// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    the toll booth on the only road
*/

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ISweepFactory} from "./interfaces/ISweepFactory.sol";
import {ISweepFeeReceiver} from "./interfaces/ISweepFeeReceiver.sol";

/**
 * @title SweepHook
 * @author 0xDAVZER
 * @notice The fee on every trade of every Sweep token, and the split that sends most of it to the
 * strategy's NFT treasury.
 *
 * @dev A v4 pool names its hook inside the struct it is identified by, so this cannot be detached,
 * upgraded or voted out: change the hook and you are naming a different pool, one that does not
 * exist. That is the whole reason the fee holds. It is not a rule traders are asked to respect, it
 * is a property of the only venue where the token can trade — the strategy's transfer lock being
 * what stops a second venue from ever being built.
 *
 * @dev The permissions this contract wants are encoded in the low fourteen bits of its own address
 * (`0x2444`), because v4 reads them from the pointer rather than from storage. `BaseHook`'s
 * constructor checks the address against `getHookPermissions()`, so deploying to an ordinary
 * address reverts rather than silently producing a hook the pool never calls. The deploy script
 * mines a CREATE2 salt to land on it.
 */
contract SweepHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint256 private constant TOTAL_BIPS = 10_000;

    /**
     * @notice What every swap pays, in either direction, from the first block of a pool's life.
     *
     * @dev One rate, one constant, and public so the interface reads it rather than assuming it.
     * The rate is flat rather than a decaying launch schedule: a schedule is read to the minute by
     * bots and by nobody else, which makes the first hour of every launch a market for the snipers
     * it was meant to keep out. A flat rate funds the strategy from everyone equally and gives a
     * first-block buyer the same deal as the last.
     */
    uint256 public constant FEE_BPS = 1000;

    /// @notice Percentage of every fee that funds the strategy's NFT purchases.
    uint256 private constant TREASURY_SHARE = 80;

    /// @notice Percentage of every fee owed to the collection, once it claims it.
    uint256 private constant CREATOR_SHARE = 10;

    /// @dev The hook only ever sells its fee into the pool, which raises the price, so this is the
    /// only limit it needs. It is a bound, not a target: the swap is asserted to have completed.
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /// @notice Who launched the pools this hook guards, and therefore who may open one at all.
    ISweepFactory public immutable factory;

    /// @notice Where the protocol's tenth accrues.
    address public protocolFeeRecipient;

    /// @notice Where a strategy's creator tenth accrues, once its collection has claimed it.
    /// @dev Zero means unclaimed, and an unclaimed share falls through to the protocol rather than
    /// being stranded. A launch therefore needs no action at all from the collection owner.
    mapping(address strategy => address recipient) public creatorFeeRecipient;

    /// @notice ETH owed to each recipient, waiting to be pulled.
    /// @dev Pulled rather than pushed. Pushing would send ETH to two arbitrary addresses in the
    /// middle of every swap, with a gas stipend large enough to call back into the PoolManager, on
    /// a contract a collection owner chose. Accruing removes the untrusted call from the hot path
    /// of every trade in the system.
    mapping(address recipient => uint256 amount) public accruedFees;

    /// @notice Only ETH-quoted pools are supported.
    error NotEthPaired();
    /// @notice Pools open and take their one deposit during a launch, and at no other time.
    error NotLaunching();
    /// @notice `amountSpecified > 0` — "give me exactly N tokens" is not supported.
    error ExactOutputNotAllowed();
    /// @notice The caller does not own the factory.
    error NotFactoryOwner();
    /// @notice The caller is not the factory.
    error NotFactory();
    /// @notice The contract that called `PoolManager.swap` is not a router the factory allows.
    error RouterNotAllowed();
    /// @notice Nothing is owed to the caller.
    error NothingAccrued();
    /// @notice A recipient of the zero address would strand every fee routed to it.
    error InvalidRecipient();
    /// @notice The pool could not absorb the whole fee, so a delta would be left outstanding.
    error FeeSwapIncomplete();
    /// @notice Only the PoolManager may send this contract ETH.
    error DirectPaymentRejected();

    event PoolLaunched(bytes32 indexed poolId, address indexed strategy, uint256 timestamp);
    event FeeCollected(
        bytes32 indexed poolId, address indexed strategy, address indexed trader, uint256 feeBps, uint256 ethAmount
    );
    event Trade(address indexed strategy, address indexed trader, uint160 sqrtPriceX96, int128 amount0, int128 amount1);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event CreatorFeeRecipientUpdated(address indexed strategy, address indexed recipient);
    event ProtocolFeeRecipientUpdated(address indexed recipient);

    /// @notice Wires the hook to the singleton, the factory, and the protocol's own fee address.
    /// @dev `BaseHook`'s constructor validates that this contract's address encodes exactly the
    /// permissions `getHookPermissions` returns, which is why deployment goes through a mined
    /// CREATE2 salt rather than a plain `new`.
    constructor(IPoolManager poolManager_, ISweepFactory factory_, address protocolFeeRecipient_)
        BaseHook(poolManager_)
    {
        if (address(factory_) == address(0) || protocolFeeRecipient_ == address(0)) {
            revert InvalidRecipient();
        }
        factory = factory_;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// @notice The four callbacks this hook implements, which must agree with its own address.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Pays out everything accrued to the caller.
    function claimFees() external {
        claimFeesFor(msg.sender);
    }

    /**
     * @notice Pays out everything accrued to `recipient`, whoever asks.
     *
     * @dev Permissionless on purpose, and safe to be: the amount and the destination are both
     * already written in `accruedFees`, so the caller decides nothing except to pay the gas. That
     * is what lets a keeper with a privilege-less key do the paying for every recipient at once,
     * and what lets a recipient still pull by hand if the keeper is down. This is not a push in
     * the swap path — the hook's reason for accruing at all — it is a pull that somebody else may
     * trigger.
     *
     * @dev Zeroed before the transfer, so a recipient that calls back in finds nothing left to
     * claim. Everyone's share sits in the same ETH balance, which is why a replayable claim would
     * drain the others rather than merely overpay one.
     *
     * @dev `safeTransferETH` rather than a forced send: a recipient contract that rejects ETH fails
     * its own claim and nothing else. The keeper skips it and moves on; the trades that funded it
     * were never at risk.
     */
    function claimFeesFor(address recipient) public {
        uint256 owed = accruedFees[recipient];
        if (owed == 0) revert NothingAccrued();

        accruedFees[recipient] = 0;
        SafeTransferLib.safeTransferETH(recipient, owed);
        emit FeesClaimed(recipient, owed);
    }

    /**
     * @notice Names where a strategy's creator share accrues, at the moment it is launched.
     *
     * @dev Factory-only, and final. This is the only writer of `creatorFeeRecipient` there is, and
     * a collection's current `owner()` cannot re-point it: a stream taken by whoever holds an
     * `owner()` today is taken from whoever paid the launch fee and opened the market. Who launches
     * is paid, and the collection's ownership decides a badge on the launch event instead.
     *
     * @dev `NotFactory` is the whole guard. Anyone else calling this would be redirecting a tenth
     * of every trade of a strategy they do not own, for good.
     */
    function registerCreatorFeeRecipient(address strategy, address recipient) external {
        if (msg.sender != address(factory)) revert NotFactory();

        creatorFeeRecipient[strategy] = recipient;
        emit CreatorFeeRecipientUpdated(strategy, recipient);
    }

    /// @notice Moves where the protocol's own tenth accrues.
    /// @dev Gated on the factory's owner rather than a second owner stored here, so there is one
    /// authority over the system and not two that can disagree. Already-accrued balances stay with
    /// the address that earned them, since accrual is per-address and not a running pointer.
    function setProtocolFeeRecipient(address recipient) external {
        if (msg.sender != factory.owner()) revert NotFactoryOwner();
        if (recipient == address(0)) revert InvalidRecipient();

        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    /**
     * @notice Opens a Sweep pool, and only during a launch.
     *
     * @dev `NotEthPaired` keeps currency0 as native ETH. Everything downstream assumes it: the fee
     * lands on the unspecified side of the swap, the treasury is denominated in ETH, and the NFT
     * purchase spends ETH. A token/token pool would fund a treasury in something it cannot spend.
     *
     * @dev `NotLaunching` is what stops a stranger opening a second pool that names this hook. Such
     * a pool would look legitimate and would skim fees into an address that never agreed to it — or
     * into something that is not a strategy at all, in which case every swap on it reverts.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.currency0.isAddressZero()) revert NotEthPaired();
        if (!factory.loadingLiquidity()) revert NotLaunching();

        emit PoolLaunched(PoolId.unwrap(key.toId()), Currency.unwrap(key.currency1), block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Accepts the launch deposit, and refuses every other one.
     *
     * @dev `NotLaunching` is what makes the position singular. The factory deposits the whole supply
     * once and sends the position NFT to the dead address; a second position would be liquidity
     * somebody could still remove, and the curve would stop being a one-way street. There is
     * deliberately no `beforeRemoveLiquidity` guard to match — nobody owns the position, so nobody
     * can ask.
     *
     * @dev The allowance is what lets the deposit move at all: the strategy reverts on transfers it
     * has not been told about, and the factory settling tokens into the PoolManager is one.
     */
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (!factory.loadingLiquidity()) revert NotLaunching();

        ISweepFeeReceiver(Currency.unwrap(key.currency1)).increaseTransferAllowance(uint256(int256(-delta.amount1())));
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Takes the fee on a swap, converts it to ETH, and splits it.
     *
     * @dev `ExactOutputNotAllowed` is the guard everything below depends on. With it, the
     * question of which side pays the fee collapses to `zeroForOne` — buys pay their fee in
     * tokens, sells pay it in ETH — and no branch exists for exact-output swaps, which cannot run.
     *
     * @dev `RouterNotAllowed` is what keeps the fee from being optional; without it there is a way
     * around everything else. The token's transfer lock sees ERC-20 movements only; v4 also keeps
     * ERC-6909 claim balances, and a swapper who takes its output as claims holds a balance the
     * lock never sees, moves it between wallets through the PoolManager, funds a hookless pool with
     * it and trades there for nothing, forever. Claims can only be minted from a delta on the PoolManager, and a locked
     * token only reaches the PoolManager through a swap on this pool — so gating that swap on the
     * factory's list of routers, every one of which settles in ERC-20 and consumes the transient
     * allowance exactly, means no such delta is ever left and no claim can come into existence.
     * `sender` is the contract that called `PoolManager.swap`, which is what the list names; v4
     * skips a pool's hooks when the hook itself is the caller, so the fee swap below is not gated
     * by this and cannot lock itself out.
     *
     * @dev The cost is composability, and it is real: no aggregator, no UniswapX, no direct call
     * to the PoolManager. It is also the cost already paid by the transfer lock, which forbids
     * every venue but this pool — this closes the one door that lock left open rather than
     * opening a new one.
     *
     * @dev Everything else lives in `_skimFee` only because this function otherwise exceeds the
     * EVM's reachable stack. The split is a compiler constraint, not a boundary: `via_ir` would
     * lift it, and `forge coverage` cannot use `via_ir`.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (params.amountSpecified > 0) revert ExactOutputNotAllowed();
        if (!factory.isRouter(sender)) revert RouterNotAllowed();
        return (IHooks.afterSwap.selector, _skimFee(_trader(sender, hookData), key, params.zeroForOne, delta));
    }

    /**
     * @notice Who the trade is for: the address the router named, or the router itself.
     *
     * @dev `sender` is whoever called the PoolManager, and that is a router, not a person. A router
     * that wants the person recorded passes their address as `hookData`; anything else — no data,
     * or data of another shape — falls back to the sender. This is what the indexer attributes a
     * trade to, and it is a claim by the router rather than a fact the hook can verify: a router
     * could name anyone. Nothing here spends or credits on the strength of it, so a false claim
     * misattributes a row and nothing more. Sweep's own router names the wallet it was called by.
     */
    function _trader(address sender, bytes calldata hookData) private pure returns (address) {
        if (hookData.length != 32) return sender;
        return abi.decode(hookData, (address));
    }

    /**
     * @notice The body of `afterSwap`: charge, convert, split, and report.
     *
     * @dev v4 only lets `afterSwap` return a delta on the currency the trader did NOT specify. Since
     * exact output is refused upstream, that is the token on a buy and ETH on a sell, and the two
     * paths differ only in whether a conversion is needed before the split.
     *
     * @dev The transfer allowance is raised before anything else and is exact rather than generous:
     * on a buy the trader receives the output minus the fee, because the fee never reaches them.
     * Authorising the gross would leave the difference standing as a hole in the lock for the rest
     * of the transaction, and the lock is the only thing stopping a competing pool from existing.
     * Erring small is also the safe direction — an under-authorised swap reverts and loses nobody
     * anything, an over-authorised one quietly widens the hole.
     *
     * @dev A fee of zero is possible on a dust trade, and it returns early *after* authorising the
     * settlement. Returning before that would leave the trader's own swap unable to settle.
     *
     * @dev Nothing here calls an address the protocol does not control. The one transfer is
     * `addFees` into our own strategy; the creator and protocol shares accrue and are pulled later.
     */
    function _skimFee(address trader, PoolKey calldata key, bool buying, BalanceDelta delta) private returns (int128) {
        address strategy = Currency.unwrap(key.currency1);
        uint256 feeAmount = (_abs(buying ? delta.amount1() : delta.amount0()) * FEE_BPS) / TOTAL_BIPS;

        ISweepFeeReceiver(strategy).increaseTransferAllowance(_abs(delta.amount1()) - (buying ? feeAmount : 0));
        if (feeAmount == 0) return 0;

        uint256 ethAmount = buying ? _sellFeeForEth(key, feeAmount) : _takeEth(key, feeAmount);
        _distribute(strategy, ethAmount);

        emit FeeCollected(PoolId.unwrap(key.toId()), strategy, trader, FEE_BPS, ethAmount);
        emit Trade(strategy, trader, _currentPrice(key), delta.amount0(), delta.amount1());
        return feeAmount.toInt128();
    }

    /// @notice Magnitude of a signed balance delta.
    /// @dev v4 signs a delta by direction, and every fee and allowance here is a size rather than a
    /// direction. `int128` cannot hold the negation of its own minimum, but a pool delta never
    /// reaches it: it is bounded by the pool's reserves.
    function _abs(int128 x) private pure returns (uint256) {
        return uint256(int256(x < 0 ? -x : x));
    }

    /**
     * @notice Turns a fee denominated in the strategy's own token into ETH.
     *
     * @dev The hook is credited its fee by the PoolManager after `afterSwap` returns, and debited
     * here by its own swap. Both land on the same `(address, currency)` running balance, so they
     * cancel and **no token ever moves**. Taking the fee out as real ERC-20 and transferring it
     * straight back in would be a round trip whose two legs both have to be authorised against the
     * strategy's transfer lock, with all the arithmetic that implies.
     *
     * @dev This swap pays no fee of its own. `Hooks.afterSwap` returns early when the hook is the
     * caller, so it does not recurse.
     *
     * @dev `FeeSwapIncomplete` catches a pool that could not absorb the whole fee, which would leave
     * a delta outstanding and revert the trader's swap with v4's opaque settlement error instead of
     * ours. It should be unreachable: the hook only ever sells back a fraction of what the trade it
     * is charging just bought, so the price it pushes back up can never reach where that trade
     * started.
     */
    function _sellFeeForEth(PoolKey calldata key, uint256 amount) private returns (uint256 ethOut) {
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            bytes("")
        );

        if (delta.amount1() != -amount.toInt128()) revert FeeSwapIncomplete();

        ethOut = uint256(int256(delta.amount0()));
        poolManager.take(key.currency0, address(this), ethOut);
    }

    /// @notice Pulls a fee that is already ETH out of the PoolManager.
    /// @dev Taken before the PoolManager credits it, which leaves the hook transiently negative and
    /// square by the end of the unlock. v4 settles once, at the end, not per call.
    function _takeEth(PoolKey calldata key, uint256 amount) private returns (uint256) {
        poolManager.take(key.currency0, address(this), amount);
        return amount;
    }

    /**
     * @notice Splits a collected fee eighty / ten / ten.
     *
     * @dev Eighty percent buys NFTs, ten is the collection's, ten is the protocol's. The
     * collection's tenth is what the protocol actually has to offer a collection in exchange for
     * launching with it.
     *
     * @dev An unclaimed creator share is added to the protocol's rather than accrued to the zero
     * address, where it would be permanently stranded. That is also what lets a strategy launch and
     * run with no action from the collection owner at all.
     */
    function _distribute(address strategy, uint256 amount) private {
        if (amount == 0) return;

        uint256 toTreasury = (amount * TREASURY_SHARE) / 100;
        uint256 toCreator = (amount * CREATOR_SHARE) / 100;
        uint256 toProtocol = amount - toTreasury - toCreator;

        address creator = creatorFeeRecipient[strategy];
        if (creator == address(0)) {
            toProtocol += toCreator;
        } else {
            accruedFees[creator] += toCreator;
        }
        accruedFees[protocolFeeRecipient] += toProtocol;

        ISweepFeeReceiver(strategy).addFees{value: toTreasury}();
    }

    /// @notice The pool's price right now, for the trade event the indexer reads.
    function _currentPrice(PoolKey calldata key) private view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }

    /// @notice Accepts ETH from the PoolManager, and from nowhere else.
    /// @dev Refusing everything else is what makes "the hook holds exactly what it owes" an
    /// invariant rather than a hope: no donation can inflate the balance the accrual ledger is
    /// supposed to account for, and no accounting bug can hide behind one.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert DirectPaymentRejected();
    }
}
