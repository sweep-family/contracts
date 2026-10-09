// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    the last leg: proceeds in, supply out
*/

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ISweepBurnRouter} from "./interfaces/ISweepBurnRouter.sol";
import {ISweepFactory} from "./interfaces/ISweepFactory.sol";

/**
 * @title SweepBurnRouter
 * @author 0xDAVZER
 * @notice Buys a Sweep token on its own pool and delivers it to the dead address. The last leg of
 * the cycle: resale proceeds in, circulating supply out.
 *
 * @dev Not the Universal Router, for two reasons. A general router takes tokens to itself and
 * forwards them, and that second transfer is wallet-to-wallet, which the strategy's lock refuses
 * unless the router is a distributor — and every distributor is a hole in the fee. And a v4 swap is
 * four calls that the hook already makes; writing them again here, against the same PoolManager
 * with the same accounting, is less to trust than a command-byte encoding.
 *
 * @dev This swap pays the hook's fee. The hook is skipped only when the hook itself is the caller,
 * and this contract is not the hook. So every burn is a tenth less effective than it looks, and
 * eighty percent of that tenth lands back in the treasury that funds the next NFT — the flywheel
 * feeds itself, and that is by design rather than by accident.
 */
contract SweepBurnRouter is ISweepBurnRouter, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice The share of the pool's live ETH reserve one protocol buy may spend, in basis points.
    /// @dev The graduated pool is one full-range position nobody can add to, so its ETH side moves
    /// with the square root of the price: a constant cap that is safe at graduation is
    /// sandwichable once the price has fallen. A share of the live reserve keeps the burn's price
    /// impact — the one thing a sandwich feeds on — the same at every price.
    uint256 public constant MAX_BURN_DEPTH_BPS = 400;
    /// @dev The burn only ever buys, which lowers the price, so this is the only limit it needs.
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    /// @dev The pool parameters every launch uses. Read from nowhere: the factory pins them as
    /// constants and the router mirrors them, so a pool key built here is the pool key the factory
    /// opened. A mismatch would be a swap on a pool that does not exist, which reverts.
    uint24 private constant LP_FEE = 0;
    int24 private constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    ISweepFactory public immutable factory;

    /// @notice The factory never launched this token, so there is no pool of ours to buy it on.
    error UnknownStrategy();
    /// @notice A swap of nothing.
    error NothingToSpend();
    /// @notice The settlement callback is the PoolManager's to make, and nobody else's.
    error NotPoolManager();
    /// @notice The pool could not absorb the whole amount, so part of it would be stranded here.
    error SwapIncomplete();

    event Burned(address indexed token, address indexed recipient, uint256 ethIn, uint256 tokensOut);

    constructor(IPoolManager poolManager_, ISweepFactory factory_) {
        if (address(poolManager_) == address(0) || address(factory_) == address(0)) revert UnknownStrategy();
        poolManager = poolManager_;
        factory = factory_;
    }

    /**
     * @notice Spends `msg.value` buying `token` on its Sweep pool and delivers what it bought to
     * `recipient`.
     *
     * @dev `UnknownStrategy` keeps this from being a general-purpose router. It exists to close one
     * loop for tokens the factory launched, and an arbitrary token would mean an arbitrary pool key
     * and a swap into whatever answers to it.
     *
     * @dev `NothingToSpend` names what v4 would otherwise reject as `SwapAmountCannotBeZero` from
     * inside a callback, three frames away from the caller who sent nothing.
     *
     * @dev `recipient` must be an address the token's lock admits — in practice the dead address —
     * because delivery is a plain transfer from this contract. See `unlockCallback`.
     */
    function buyTokenWithEth(address token, address recipient) external payable returns (uint256 received) {
        if (!factory.isStrategy(token)) revert UnknownStrategy();
        if (msg.value == 0) revert NothingToSpend();

        received = abi.decode(poolManager.unlock(abi.encode(token, recipient, msg.value)), (uint256));
        emit Burned(token, recipient, msg.value, received);
    }

    /**
     * @notice The largest single buy of `token` a strategy may make on its own pool right now:
     * `MAX_BURN_DEPTH_BPS` of the pool's ETH reserve.
     *
     * @dev The reserve of a full-range position is `L / sqrtP`, read live from the PoolManager;
     * zero before the pool exists. Both a desk's burn pass and a recursive distribution are
     * bounded by it. A front-run buy deepens the ETH side and raises the bound in step, but the
     * ratio of the burn to the depth it lands in stays fixed, and the attacker pays the 10% fee
     * on both legs of a position that grows with the depth.
     */
    function maxBurnBuy(address token) external view returns (uint256) {
        PoolId id = _keyFor(token).toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return 0;
        uint256 depth = FixedPointMathLib.fullMulDiv(poolManager.getLiquidity(id), 1 << 96, sqrtPriceX96);
        return (depth * MAX_BURN_DEPTH_BPS) / 10_000;
    }

    /// @notice The pool key every Sweep launch's pool carries.
    function _keyFor(address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(factory.hook())
        });
    }

    /**
     * @notice The swap, inside the PoolManager's flash-accounting window.
     *
     * @dev `NotPoolManager` is the guard that matters: this function settles ETH and takes tokens on
     * the strength of whatever `data` says, and only the PoolManager may be the one saying it —
     * echoing back what `buyTokenWithEth` handed to `unlock` in the same call.
     *
     * @dev The delta v4 returns is already net of the hook's fee, because the PoolManager subtracts
     * the hook's delta from the swapper's before returning it. What is taken here is therefore
     * exactly what the hook authorised the lock to let through.
     *
     * @dev `SwapIncomplete` fires if the pool stopped short of consuming everything. The strategy
     * has already debited `pendingBurn` by then, so a partial fill would strand the remainder here
     * with no ledger entry to return it against; reverting leaves the queue intact to retry. It
     * should be unreachable — the launch position spans down to the minimum tick, so a buy always
     * finds liquidity until the supply itself is exhausted.
     *
     * @dev The tokens are taken to this contract and then transferred on, rather than taken to the
     * recipient directly. When the lock still admitted the dead address before reading the pool
     * rule, a direct take left the hook's transient authorisation unspent and standing open for
     * the rest of the transaction — and `processBurn` is public, so the rest of the transaction is
     * whoever called it. Taking to self consumes the allowance exactly; the onward transfer is admitted on its own
     * terms. One extra transfer, and brick 4's invariant holds here too.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, address recipient, uint256 amountIn) = abi.decode(data, (address, address, uint256));

        PoolKey memory key = _keyFor(token);

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            bytes("")
        );

        uint256 ethOwed = uint256(int256(-delta.amount0()));
        uint256 tokensOut = uint256(int256(delta.amount1()));
        if (ethOwed != amountIn) revert SwapIncomplete();

        poolManager.settle{value: ethOwed}();
        poolManager.take(key.currency1, address(this), tokensOut);
        SafeTransferLib.safeTransfer(token, recipient, tokensOut);

        return abi.encode(tokensOut);
    }
}
