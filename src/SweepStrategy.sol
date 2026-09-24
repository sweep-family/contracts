// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    sweeping the floor, one cycle at a time
*/

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {SweepToken} from "./SweepToken.sol";
import {ISweepFeeReceiver} from "./interfaces/ISweepFeeReceiver.sol";

/**
 * @title SweepStrategy
 * @author 0xDAVZER
 * @notice The bookkeeping of the machine every desk runs, on top of the token it is. What the
 * machine buys is left to the concrete strategy.
 *
 * @dev Three responsibilities, separated because they fail differently: the treasury that funds
 * purchases, the bid the protocol publishes, and the burn that turns sale proceeds into destroyed
 * supply. The token and its transfer lock live in `SweepToken`.
 *
 * The swap that performs a burn deliberately lives in `_executeBurn`, implemented downstream, so
 * this contract can be tested exhaustively with no pool in existence.
 */
abstract contract SweepStrategy is SweepToken, ISweepFeeReceiver {
    /// @notice Paid to whoever triggers a burn pass.
    /// @dev A burn benefits every holder diffusely and nobody individually, so without a bounty
    /// nobody ever calls it. Contrast the purchase, which pays nothing because the seller wanting
    /// their money is motive enough.
    uint256 public constant BURN_CALLER_REWARD_BPS = 50;

    /// @notice Longest gap the owner may put between burn passes.
    /// @dev Bounds the retuning setter so it cannot be used to switch the burn off entirely. A
    /// cooldown of a year would freeze the queue for practical purposes while leaving the mechanism
    /// nominally in place, which is worse than removing it because it still reads as working.
    uint256 public constant MAX_BURN_COOLDOWN = 1 days;

    /// @notice How fast the published bid climbs, per second of waiting.
    /// @dev Per second rather than per block. Block time is a property of the chain: Robinhood
    /// Chain produces one every ~101 ms, so a block-paced ramp climbs 119x faster here than on
    /// Ethereum — and an Orbit operator can change block production, moving the economics on the
    /// same chain with no warning.
    uint256 public bidIncreasePerSecond;

    /// @notice Ceiling the bid may never exceed, however long nobody sells.
    /// @dev Without it the ramp always eventually passes the price above which a purchase cannot be
    /// resold at a markup, and the protocol condemns itself to holding the asset. The bound that
    /// actually matters is `floor / resaleMultiplier`, which needs a floor price and therefore
    /// cannot be computed on-chain — so this is an explicit parameter. It does not solve the
    /// problem; it turns an unbounded drift into a number somebody chose and can be held to.
    uint256 public maxBid;

    /// @notice When the last purchase happened, which is where the ramp restarts.
    uint256 public lastPurchaseAt;

    /// @notice ETH available to buy assets with.
    uint256 public treasury;

    /// @notice ETH from asset sales, waiting to be turned into destroyed supply.
    /// @dev Never mixes with `treasury`. Crossing the two would let sale proceeds fund purchases
    /// and quietly turn the machine into a fund.
    uint256 public pendingBurn;

    /// @notice Most a single burn pass may spend.
    uint256 public burnIncrement;

    /// @notice Minimum seconds between burn passes.
    ///
    /// @dev Seconds, not blocks. One block is twelve seconds on Ethereum and about a tenth of a
    /// second here, so a block-paced cooldown would remove the rate limit entirely rather than
    /// enforce it. Twelve seconds is the intended rhythm.
    ///
    /// The pacing exists so a large queue drains as a schedule rather than as one market order,
    /// which on a thin pool is simply an invitation to be sandwiched.
    uint256 public burnCooldown;

    /// @notice When the last burn pass ran.
    /// @dev Deliberately left at zero by the initializer rather than set to the deployment time.
    /// The cooldown exists to space passes apart so a backlog drains as a schedule; anchoring it at
    /// launch would delay the very first pass for no reason, since there cannot be a backlog before
    /// anything has been sold.
    uint256 public lastBurnAt;

    error NothingToBurn();
    error BurnCooldownNotElapsed();

    event FeesReceived(uint256 amount, uint256 treasury);
    event SaleRecorded(uint256 proceeds, uint256 pendingBurn);
    event PurchaseRecorded(uint256 cost, uint256 treasury);
    event Burned(address indexed caller, uint256 spent, uint256 reward);
    event BurnPacingUpdated(uint256 increment, uint256 cooldown);
    event BidParametersUpdated(uint256 increasePerSecond, uint256 cap);

    /**
     * @notice Wires the strategy on top of its token, which mints the entire supply to the caller.
     * @dev `maxBid` of zero would leave the strategy unable to ever buy, and a zero increase per
     * second would leave the bid pinned at nothing, so both are refused rather than deployed dead.
     * The token's own guards (hook, pool manager, owner) run in `__SweepToken_init`.
     */
    function __SweepStrategy_init(
        string memory name_,
        string memory symbol_,
        address hook_,
        address poolManager_,
        uint256 bidIncreasePerSecond_,
        uint256 maxBid_,
        address owner_
    ) internal onlyInitializing {
        if (bidIncreasePerSecond_ == 0 || maxBid_ == 0) revert InvalidConfiguration();

        __SweepToken_init(name_, symbol_, hook_, poolManager_, owner_);
        bidIncreasePerSecond = bidIncreasePerSecond_;
        maxBid = maxBid_;

        burnIncrement = 1 ether;
        burnCooldown = 12;
        lastPurchaseAt = block.timestamp;
    }

    /**
     * @notice What the protocol will pay right now for one unit of the asset it buys.
     *
     * @dev The protocol has no oracle and cannot see an off-chain listing, so it cannot ask what
     * something is worth. Instead it publishes what it will pay and lets that climb until a seller
     * finds it worth taking — a reverse Dutch auction where the seller supplies the price
     * discovery, and where the only cost of waiting is that someone else may take the offer first.
     *
     * @dev The smallest of three bounds, all computed on read so none can drift out of sync with
     * the others: the ramp since the last purchase, the configured ceiling, and what the treasury
     * actually holds. A stored ramp re-pinned only when a single fee deposit exceeds the increment
     * never re-pins in low volume, so the published bid drifts far above the treasury and the
     * auction stops meaning anything for hours at a time.
     */
    function currentBid() public view returns (uint256) {
        uint256 ramped = (block.timestamp - lastPurchaseAt) * bidIncreasePerSecond;
        uint256 bid = ramped < maxBid ? ramped : maxBid;
        return bid < treasury ? bid : treasury;
    }

    /// @notice Funds the treasury from a swap's fee.
    /// @dev Restricted to the hook because it is the only thing that observes a swap; anyone else
    /// sending ETH here would inflate the bid without a trade having happened.
    function addFees() external payable onlyHook {
        treasury += msg.value;
        emit FeesReceived(msg.value, treasury);
    }

    /**
     * @notice Spends one increment of pending proceeds on buying and burning the token.
     *
     * @dev Permissionless and paid, because a burn benefits every holder diffusely and nobody
     * individually. Rate-limited and capped per pass so a large backlog is drained as a schedule
     * rather than as one market order, which on a thin pool would simply be sandwiched.
     *
     * @dev Pays the caller before swapping so a failed swap cannot leave the reward stranded, and
     * the swap itself is deferred to `_executeBurn` so this accounting can be tested with no pool
     * in existence.
     */
    function processBurn() external nonReentrant returns (uint256 spent, uint256 reward) {
        if (pendingBurn == 0) revert NothingToBurn();
        if (block.timestamp < lastBurnAt + burnCooldown) revert BurnCooldownNotElapsed();

        uint256 pass = pendingBurn < burnIncrement ? pendingBurn : burnIncrement;
        reward = (pass * BURN_CALLER_REWARD_BPS) / BPS;
        spent = pass - reward;

        pendingBurn -= pass;
        lastBurnAt = block.timestamp;

        if (reward != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, reward);
        if (spent != 0) _executeBurn(spent);

        emit Burned(msg.sender, spent, reward);
    }

    /**
     * @notice Retunes what the protocol is willing to pay, and how fast it gets there.
     *
     * @dev The most consequential lever in the contract, and the one that was frozen longest. A cap
     * set too low at launch leaves a strategy unable to ever buy anything: the treasury fills behind
     * a ceiling it can never cross, and the machine looks alive while doing nothing.
     *
     * @dev The cap is also the protocol's only protection against overpaying, so a settable cap is
     * a power over funds — the same category as `setDistributor`. Note that on an upgradeable proxy
     * this grants nothing new: an owner who can replace the implementation can already do anything
     * a setter would allow. The decision that actually carries weight is the upgradeability itself,
     * not this function.
     */
    function setBidParameters(uint256 increasePerSecond, uint256 cap) external onlyOwner {
        if (increasePerSecond == 0 || cap == 0) revert InvalidConfiguration();
        bidIncreasePerSecond = increasePerSecond;
        maxBid = cap;
        emit BidParametersUpdated(increasePerSecond, cap);
    }

    /**
     * @notice Retunes how fast the burn queue drains.
     *
     * @dev Without this, a strategy launched with the wrong rhythm is stuck with it for life short
     * of upgrading the proxy. The unit is not adjustable and never will be — seconds are baked into
     * `processBurn` — only the duration moves.
     *
     * @dev Both bounds are load-bearing. A zero increment makes every pass a no-op that still
     * consumes the cooldown, freezing the queue while appearing to work. A zero cooldown lets a
     * whole queue drain inside one block, which is the single market order the pacing exists to
     * prevent. And an unbounded cooldown would let this setter switch the burn off while leaving it
     * nominally in place, which reads as working and is therefore worse than removing it.
     */
    function setBurnPacing(uint256 increment, uint256 cooldown) external onlyOwner {
        if (increment == 0 || cooldown == 0 || cooldown > MAX_BURN_COOLDOWN) {
            revert InvalidConfiguration();
        }
        burnIncrement = increment;
        burnCooldown = cooldown;
        emit BurnPacingUpdated(increment, cooldown);
    }

    /// @notice Buys the token on its own pool and sends it to the dead address.
    /// @dev Left to the concrete strategy, which knows the pool and the router. Keeping it out of
    /// the base is what lets every rule above be tested before a pool exists.
    function _executeBurn(uint256 amountIn) internal virtual;

    /// @dev Books a purchase: the treasury pays, and the ramp restarts from nothing.
    function _recordPurchase(uint256 cost) internal {
        treasury -= cost;
        lastPurchaseAt = block.timestamp;
        emit PurchaseRecorded(cost, treasury);
    }

    /// @dev Books a sale. Proceeds join the burn queue and never the treasury.
    function _recordSale(uint256 proceeds) internal {
        pendingBurn += proceeds;
        emit SaleRecorded(proceeds, pendingBurn);
    }
}
