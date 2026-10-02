// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    where a market is born, with no capital
*/

import {Ownable} from "solady/src/auth/Ownable.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SweepNFTStrategy} from "./SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "./SweepERC20Strategy.sol";
import {SweepRecursiveStrategy} from "./SweepRecursiveStrategy.sol";
import {SweepBondingCurve} from "./SweepBondingCurve.sol";
import {SweepGraduationMath} from "./libraries/SweepGraduationMath.sol";
import {ISweepBondingCurve, ISweepCurveToken} from "./interfaces/ISweepBondingCurve.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ISweepFactory} from "./interfaces/ISweepFactory.sol";
import {ISweepHookRegistry} from "./interfaces/ISweepHookRegistry.sol";
import {IOwnable} from "./interfaces/IOwnable.sol";

/**
 * @title SweepNFTStrategyFactory
 * @author 0xDAVZER
 * @notice Turns a collection into a market: one token, one curve at launch, one pool at
 * graduation.
 *
 * @dev A launch deploys the strategy — which is the token — and moves its entire supply onto a
 * `SweepBondingCurve` clone, where it trades against a virtual reserve until 4.2 ETH of real ETH
 * has come in. `createGraduatedPool`, permissionless, then takes the curve's reserves and opens
 * the Uniswap v4 pool at the curve's exact final price: a full-range position seeded with all
 * the swept ETH and the reserved token allocation, its ownership NFT minted to the dead address
 * so nobody can ever withdraw it, and the excess tokens burnt the same way. Reserves move from
 * curve to pool in one transaction, so there is no swept-but-unpooled state and no rescue path
 *.
 *
 * @dev Anyone may launch on anything, for the fee. There is no allowlist and no gate on the
 * collection's own `owner()`: a gate on `owner()` would exclude every collection that renounced it
 * and stop nothing, since a launch through another door takes a slot just as permanently. What the
 * collection's `owner()` now decides is one bit on the launch event: whether the launcher was it.
 * The strategy's owner is this factory's owner whoever launched, so launching grants no power over
 * a contract that will hold other people's money.
 *
 * @dev Three kinds of strategy leave here. Two are desks, sweeping a collection's pieces or a
 * token's bags; the third sweeps nothing and pays its own holders in itself. The pool, the
 * position and the fee are the same for all three; what differs is the target and what is
 * recorded.
 */
contract SweepNFTStrategyFactory is Ownable, ReentrancyGuard, ISweepFactory {
    /// @notice Where the bonding curve's ownership goes, permanently.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice `type(IERC721).interfaceId`, the gate a collection must answer to.
    bytes4 public constant ERC721_INTERFACE_ID = 0x80ac58cd;

    /// @notice No Uniswap fee on the pool.
    /// @dev The hook takes the fee instead. An LP fee here would accrue to the launch position,
    /// which is owned by the dead address — so it would be collected and then lost forever, and it
    /// would also be charged on the hook's own conversion of its fee back to ETH.
    uint24 public constant LP_FEE = 0;

    int24 public constant TICK_SPACING = 60;

    /// @notice The curve's virtual reserve, mirrored so graduation can split the reserves with
    /// the same number the curve priced them with. `setCurveImplementation` refuses an
    /// implementation whose constant disagrees, so the mirror cannot drift.
    uint256 public constant PHANTOM_QUOTE = 1.68 ether;

    /// @notice The curve's graduation threshold, mirrored and verified the same way.
    uint256 public constant GRADUATION_THRESHOLD = 4.2 ether;

    /// @notice Slowest bid ramp a launch may choose: about 0.0036 ETH an hour.
    /// @dev Below this a strategy's published bid never reaches a floor price within any useful
    /// horizon, and the machine looks alive while being unable to buy anything.
    uint256 public constant MIN_BID_INCREASE_PER_SECOND = 0.000_001 ether;

    /// @notice Fastest bid ramp a launch may choose: about 36 ETH an hour.
    /// @dev Above this the reverse auction resolves faster than anyone can watch it, which defeats
    /// the point — the ramp exists so a seller has time to decide the offer is worth taking.
    uint256 public constant MAX_BID_INCREASE_PER_SECOND = 0.01 ether;

    /// @notice Highest ceiling a launch may set on its own bid.
    /// @dev A launch-time sanity bound on a number a stranger supplies, not a permanent one: the
    /// strategy's owner can raise it later through `setBidParameters`. It catches a mistyped
    /// ceiling, which would otherwise let the treasury be spent in one purchase.
    uint256 public constant MAX_BID_CAP = 100 ether;

    /// @notice A fungible strategy's bag is the target's total supply divided by this.
    ///
    /// @dev One thousandth of the supply: for a token with a supply of 296,296,296 the bag is
    /// 296,296.296, large enough to be worth selling and small enough for one holder to bring. It
    /// is a factory constant rather than a launch argument so that no front end can
    /// launch a bag of one wei, which would sell for the whole treasury at the first tick of the
    /// ramp, or of half the supply, which nobody could ever bring.
    uint256 public constant BAG_DIVISOR = 1000;

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable poolManager;

    /// @notice The implementation every strategy proxy points at.
    address public strategyImplementation;

    /// @notice The implementation every fungible launch clones. Unset until the protocol sets it,
    /// and `launchERC20` refuses until then.
    address public erc20Implementation;

    /// @notice The implementation every recursive launch clones. Unset until the protocol sets
    /// it, and `launchRecursive` refuses until then.
    address public recursiveImplementation;

    /// @notice The v4 hook every launched pool is welded to.
    /// @dev Settable exactly once. See `setHook`.
    address public hook;

    /// @notice Where a strategy's burn buys its own token.
    address public burnRouter;

    /// @notice What a launch costs, and where that goes.
    uint256 public launchFee = 0.001 ether;
    address public launchFeeRecipient;

    /// @notice The markup every new strategy opens its resales at.
    /// @dev A factory default rather than a launch parameter: it is the same judgement for every
    /// collection, and a stranger has no better information about it than we do.
    uint256 public resaleMultiplierBps = 12_000;

    /// @inheritdoc ISweepFactory
    bool public loadingLiquidity;

    /// @inheritdoc ISweepFactory
    mapping(address strategy => address collection) public strategyToCollection;

    /// @inheritdoc ISweepFactory
    mapping(address token => bool launched) public isStrategy;

    /**
     * @inheritdoc ISweepFactory
     *
     * @dev This is the reason ERC-6909 claims on a strategy's token cannot exist: claims are
     * minted from a delta on the PoolManager, a locked token only reaches the PoolManager through
     * a swap on the hooked pool, and the hook refuses a swap from anything not listed here. Both
     * routers we ship take and settle in ERC-20 and consume the transient allowance exactly, so
     * no delta is ever left over for a claim to be minted from.
     *
     * @dev A list of contracts, not of traders: anyone may trade, through one of them. It is also
     * a trust boundary the owner holds, and is disclosed as an owner power alongside
     * `setDistributor`.
     */
    mapping(address router => bool allowed) public isRouter;

    /// @notice The implementation every launch's bonding curve is cloned from.
    address public curveImplementation;

    /// @notice Each strategy's launch market.
    mapping(address strategy => address curve) public curveOf;

    /// @notice The strategy behind a curve — nonzero exactly for curves this factory deployed,
    /// which is what the `receive` gate reads.
    mapping(address curve => address strategy) public strategyOfCurve;

    /// @notice Routers that can never be delisted. The base swap and burn
    /// routers live here, so no owner — honest or compromised — can freeze trading on a token
    /// whose transfer lock makes these routers the only market.
    mapping(address router => bool permanent) public isPermanentRouter;

    /// @notice The position NFT each graduation minted to the dead address. Zero until the
    /// strategy graduates, which is how "not yet pooled" is spelled.
    mapping(address strategy => uint256 tokenId) public positionIdOf;

    error HookNotSet();
    error HookAlreadySet();
    error BurnRouterNotSet();
    error WrongLaunchFee();
    error NotERC721();
    error InvalidBidParameters();
    error InvalidConfiguration();
    error ERC20ImplementationNotSet();
    error NotERC20();
    error InvalidBag();
    error RecursiveImplementationNotSet();
    error CurveImplementationNotSet();
    error CurveEconomicsMismatch();
    error RouterPermanent();
    error UnknownStrategy();
    error AlreadyPooled();
    error DirectPaymentRejected();

    event StrategyLaunched(
        address indexed collection,
        address indexed strategy,
        address indexed launcher,
        string name,
        string symbol,
        address curve,
        bool verified
    );
    event ERC20StrategyLaunched(
        address indexed token,
        address indexed strategy,
        address indexed launcher,
        string name,
        string symbol,
        address curve,
        uint256 bagSize
    );
    event RecursiveStrategyLaunched(
        address indexed strategy, address indexed launcher, string name, string symbol, address curve
    );
    event StrategyGraduated(
        address indexed strategy,
        address indexed curve,
        uint256 positionId,
        uint256 pooledEth,
        uint256 pooledTokens,
        uint256 burnedTokens,
        uint160 sqrtPriceX96
    );
    event CurveImplementationSet(address indexed implementation);
    event RouterMadePermanent(address indexed router);
    event HookSet(address indexed hook);
    event BurnRouterSet(address indexed router);
    event StrategyImplementationSet(address indexed implementation);
    event ERC20ImplementationSet(address indexed implementation);
    event RecursiveImplementationSet(address indexed implementation);
    event RouterSet(address indexed router, bool allowed);
    event LaunchFeeSet(uint256 fee, address indexed recipient);
    event ResaleMultiplierSet(uint256 multiplierBps);

    /// @notice Wires the factory to Uniswap and to the implementation it clones, and proves the
    /// constant curve economics can seed a v4 pool at all — a misbuilt deployment fails here, at
    /// deploy time, rather than at the first stranger's graduation.
    /// @dev The hook is deliberately absent. Its address encodes its permissions and is mined over
    /// an initcode containing this factory's address, so it cannot exist yet — see `setHook`.
    constructor(
        address positionManager_,
        address permit2_,
        address poolManager_,
        address strategyImplementation_,
        address launchFeeRecipient_,
        address owner_
    ) {
        if (
            positionManager_ == address(0) || permit2_ == address(0) || poolManager_ == address(0)
                || strategyImplementation_ == address(0) || launchFeeRecipient_ == address(0) || owner_ == address(0)
        ) {
            revert InvalidConfiguration();
        }

        positionManager = IPositionManager(positionManager_);
        permit2 = IAllowanceTransfer(permit2_);
        poolManager = poolManager_;
        strategyImplementation = strategyImplementation_;
        launchFeeRecipient = launchFeeRecipient_;

        _initializeOwner(owner_);

        uint256 supply = SweepNFTStrategy(payable(strategyImplementation_)).MAX_SUPPLY();
        uint256 reserved = FixedPointMathLib.fullMulDiv(supply, PHANTOM_QUOTE, PHANTOM_QUOTE + GRADUATION_THRESHOLD);
        SweepGraduationMath.assertSeedable(
            TICK_SPACING,
            GRADUATION_THRESHOLD,
            FixedPointMathLib.fullMulDiv(reserved, GRADUATION_THRESHOLD, PHANTOM_QUOTE + GRADUATION_THRESHOLD)
        );
    }

    /**
     * @notice Launches a strategy on `collection`. Anyone may call this, for the fee.
     *
     * @dev There is no ownership gate. One would refuse every collection whose `owner()` is
     * renounced, cold or lost, which is most of the ones worth sweeping, and it would not be the
     * protection it looks like: nothing about owning a collection is needed to point a desk at its
     * floor. What ownership buys
     * is a badge, not a veto — see `_launch`, which computes it.
     *
     * @dev The launcher is registered with the hook as the creator fee recipient in the same
     * transaction, so the strategy is paid from its first trade with nothing further to sign, and
     * that registration is final: the hook has no second writer. Whoever pays the fee and opens
     * the market keeps the stream, and a collection that turns up afterwards takes nothing.
     *
     * @dev Every other guard is on `_validateLaunch`, and explained there.
     */
    function launch(
        address collection,
        string calldata name_,
        string calldata symbol_,
        uint256 bidIncreasePerSecond,
        uint256 maxBid
    ) external payable nonReentrant returns (address) {
        return _launch(collection, name_, symbol_, bidIncreasePerSecond, maxBid, msg.sender);
    }

    /**
     * @notice Launches a strategy on behalf of a collection that cannot prove its owner on-chain.
     *
     * @dev This skips no gate, because there is none to skip. What it does, and `launch` cannot,
     * is name a recipient that is not the caller: a collection whose ownership was established
     * off-chain can be launched on its behalf and paid from the first trade, which is the only
     * reason this path exists.
     *
     * @dev Such a launch is never marked verified, and needs no special case to not be: we are not
     * the collection's owner, so the one rule `_launch` applies already answers. A zero recipient
     * leaves the share unclaimed, falling through to the protocol for good.
     */
    function ownerLaunch(
        address collection,
        string calldata name_,
        string calldata symbol_,
        uint256 bidIncreasePerSecond,
        uint256 maxBid,
        address creatorFeeRecipient
    ) external payable onlyOwner nonReentrant returns (address) {
        return _launch(collection, name_, symbol_, bidIncreasePerSecond, maxBid, creatorFeeRecipient);
    }

    /**
     * @notice The launch itself, once the caller has been admitted.
     *
     * @dev `HookNotSet` and `BurnRouterNotSet` guard against a launch that would produce a pool with
     * no toll booth, or a strategy that can never burn. Neither is fixable afterwards for a strategy
     * already launched: the hook is part of the pool's identity, and both are written into the
     * proxy at initialisation.
     *
     * @dev `WrongLaunchFee` is exact in both directions. Under-paying is obvious; over-paying
     * matters because the surplus would sit in a contract with no way to return it.
     *
     * @dev Nothing here refuses a collection that already has strategies. Two desks on one
     * collection do compete for the same floor, and each purchase does make the next dearer for
     * the other, but a one-per-collection rule would be worse: one slot per collection, taken by
     * whoever transacted first, at 101 ms blocks with a public mempool.
     *
     * @dev `NotERC721` is the gate that matters most after ownership, because the failure it
     * prevents is silent and paid for. The strategy calls `ownerOf` and `transferFrom` on this
     * address for the rest of its life; against something that is not a collection it can never
     * buy anything, and the fee has already been taken by the time anyone notices.
     *
     * @dev `InvalidBidParameters` bounds what a launcher can ship. Too slow and the published bid
     * never reaches a floor price; too fast and the reverse auction resolves before a seller can
     * read it; too high a ceiling and one purchase empties the treasury.
     *
     * @dev The strategy's owner is `owner()` — this factory's — and never the launcher. A collection
     * owner launching their own strategy still does not get the setters, because those are power
     * over funds that belong to the token's holders, not to the collection.
     *
     * @dev The creator recipient is registered with the hook after the strategy is recorded and
     * before the pool is opened, so by the time the first trade can happen the hook already knows
     * where that trade's creator tenth goes. A zero recipient is simply not registered: the share
     * then falls through to the protocol, which is the hook's default for an unclaimed strategy.
     *
     * @dev `verified` is the badge, and the whole of it: at this block, this collection's own
     * contract named this caller as its owner. It is emitted rather than stored, because the fact
     * is dated. A collection sold tomorrow does not un-launch, and a stored copy would read as
     * current when it is not — while an indexer replaying this log rebuilds the same answer years
     * later, which no re-read of `owner()` could. The comparison carries no zero check because
     * `_collectionOwner` returns zero for a collection that has no accessor and `msg.sender` is
     * never zero, so such a collection is already never verified; an added check would be a guard
     * nothing can reach. An `ownerLaunch` is never verified either, for the same one reason: the
     * factory owner is not the collection's owner.
     */
    function _launch(
        address collection,
        string calldata name_,
        string calldata symbol_,
        uint256 bidIncreasePerSecond,
        uint256 maxBid,
        address creatorFeeRecipient
    ) private returns (address strategy) {
        _validateLaunch(collection, bidIncreasePerSecond, maxBid);
        address collectionOwner = _collectionOwner(collection);

        address curve = _deployCurve();
        strategy = _deployStrategy(collection, name_, symbol_, bidIncreasePerSecond, maxBid, curve);
        _open(collection, strategy, curve, creatorFeeRecipient);

        emit StrategyLaunched(collection, strategy, msg.sender, name_, symbol_, curve, collectionOwner == msg.sender);
    }

    /**
     * @notice Launches a fungible strategy on `token`. Anyone may call this, for the fee.
     *
     * @dev No owner's consent is asked for, and the reason is what a token is: a fungible token
     * has, more often than not, renounced its owner and is nobody's to consent for. Anyone is
     * admitted for the fee.
     *
     * @dev The creator tenth goes to the token's `owner()` when it has one, read the way the
     * collection owner is read, and is left unregistered otherwise, which the hook routes to the
     * protocol. The launcher is never the recipient: if the launcher could name any address, the
     * first person to launch on a popular token would collect a tenth of its fees forever, and
     * that is a race worth not having.
     *
     * @dev The bag is `totalSupply() / BAG_DIVISOR`, sized here and not by a front end; see the
     * constant. Every other guard is on `_validateERC20Launch`, and explained there.
     */
    function launchERC20(
        address token,
        string calldata name_,
        string calldata symbol_,
        uint256 bidIncreasePerSecond,
        uint256 maxBid
    ) external payable nonReentrant returns (address) {
        ERC20Launch memory terms = ERC20Launch({
            token: token,
            bagSize: _totalSupply(token) / BAG_DIVISOR,
            bidIncreasePerSecond: bidIncreasePerSecond,
            maxBid: maxBid,
            creatorFeeRecipient: _collectionOwner(token)
        });
        return _launchERC20(terms, name_, symbol_);
    }

    /**
     * @notice Launches a fungible strategy with an explicit bag and an explicit creator recipient.
     *
     * @dev The team-launched path, for the factory owner only: a token whose right bag
     * is not a thousandth of its supply, or whose owner was established off-chain. Same fee, same
     * bounds, same everything else; `InvalidBag` refuses a bag of nothing, which could never be
     * sold, and a bag above the supply, which could never be bought.
     */
    function ownerLaunchERC20(
        address token,
        uint256 bagSize,
        string calldata name_,
        string calldata symbol_,
        uint256 bidIncreasePerSecond,
        uint256 maxBid,
        address creatorFeeRecipient
    ) external payable onlyOwner nonReentrant returns (address) {
        ERC20Launch memory terms = ERC20Launch({
            token: token,
            bagSize: bagSize,
            bidIncreasePerSecond: bidIncreasePerSecond,
            maxBid: maxBid,
            creatorFeeRecipient: creatorFeeRecipient
        });
        return _launchERC20(terms, name_, symbol_);
    }

    /// @notice The numbers of a fungible launch, in one place.
    /// @dev A struct because the flat version — seven arguments, two of them strings — is exactly
    /// what overflows the stack without `via_ir`, which `forge coverage` cannot use.
    struct ERC20Launch {
        address token;
        uint256 bagSize;
        uint256 bidIncreasePerSecond;
        uint256 maxBid;
        address creatorFeeRecipient;
    }

    /// @notice The fungible launch itself, once the caller has been admitted and the bag sized.
    /// @dev Mirrors `_launch`: validate, deploy, open, announce. The event is its own so that an
    /// indexer tells the two kinds of strategy apart by signature.
    function _launchERC20(ERC20Launch memory terms, string calldata name_, string calldata symbol_)
        private
        returns (address strategy)
    {
        _validateERC20Launch(terms);

        address curve = _deployCurve();
        strategy = _deployERC20Strategy(terms, name_, symbol_, curve);
        _open(terms.token, strategy, curve, terms.creatorFeeRecipient);

        emit ERC20StrategyLaunched(terms.token, strategy, msg.sender, name_, symbol_, curve, terms.bagSize);
    }

    /**
     * @notice Launches a strategy that sweeps nothing and pays its holders in itself. Anyone may
     * call this, for the fee.
     *
     * @dev There is no target, so there is no owner whose consent could be asked for, and
     * nothing to record in the collection mappings: `strategyToCollection` stays zero, which is
     * what tells the hook that the creator recipient can never be re-pointed. The launcher is that
     * recipient, fixed here for good; unlike a fungible launch there is no popular token to race
     * for, only a name the launcher chose.
     *
     * @dev `RecursiveImplementationNotSet` has the shape of `HookNotSet`: nothing to clone. The
     * hook, router and fee guards are the ones every launch has.
     */
    function launchRecursive(string calldata name_, string calldata symbol_)
        external
        payable
        nonReentrant
        returns (address strategy)
    {
        if (hook == address(0)) revert HookNotSet();
        if (burnRouter == address(0)) revert BurnRouterNotSet();
        if (recursiveImplementation == address(0)) revert RecursiveImplementationNotSet();
        if (curveImplementation == address(0)) revert CurveImplementationNotSet();
        if (msg.value != launchFee) revert WrongLaunchFee();

        address curve = _deployCurve();
        strategy = _deployRecursiveStrategy(name_, symbol_, curve);
        _open(address(0), strategy, curve, msg.sender);

        emit RecursiveStrategyLaunched(strategy, msg.sender, name_, symbol_, curve);
    }

    /// @notice Clones the recursive implementation and wires the new strategy to everything it
    /// will need. The owner is this factory's, never `msg.sender`, for the reason `_deployStrategy`
    /// gives.
    function _deployRecursiveStrategy(string calldata name_, string calldata symbol_, address curve)
        private
        returns (address strategy)
    {
        SweepRecursiveStrategy.Config memory config;
        config.burnRouter = burnRouter;
        config.name = name_;
        config.symbol = symbol_;
        config.hook = hook;
        config.poolManager = poolManager;
        config.owner = owner();
        config.curve = curve;

        strategy = LibClone.deployERC1967(recursiveImplementation);
        SweepRecursiveStrategy(payable(strategy)).initialize(config);
    }

    /**
     * @notice What every launch does once its strategy exists, whatever the strategy buys.
     *
     * @dev The mappings are written first so `isStrategy` answers for the routers and
     * `strategyToCollection` for anything that needs to know what a strategy buys. There is no
     * reverse mapping: a collection may carry any number of strategies, and a
     * `collection => strategy` entry would answer one address for a one-to-many relation — a fact
     * that is wrong the moment a second launch lands. Whatever needs the strategies of a collection
     * reads them from the launch events. A launch with no target passes the zero address and is
     * recorded as a strategy only. The creator recipient is registered before the curve opens,
     * so by the time the first trade can happen the hook already knows where a trade's creator
     * tenth will go once the pool exists; a zero recipient is simply not registered, and the
     * share falls through to the protocol — on the curve as on the pool. The whole supply then
     * moves onto the curve, which refuses anything less than all of it, and the curve exempts
     * both the sender and the creator recipient from its snipe tax — two different wallets on a
     * bag desk or an owner launch. Then the fee.
     */
    function _open(address target, address strategy, address curve, address creatorFeeRecipient) private {
        isStrategy[strategy] = true;
        curveOf[strategy] = curve;
        strategyOfCurve[curve] = strategy;
        if (target != address(0)) strategyToCollection[strategy] = target;
        if (creatorFeeRecipient != address(0)) {
            ISweepHookRegistry(hook).registerCreatorFeeRecipient(strategy, creatorFeeRecipient);
        }

        uint256 supply = ISweepCurveToken(strategy).balanceOf(address(this));
        SafeTransferLib.safeTransfer(strategy, curve, supply);
        ISweepBondingCurve(curve).initialize(strategy, creatorFeeRecipient, msg.sender);

        if (launchFee != 0) SafeTransferLib.safeTransferETH(launchFeeRecipient, launchFee);
    }

    /// @notice Everything a launch must be true about before anything is deployed.
    /// @dev Split out of `launch` to keep it inside the reachable stack without `via_ir`, which
    /// `forge coverage` cannot use. Each guard is explained on `_launch`, where the reader is.
    function _validateLaunch(address collection, uint256 bidIncreasePerSecond, uint256 maxBid) private view {
        if (hook == address(0)) revert HookNotSet();
        if (burnRouter == address(0)) revert BurnRouterNotSet();
        if (curveImplementation == address(0)) revert CurveImplementationNotSet();
        if (msg.value != launchFee) revert WrongLaunchFee();
        if (
            bidIncreasePerSecond < MIN_BID_INCREASE_PER_SECOND || bidIncreasePerSecond > MAX_BID_INCREASE_PER_SECOND
                || maxBid == 0 || maxBid > MAX_BID_CAP
        ) {
            revert InvalidBidParameters();
        }
        if (!_isERC721(collection)) revert NotERC721();
    }

    /**
     * @notice Everything a fungible launch must be true about before anything is deployed.
     *
     * @dev `ERC20ImplementationNotSet` has the same shape as `HookNotSet`: nothing to clone.
     * A token may carry any number of bag desks, as a collection may.
     * `NotERC20` is the gate that matters most, because the
     * failure it prevents is silent and paid for: the strategy calls `transferFrom` and `transfer`
     * on this address for the rest of its life, and against something that is not a token it can
     * never buy a bag. An address with no code, or one whose `totalSupply()` reverts or is zero,
     * is refused. `InvalidBag` refuses a bag of nothing, which could never be sold, and one above
     * the supply, which could never be brought. The bid bounds are the NFT launch's.
     *
     * @dev `NotERC20` also refuses a collection and a Sweep token. `totalSupply()` is not proof of
     * being fungible: every `ERC721Enumerable` and every ERC721A answers it, and a bag desk pointed
     * at a collection is broken from birth. A Sweep token is refused for the same reason in a
     * different dress: its transfer lock would refuse the desk delivery of every bag it ever paid
     * for. Without this guard both launches would succeed and cost the launch fee to discover.
     */
    function _validateERC20Launch(ERC20Launch memory terms) private view {
        if (hook == address(0)) revert HookNotSet();
        if (burnRouter == address(0)) revert BurnRouterNotSet();
        if (erc20Implementation == address(0)) revert ERC20ImplementationNotSet();
        if (curveImplementation == address(0)) revert CurveImplementationNotSet();
        if (msg.value != launchFee) revert WrongLaunchFee();
        if (
            terms.bidIncreasePerSecond < MIN_BID_INCREASE_PER_SECOND
                || terms.bidIncreasePerSecond > MAX_BID_INCREASE_PER_SECOND || terms.maxBid == 0
                || terms.maxBid > MAX_BID_CAP
        ) {
            revert InvalidBidParameters();
        }
        uint256 supply = _totalSupply(terms.token);
        if (supply == 0 || _isERC721(terms.token) || isStrategy[terms.token]) revert NotERC20();
        if (terms.bagSize == 0 || terms.bagSize > supply) revert InvalidBag();
    }

    /// @notice Clones the fungible implementation and wires the new strategy to everything it will
    /// need. The owner is this factory's, never `msg.sender`, for the reason `_deployStrategy` gives.
    function _deployERC20Strategy(
        ERC20Launch memory terms,
        string calldata name_,
        string calldata symbol_,
        address curve
    ) private returns (address strategy) {
        SweepERC20Strategy.Config memory config;
        config.token = terms.token;
        config.bagSize = terms.bagSize;
        config.burnRouter = burnRouter;
        config.name = name_;
        config.symbol = symbol_;
        config.hook = hook;
        config.poolManager = poolManager;
        config.bidIncreasePerSecond = terms.bidIncreasePerSecond;
        config.maxBid = terms.maxBid;
        config.resaleMultiplierBps = resaleMultiplierBps;
        config.askDecayWindow = 0;
        config.owner = owner();
        config.curve = curve;

        strategy = LibClone.deployERC1967(erc20Implementation);
        SweepERC20Strategy(payable(strategy)).initialize(config);
    }

    /// @notice Clones the implementation and wires the new strategy to everything it will need.
    /// @dev The owner is this factory's, never `msg.sender`. Launching is permissionless precisely
    /// so that it grants nothing: the setters it would otherwise hand over — the bid ceiling, the
    /// distributor list — are power over a contract that will hold other people's money.
    /// @dev The ask decay window is passed as zero: a fixed resale price.
    function _deployStrategy(
        address collection,
        string calldata name_,
        string calldata symbol_,
        uint256 bidIncreasePerSecond,
        uint256 maxBid,
        address curve
    ) private returns (address strategy) {
        SweepNFTStrategy.Config memory config;
        config.collection = collection;
        config.burnRouter = burnRouter;
        config.name = name_;
        config.symbol = symbol_;
        config.hook = hook;
        config.poolManager = poolManager;
        config.bidIncreasePerSecond = bidIncreasePerSecond;
        config.maxBid = maxBid;
        config.resaleMultiplierBps = resaleMultiplierBps;
        config.askDecayWindow = 0;
        config.owner = owner();
        config.curve = curve;

        strategy = LibClone.deployERC1967(strategyImplementation);
        SweepNFTStrategy(payable(strategy)).initialize(config);
    }

    /**
     * @notice Names the hook every future launch welds its pool to. Once, and never again.
     *
     * @dev The one-shot is load-bearing rather than tidy. A v4 pool's identity includes its hook, so
     * every strategy already launched has this address baked into the pool it trades on and into its
     * own `hook` field, which is what its `addFees` is gated on. Repointing the factory would leave
     * those strategies naming a hook that no longer receives their fees, with no way to move them.
     *
     * @dev It is also why this is a setter at all. The hook's address encodes its permissions and is
     * mined over an initcode containing this factory's address, so the hook cannot be built until
     * the factory exists — the dependency is circular and this is the end that gives.
     */
    function setHook(address hook_) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ == address(0)) revert InvalidConfiguration();

        hook = hook_;
        emit HookSet(hook_);
    }

    /**
     * @notice Names where future strategies buy their own token to burn it.
     *
     * @dev Affects future launches only; a strategy holds its own copy from initialisation. Which
     * is why the allow-list entry is added here and the old one never cleared: every strategy
     * launched before this call still burns through the router it was born with, and revoking
     * that router would leave those strategies unable to burn at all. Clearing one is a deliberate
     * `setRouter(old, false)`, made when nothing needs it any more.
     *
     * @dev A burn router that may not swap is a burn router that does nothing, so the two are set
     * in one call rather than two with a silent failure between them. The listing is permanent
     *: strategies born with this router can never follow it out of the list, so
     * delisting it would freeze their burns for good.
     */
    function setBurnRouter(address router) external onlyOwner {
        if (router == address(0)) revert InvalidConfiguration();
        burnRouter = router;
        isRouter[router] = true;
        isPermanentRouter[router] = true;
        emit BurnRouterSet(router);
        emit RouterSet(router, true);
        emit RouterMadePermanent(router);
    }

    /**
     * @notice Admits or removes a router from the set allowed to swap on this protocol's pools.
     *
     * @dev `InvalidConfiguration` refuses the zero address, which could never be a caller and
     * whose presence in the list would only ever be a mistake read back later as intent.
     *
     * @dev What this grants is the power to create ERC-6909 claims on a strategy's token, since a
     * router is the only way that token reaches the PoolManager at all. A router added here that
     * took its output as claims would open an escape from the fee: claims move
     * from wallet to wallet without touching the token, fund a hookless pool, and trade there
     * paying nothing forever. Add only a contract whose settlement you have read.
     *
     * @dev `RouterPermanent` refuses to delist a frozen router — see `setRouterPermanent` for
     * why the freeze exists and what it costs.
     */
    function setRouter(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert InvalidConfiguration();
        if (!allowed && isPermanentRouter[router]) revert RouterPermanent();
        isRouter[router] = allowed;
        emit RouterSet(router, allowed);
    }

    /**
     * @notice Admits a router and freezes it in: it can never be delisted again, by anyone.
     *
     * @dev One-way on purpose. The transfer lock makes the listed routers the
     * only market this token has, so an owner who could empty the list — or an attacker holding
     * that owner's keys — could freeze every holder's exit in two transactions. The base swap
     * and burn routers are frozen at deploy; the price is that a permanent router with a bug can
     * only be routed around by adding a fixed one beside it, never removed, and that is accepted
     * on the record.
     */
    function setRouterPermanent(address router) external onlyOwner {
        if (router == address(0)) revert InvalidConfiguration();
        isRouter[router] = true;
        isPermanentRouter[router] = true;
        emit RouterSet(router, true);
        emit RouterMadePermanent(router);
    }

    /**
     * @notice Names the implementation every future launch's bonding curve is cloned from.
     *
     * @dev `CurveEconomicsMismatch` refuses an implementation whose phantom reserve or
     * graduation threshold disagrees with the constants this factory splits reserves with at
     * graduation: a drift between the two would price the pool at something other than the
     * curve's final spot, silently, on every launch. Existing curves are untouched — a clone
     * keeps the implementation it was born with.
     */
    function setCurveImplementation(address implementation) external onlyOwner {
        if (implementation == address(0)) revert InvalidConfiguration();
        if (
            SweepBondingCurve(payable(implementation)).PHANTOM_QUOTE() != PHANTOM_QUOTE
                || SweepBondingCurve(payable(implementation)).GRADUATION_THRESHOLD() != GRADUATION_THRESHOLD
        ) {
            revert CurveEconomicsMismatch();
        }
        curveImplementation = implementation;
        emit CurveImplementationSet(implementation);
    }

    /// @notice Replaces the fungible implementation every future `launchERC20` clones.
    /// @dev Existing strategies are untouched: a clone points at the implementation it was born
    /// with. Zero is refused so a launch cannot clone nothing.
    function setERC20Implementation(address implementation) external onlyOwner {
        if (implementation == address(0)) revert InvalidConfiguration();
        erc20Implementation = implementation;
        emit ERC20ImplementationSet(implementation);
    }

    /// @notice Replaces the recursive implementation every future `launchRecursive` clones.
    /// @dev Existing strategies are untouched, as for the other two implementations. Zero is refused
    /// so a launch cannot clone nothing.
    function setRecursiveImplementation(address implementation) external onlyOwner {
        if (implementation == address(0)) revert InvalidConfiguration();
        recursiveImplementation = implementation;
        emit RecursiveImplementationSet(implementation);
    }

    /// @notice Changes what future proxies point at.
    /// @dev Every strategy already launched keeps the implementation it was cloned against, since a
    /// proxy stores its own. This decides what the next launch gets, not what the last one runs.
    function setStrategyImplementation(address implementation) external onlyOwner {
        if (implementation == address(0)) revert InvalidConfiguration();
        strategyImplementation = implementation;
        emit StrategyImplementationSet(implementation);
    }

    /// @notice Retunes the price of a launch and where it goes.
    /// @dev A fixed amount of ETH drifts against the dollar, which is the same thing pump.fun's
    /// fixed 0.02 SOL does. It is deliberately settable so the drift can be corrected rather than
    /// lived with. Zero is allowed: a free launch is a decision, not a misconfiguration.
    function setLaunchFee(uint256 fee, address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidConfiguration();
        launchFee = fee;
        launchFeeRecipient = recipient;
        emit LaunchFeeSet(fee, recipient);
    }

    /// @notice Retunes the markup future strategies open their resales at.
    /// @dev Below `BPS` a strategy would list every piece for less than it paid, so the strategy's
    /// own initialiser refuses it; bounding here as well would duplicate that check in a place that
    /// can drift out of step with it.
    function setResaleMultiplier(uint256 multiplierBps) external onlyOwner {
        resaleMultiplierBps = multiplierBps;
        emit ResaleMultiplierSet(multiplierBps);
    }

    /// @notice Clones the curve implementation for one launch. Initialisation happens in
    /// `_open`, after the strategy exists and the supply has moved, because the curve refuses to
    /// initialise over anything less than the whole supply.
    function _deployCurve() private returns (address curve) {
        curve = LibClone.deployERC1967(curveImplementation);
    }

    /**
     * @notice Settles a graduated launch: takes the curve's reserves and opens the strategy's
     * pool at the curve's exact final price. Permissionless — the keeper drives it, anyone may.
     *
     * @dev `UnknownStrategy` refuses an address this factory never launched, whose "curve" would
     * be the zero address and whose "reserves" whatever a hostile contract answers.
     * `AlreadyPooled` refuses a second graduation, which would try to reopen an existing pool
     * and revert deep inside v4 rather than here by name; the curve's own `NothingToComplete`
     * backs it up. The curve refuses `completeGraduation` before its flag, so ungraduated
     * strategies are refused there by name.
     *
     * @dev The order is the guard. The reserves arrive, the pool's token share is computed with
     * the same phantom constant the curve priced with — `tokenOut · ethOut / (ethOut + P)`,
     * which makes the pool's opening price the curve's final spot price — and `assertSeedable`
     * re-proves the mint before anything irreversible. Everything from `completeGraduation` on
     * happens in this one transaction: a failed seed reverts the whole thing back onto the
     * curve, solvent and retryable, which is why no rescue function exists. The
     * excess is measured as this factory's remaining balance rather than recomputed, so mint
     * rounding dust burns with it instead of stranding here.
     */
    function createGraduatedPool(address strategy) external nonReentrant returns (uint256 positionId) {
        address curve = curveOf[strategy];
        if (curve == address(0)) revert UnknownStrategy();
        if (positionIdOf[strategy] != 0) revert AlreadyPooled();

        (uint256 ethOut, uint256 tokenOut) = ISweepBondingCurve(curve).completeGraduation();
        uint256 poolTokens = FixedPointMathLib.fullMulDiv(tokenOut, ethOut, ethOut + PHANTOM_QUOTE);
        SweepGraduationMath.assertSeedable(TICK_SPACING, ethOut, poolTokens);

        uint160 sqrtPriceX96;
        (positionId, sqrtPriceX96) = _seedPool(strategy, ethOut, poolTokens);

        uint256 burned = ISweepCurveToken(strategy).balanceOf(address(this));
        if (burned != 0) SafeTransferLib.safeTransfer(strategy, DEAD_ADDRESS, burned);

        emit StrategyGraduated(strategy, curve, positionId, ethOut, poolTokens, burned, sqrtPriceX96);
    }

    /**
     * @notice Opens the pool and mints the graduation position, full-range, to the dead address.
     *
     * @dev `loadingLiquidity` is raised for exactly the span of the multicall. It is the only
     * gate the hook has on pool creation and on deposits, so outside this window nobody can open
     * a Sweep pool and nobody can add a second position to one that exists — the same gate that
     * guarded the launch-time load when pools were still created at launch.
     *
     * @dev The Permit2 approval is what lets the PositionManager pull the token side; solady's
     * ERC20 grants Permit2 itself an infinite allowance by default, and that is safe on a locked
     * token because an allowance decides who may ask while the lock decides whether the move
     * happens — the pull still lands in `_beforeTokenTransfer` and still needs the transient
     * allowance the hook opens during this window.
     */
    function _seedPool(address strategy, uint256 ethAmount, uint256 tokenAmount)
        private
        returns (uint256 positionId, uint160 sqrtPriceX96)
    {
        sqrtPriceX96 = SweepGraduationMath.sqrtPriceX96FromAmounts(ethAmount, tokenAmount);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(strategy),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        permit2.approve(strategy, address(positionManager), type(uint160).max, type(uint48).max);
        positionId = positionManager.nextTokenId();
        positionIdOf[strategy] = positionId;

        loadingLiquidity = true;
        positionManager.multicall{value: ethAmount}(_graduationCalls(key, sqrtPriceX96, ethAmount, tokenAmount));
        loadingLiquidity = false;
    }

    /**
     * @notice The two calls that open the pool and fill it, encoded for the PositionManager.
     *
     * @dev Split out of `_seedPool` to keep both inside the reachable stack without `via_ir`,
     * which `forge coverage` cannot use. The split is a compiler constraint, not a boundary.
     *
     * @dev Unlike the launch-time load this replaces, the position is two-sided: all the swept
     * ETH against the pool's token allocation, so the mint carries value and the action list
     * ends with a `SWEEP` of the native side — liquidity rounds down, and without the sweep the
     * unabsorbed wei would strand in the PositionManager. They go to the dead address, which
     * accepts ETH unconditionally: sent to the launch fee recipient instead, a recipient that
     * refuses ETH would turn one wei of dust into a revert of every graduation. Wei-scale, and
     * disclosed. The token side's rounding remainder stays in the factory and is burnt by the
     * caller.
     */
    function _graduationCalls(PoolKey memory key, uint160 sqrtPriceX96, uint256 ethAmount, uint256 tokenAmount)
        private
        view
        returns (bytes[] memory params)
    {
        (int24 tickLower, int24 tickUpper) = SweepGraduationMath.fullRangeTicks(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            tokenAmount
        );

        bytes[] memory mintParams = new bytes[](3);
        mintParams[0] = abi.encode(
            key, tickLower, tickUpper, liquidity, uint128(ethAmount), uint128(tokenAmount), DEAD_ADDRESS, bytes("")
        );
        mintParams[1] = abi.encode(key.currency0, key.currency1);
        mintParams[2] = abi.encode(key.currency0, DEAD_ADDRESS);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));

        params = new bytes[](2);
        params[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (key, sqrtPriceX96));
        params[1] =
            abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, mintParams), block.timestamp));
    }

    /// @notice Accepts a graduating curve's reserves, and nothing else.
    /// @dev The reserves arrive as a plain transfer inside `completeGraduation`; refusing every
    /// other sender keeps "the factory holds no ETH between transactions" true, which is what
    /// makes a zero launch fee workable and what keeps a mistaken send from stranding here.
    receive() external payable {
        if (strategyOfCurve[msg.sender] == address(0)) revert DirectPaymentRejected();
    }

    /// @notice Who may retune this factory and who owns every strategy it launches.
    /// @dev Disambiguates solady's `Ownable` from `ISweepFactory`, which declares the same accessor
    /// because the hook reads it to gate its own protocol settings. One authority, named twice.
    function owner() public view override(Ownable, ISweepFactory) returns (address) {
        return Ownable.owner();
    }

    /// @notice Who owns `collection`, or the zero address if it does not say.
    /// @dev The same read the hook makes to decide who may claim the creator share, so a collection
    /// that can launch itself is exactly a collection that can claim its fee — one notion of owner,
    /// not two. A static call rather than an interface call, because `owner()` is not part of
    /// ERC-721 and its absence must mean "refused", not "reverted with someone else's error".
    function _collectionOwner(address collection) private view returns (address) {
        (bool ok, bytes memory data) = collection.staticcall(abi.encodeCall(IOwnable.owner, ()));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    /// @notice The total supply `token` reports, or zero if it has no code or does not answer.
    /// @dev A low-level call rather than an interface call, so an EOA or a contract without
    /// `totalSupply` is refused with `NotERC20` instead of reverting with whatever its fallback does.
    function _totalSupply(address token) private view returns (uint256) {
        if (token.code.length == 0) return 0;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @notice Whether `collection` claims to be an ERC-721.
    /// @dev A low-level call rather than an interface call, so a contract with no `supportsInterface`
    /// at all is refused with `NotERC721` instead of reverting with whatever its fallback does.
    function _isERC721(address collection) private view returns (bool) {
        (bool ok, bytes memory data) =
            collection.staticcall(abi.encodeWithSignature("supportsInterface(bytes4)", ERC721_INTERFACE_ID));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }
}
