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
import {ISweepFactory, ISweepHooked} from "./interfaces/ISweepFactory.sol";

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

    /// @notice Largest burn pass the owner may set.
    /// @dev The graduated pool's depth is fixed at its ~4.2 ETH seed, and the burn swap takes
    /// the pool's price as it finds it. On a fork, a one-transaction sandwich around a pass
    /// turned a profit from about 0.33 ETH up (audit 2026-10-02, M-2); this bound sits below it.
    uint256 public constant MAX_BURN_INCREMENT = 0.25 ether;

    /// @notice Slowest ramp the owner may set, mirroring the factory's launch gate: below it the
    /// bid never reaches a floor price within any useful horizon and the machine looks alive
    /// while being unable to buy anything.
    uint256 public constant MIN_BID_INCREASE_PER_SECOND = 0.000_001 ether;

    /// @notice Fastest ramp the owner may set, mirroring the factory's launch gate: above it the
    /// reverse auction resolves faster than anyone can watch it.
    uint256 public constant MAX_BID_INCREASE_PER_SECOND = 0.01 ether;

    /// @notice Highest ceiling the owner may ever set. The launch gate bounds what a stranger
    /// types; this bounds what the owner can do afterwards, which is the promise that the bid
    /// can never be pointed at a whole treasury in one move (decision 0015).
    uint256 public constant MAX_BID_CAP = 100 ether;

    /// @notice How long the owner must wait between raises of either bid parameter.
    uint256 public constant BID_RAISE_COOLDOWN = 7 days;

    /// @notice How long a desk must publish its whole bid, with nobody selling, before its owner
    /// may retire it (decision 0017).
    /// @dev Counted after the ramp has reached `min(maxBid, treasury)`, never from the last
    /// purchase alone, so a desk still climbing toward a dear floor is never mistaken for a dead
    /// one. A month is long enough for any market that exists to answer a standing offer.
    uint256 public constant RETIRE_GRACE = 30 days;

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

    /// @notice Where the bid ramp starts, in whole seconds: the launch, the last purchase that used
    /// up the whole bid, or the point a partial purchase moved it to. Graduation does not move it
    /// (decision 0021).
    uint256 public lastPurchaseAt;

    /// @notice Wei of ramp already spent since `lastPurchaseAt`, always below one second of ramp
    /// once a purchase is booked (SC-07). Kept in wei so a purchase lowers the bid by exactly its
    /// cost, never by a whole second.
    uint256 public rampSpent;

    /// @notice When the owner last raised the bid ramp or its ceiling. Raises are paced by
    /// `BID_RAISE_COOLDOWN`; lowering is always free and does not touch this clock.
    uint256 public lastBidRaiseAt;

    /// @notice The highest bid ramp and ceiling ever in force, which the owner may return to at
    /// once after lowering (SC-09 of the 2 October audit).
    uint256 public restorableIncreasePerSecond;
    uint256 public restorableMaxBid;

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
    /// @dev Seconds, not blocks. The reference waits one block, which is twelve seconds on Ethereum
    /// and about a tenth of a second here — porting the constant would have removed the rate limit
    /// entirely rather than translated it. Twelve seconds reproduces what they actually meant.
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

    /// @notice When the bid terms last changed, in either direction, by the owner or a bid
    /// manager. `retire` waits a full `RETIRE_GRACE` after it, so lowering the bid as a brake
    /// never makes a desk retirable.
    uint256 public lastBidChangeAt;

    /// @notice Whether the desk has been retired: it buys nothing again, and its treasury drains
    /// into the burn one pass at a time (decision 0017). Final once set.
    bool public retired;

    /// @notice Whether the launch has graduated into its pool, set by the curve's notice. Before
    /// it nothing can buy the token, so a sale's proceeds go back to the treasury instead of the
    /// burn queue, and the desk cannot be retired (decision 0021, audit H-1 of PR #74).
    bool public graduated;

    error NothingToBurn();
    error StillOnCurve();
    error BurnCooldownNotElapsed();
    error BidRaiseTooLarge();
    error BidRaiseTooSoon();
    error AlreadyRetired();
    error NothingToRetire();
    error DeskStillBidding();
    error NotBidManager();
    error BidAboveRestorable();

    event FeesReceived(uint256 amount, uint256 treasury);
    event SaleRecorded(uint256 proceeds, uint256 pendingBurn);
    event SaleRecycled(uint256 proceeds, uint256 treasury);
    event PurchaseRecorded(uint256 cost, uint256 treasury);
    event Burned(address indexed caller, uint256 spent, uint256 reward);
    event BurnPacingUpdated(uint256 increment, uint256 cooldown);
    event BidParametersUpdated(uint256 increasePerSecond, uint256 cap);
    event Retired(address indexed caller, uint256 treasury);
    event TreasuryReleased(uint256 amount, uint256 treasury);

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
        restorableIncreasePerSecond = bidIncreasePerSecond_;
        restorableMaxBid = maxBid_;

        burnIncrement = 0.1 ether;
        burnCooldown = 12;
        lastPurchaseAt = block.timestamp;
        lastBidRaiseAt = block.timestamp;
        lastBidChangeAt = block.timestamp;
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
     * actually holds. The reference stored a re-pinned ramp instead and re-pinned it only when a
     * single fee deposit exceeded the increment, which in low volume never fires — observed live as
     * a 36.98 ETH bid against a 0.43 ETH treasury, with the auction irrelevant for twelve hours.
     *
     * @dev A retired desk bids nothing, which is how retirement stops every purchase without
     * either desk's buy path needing a check of its own: the NFT desk refuses any value above a
     * zero bid, and the bag desk refuses to buy at zero.
     */
    function currentBid() public view returns (uint256) {
        if (retired) return 0;
        uint256 ramped = (block.timestamp - lastPurchaseAt) * bidIncreasePerSecond;
        ramped = ramped > rampSpent ? ramped - rampSpent : 0;
        uint256 bid = ramped < maxBid ? ramped : maxBid;
        return bid < treasury ? bid : treasury;
    }

    /// @notice Funds the treasury from a trade's fee: a pool swap's, through the hook, or a curve
    /// trade's, through the launch's curve (decision 0021).
    /// @dev Restricted to those two because they are the only things that observe a trade; anyone
    /// else sending ETH here would inflate the bid without a trade having happened.
    function addFees() external payable onlyFeeSource {
        _creditTreasury(msg.value);
        emit FeesReceived(msg.value, treasury);
    }

    /**
     * @notice The curve's graduation notice: records that the pool now exists.
     *
     * @dev It leaves the bid ramp alone, since the desk has been running since launch (decision
     * 0021). What it switches is the fate of a sale: from here on proceeds queue for the burn,
     * which the pool can now run, and `retire` becomes possible. Restricted to the curve so the
     * notice cannot be forged.
     */
    function markGraduated() external virtual override onlyCurve {
        graduated = true;
    }

    /**
     * @dev Adds to the treasury without letting the new money be bid all at once.
     *
     * @dev The bid is `min(ramp, maxBid, treasury)`, and the ramp keeps climbing while the treasury
     * is too small to buy anything. Left alone, a desk idle for a day held a whole day of ramp above
     * its treasury, and the block a large fee landed — the crossing buy, a burst of pool trades, a
     * recycled sale — the bid jumped to the cap: on the fork, a 0.0004 ETH floor piece sold for ten
     * times its price in that block (audit C-2 of PR #74). So when the treasury is what binds the
     * bid, the ramp is first brought down to stand exactly at the treasury as it was; the new money
     * then becomes biddable at the ramp's pace, as an ascending auction should release it. When the
     * cap binds instead, new money changes no bid and the ramp is left where it is, which also keeps
     * `retire`'s clock running on a dead desk whose fees keep arriving.
     */
    function _creditTreasury(uint256 amount) internal {
        uint256 before = treasury;
        if (before < maxBid) _bringRampDownTo(before);
        treasury = before + amount;
    }

    /**
     * @dev Lowers the standing ramp to exactly `ceiling` when it has climbed above it, in the
     * representation the ramp is kept in: whole seconds in `lastPurchaseAt`, the wei below one
     * second in `rampSpent`. A ramp at or below the ceiling is left untouched.
     */
    function _bringRampDownTo(uint256 ceiling) internal {
        uint256 increase = bidIncreasePerSecond;
        uint256 grown = (block.timestamp - lastPurchaseAt) * increase;
        uint256 standing = grown > rampSpent ? grown - rampSpent : 0;
        if (standing <= ceiling) return;
        uint256 secondsToCeiling = (ceiling + increase - 1) / increase;
        lastPurchaseAt = block.timestamp - secondsToCeiling;
        rampSpent = secondsToCeiling * increase - ceiling;
    }

    /**
     * @notice Spends one increment of pending proceeds on buying and burning the token.
     *
     * @dev Permissionless and paid, because a burn benefits every holder diffusely and nobody
     * individually. Rate-limited and capped per pass so a large backlog is drained as a schedule
     * rather than as one market order, which on a thin pool would simply be sandwiched.
     *
     * @dev A pass is the smallest of the queue, the owner's increment and `_burnBound`, the share
     * of the pool's live depth one buy may take: the increment alone is a constant, and a pool
     * whose price has fallen is shallow enough for a constant pass to be sandwiched again (review
     * of the fixes, 2026-10-02). `NothingToBurn` also refuses a pass the bound has rounded to
     * zero, which would otherwise burn nothing and still consume the cooldown.
     *
     * @dev On a retired desk the queue is first topped up from the treasury to one increment
     * (`_releaseRetiredTreasury`). `NothingToBurn` therefore also counts a retired treasury still
     * waiting to drain, or a retired desk with an empty queue would never burn again. The release
     * runs after the cooldown check, so it is paced exactly like the pass it feeds.
     *
     * @dev The swap itself is deferred to `_executeBurn` so this accounting can be tested with no
     * pool in existence. The caller's reward is booked before the swap, and a swap that fails
     * reverts the whole pass, reward included.
     */
    function processBurn() external nonReentrant returns (uint256 spent, uint256 reward) {
        if (pendingBurn == 0 && !(retired && treasury != 0)) revert NothingToBurn();
        if (block.timestamp < lastBurnAt + burnCooldown) revert BurnCooldownNotElapsed();
        _releaseRetiredTreasury();

        uint256 pass = pendingBurn < burnIncrement ? pendingBurn : burnIncrement;
        uint256 bound = _burnBound();
        if (bound < pass) pass = bound;
        if (pass == 0) revert NothingToBurn();
        reward = (pass * BURN_CALLER_REWARD_BPS) / BPS;
        spent = pass - reward;

        pendingBurn -= pass;
        lastBurnAt = block.timestamp;

        if (reward != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, reward);
        if (spent != 0) _executeBurn(spent);

        emit Burned(msg.sender, spent, reward);
    }

    /**
     * @notice Retires a desk that can no longer buy anything, so its treasury turns into
     * buyback-and-burn instead of sitting frozen for good (decision 0017). Owner only.
     *
     * @dev The desks this exists for are the ones that cannot buy: a target that blocklisted the
     * desk, paused for good, charges a fee on every transfer, or sells a bag no bid can reach.
     * Without it their treasury has no spender but a purchase that can never happen, and every fee
     * the hook pays in afterwards is lost with it.
     *
     * @dev `onlyOwner` is the first guard, because retirement is final and the test of death
     * below cannot tell a dead desk from a saving one. It judges against the treasury as it
     * stands now, and a healthy desk saving toward a floor it cannot yet afford holds a treasury
     * the ramp passes within minutes; a month without a purchase later it passes the test while
     * fees are still arriving. Without the gate any stranger could shut that desk forever.
     * Decision 0017 made `retire` permissionless; the 4 October re-audit found this case and the
     * gate replaced it. The accepted cost is that a truly dead desk stays frozen until its owner
     * (the Safe, for protocol launches) acts.
     *
     * @dev `AlreadyRetired` keeps the event and the moment single. `StillOnCurve` refuses a desk
     * whose launch has not graduated: retiring turns the treasury into burn queue, and before the
     * pool exists nothing can run that queue, so a desk retired on its curve would only strand its
     * treasury and every curve fee after it (audit H-1 of PR #74). `NothingToRetire` refuses a
     * desk with an empty treasury: retiring it would release nothing.
     *
     * @dev `DeskStillBidding` is the test of death, and it binds the owner too. The desk must
     * have published its whole bid, `min(maxBid, treasury)`, for `RETIRE_GRACE` beyond the moment
     * the ramp got there, with no purchase. Measuring from the last purchase alone would let a
     * desk whose slow ramp is still climbing toward a dear floor be retired. A purchase restarts
     * the measure, and a dead desk cannot complete one, so nobody can keep a dead desk alive with
     * purchases of nothing.
     *
     * @dev The same test also waits `RETIRE_GRACE` after the owner last changed the bid terms.
     * Lowering the bid is the owner's brake, and against the lowered ceiling a braked desk looks
     * as though it has offered everything it has. Without the wait, braking a desk would make it
     * retirable at once, for good. With it, a brake shorter than the grace never does; a brake
     * held for the whole grace does, and then the frozen treasury goes to the burn, never to a
     * person.
     */
    function retire() external onlyOwner nonReentrant {
        if (retired) revert AlreadyRetired();
        if (!graduated) revert StillOnCurve();
        if (treasury == 0) revert NothingToRetire();
        uint256 full = maxBid < treasury ? maxBid : treasury;
        uint256 waited = block.timestamp - lastPurchaseAt;
        if (
            waited < RETIRE_GRACE || (waited - RETIRE_GRACE) * bidIncreasePerSecond < full
                || block.timestamp < lastBidChangeAt + RETIRE_GRACE
        ) {
            revert DeskStillBidding();
        }

        retired = true;
        emit Retired(msg.sender, treasury);
    }

    /**
     * @notice Retunes what the protocol is willing to pay, and how fast it gets there.
     *
     * @dev The most consequential lever in the contract, and the one that was frozen longest. A cap
     * set too low at launch leaves a strategy unable to ever buy anything: the treasury fills behind
     * a ceiling it can never cross, and the machine looks alive while doing nothing.
     *
     * @dev The cap is the protocol's only protection against overpaying, so a settable cap is a
     * power over funds — the same category as `setDistributor` — and the strategies are not
     * upgradeable, so this setter is the whole of that power. It is bounded three ways
     * (decision 0015). The absolute bounds mirror the factory's launch gates, so the owner can
     * never set what a launch could not have opened with. Raising either parameter is capped at
     * double its current value and paced to once per `BID_RAISE_COOLDOWN`: without the pacing, a
     * compromised owner walks the cap to the treasury in one transaction and drains it through a
     * single sale; with it, every raise is a public event days ahead of the money it could ever
     * move. Lowering is always free, because a lower bid endangers nobody, and it must never
     * consume the raise clock or an owner de-risking a strategy would lock themselves out of
     * re-tuning it.
     *
     * @dev Returning to terms that were already in force is not a raise (SC-09 of the 2 October
     * audit). Lowering is the owner's only brake on a desk, and with every return paced at 2x a
     * week, a brake applied at the minimum took about a year to release: the same lever froze a
     * desk for a year in a compromised owner's hands, and kept an honest owner from undoing an
     * emergency stop. Terms at or below `restorableIncreasePerSecond` and `restorableMaxBid`, the
     * highest values ever in force, apply at once and leave the raise clock alone. They were
     * public when they first took effect, which is what the pacing exists to guarantee.
     */
    function setBidParameters(uint256 increasePerSecond, uint256 cap) external onlyOwner {
        _requireBidInBounds(increasePerSecond, cap);
        bool raising = increasePerSecond > bidIncreasePerSecond || cap > maxBid;
        bool restoring = increasePerSecond <= restorableIncreasePerSecond && cap <= restorableMaxBid;
        if (raising && !restoring) {
            if (increasePerSecond > bidIncreasePerSecond * 2 || cap > maxBid * 2) revert BidRaiseTooLarge();
            if (block.timestamp < lastBidRaiseAt + BID_RAISE_COOLDOWN) revert BidRaiseTooSoon();
            lastBidRaiseAt = block.timestamp;
        }
        bidIncreasePerSecond = increasePerSecond;
        maxBid = cap;
        lastBidChangeAt = block.timestamp;
        if (increasePerSecond > restorableIncreasePerSecond) restorableIncreasePerSecond = increasePerSecond;
        if (cap > restorableMaxBid) restorableMaxBid = cap;
        emit BidParametersUpdated(increasePerSecond, cap);
    }

    /**
     * @notice Moves the bid anywhere at or below the highest terms ever in force, at once. Open to
     * the owner and to any address the desk's factory lists as a bid manager (decision 0019).
     *
     * @dev Exists for the launch-high-then-lower pattern of audit H-1. A desk whose bid sits far
     * above its collection's floor pays anyone holding one piece the whole bid, so a desk opens
     * with a high ceiling, which sets its restorable highs, and is lowered at once to near the
     * floor. When the floor rises, the bid must follow before the desk is simply never sold to,
     * and waiting for the Safe is too slow; the protocol's keepers follow it here instead.
     *
     * @dev `NotBidManager` refuses everyone but the owner and the managers of this desk's own
     * factory. The factory is read through the hook, as `setBurnRouter` reads it, because the hook
     * is fixed at initialisation and its factory reference is immutable: there is nothing the
     * owner, a manager or a stranger can repoint to make another factory's listing count here.
     * The owner is checked first so the owner's path never depends on the factory answering.
     *
     * @dev `InvalidConfiguration` applies the absolute bounds of `setBidParameters`, so this path
     * can never write what that one could not.
     *
     * @dev `BidAboveRestorable` is the whole of the security bound. Without it a manager is an
     * owner with no pacing, and one stolen keeper key walks every desk's ceiling to the treasury
     * and drains it through a single sale. With it, a compromised manager can do two things: set
     * the bid anywhere up to the restorable highs, which is H-1's exposure capped at what the
     * owner chose at launch, or hold a desk's bid down, which the owner undoes with
     * `setBidParameters` after delisting the manager with `setBidManager(manager, false)`. It can
     * never raise a ceiling, move funds or touch any other parameter. The restorable highs are
     * deliberately never written here: only the owner's paced `setBidParameters` raises them, so
     * the bound a manager works under is one the owner set and the public saw take effect.
     *
     * @dev Nothing here is a raise in the sense of `BID_RAISE_COOLDOWN`, so the raise clock is
     * left alone and the owner's next genuine raise is unaffected. `lastBidChangeAt` is stamped,
     * as for any change of terms: `retire` judges against the ceiling in force, and a bid a
     * manager has lowered would otherwise read as a desk that has offered everything it has. The
     * cost is that a keeper retuning a desk keeps restarting the retire grace; an owner who wants
     * to retire a desk a keeper is following must first have the keeper stop, or delist it.
     */
    function manageBid(uint256 increasePerSecond, uint256 cap) external {
        if (msg.sender != owner() && !ISweepFactory(ISweepHooked(hook).factory()).isBidManager(msg.sender)) {
            revert NotBidManager();
        }
        _requireBidInBounds(increasePerSecond, cap);
        if (increasePerSecond > restorableIncreasePerSecond || cap > restorableMaxBid) revert BidAboveRestorable();
        bidIncreasePerSecond = increasePerSecond;
        maxBid = cap;
        lastBidChangeAt = block.timestamp;
        emit BidParametersUpdated(increasePerSecond, cap);
    }

    /**
     * @notice Retunes how fast the burn queue drains.
     *
     * @dev Neither the reference nor our first draft had this, so a strategy launched with the wrong
     * rhythm was stuck with it for life short of upgrading the proxy. The unit is not adjustable and
     * never will be — seconds are baked into `processBurn` — only the duration moves.
     *
     * @dev Both bounds are load-bearing. A zero increment makes every pass a no-op that still
     * consumes the cooldown, freezing the queue while appearing to work. A zero cooldown lets a
     * whole queue drain inside one block, which is the single market order the pacing exists to
     * prevent. An increment above `MAX_BURN_INCREMENT` makes each pass worth sandwiching on the
     * graduated pool's fixed ~4.2 ETH depth (audit 2026-10-02, M-2). And an unbounded cooldown would let this setter switch the burn off while leaving it
     * nominally in place, which reads as working and is therefore worse than removing it.
     */
    function setBurnPacing(uint256 increment, uint256 cooldown) external onlyOwner {
        if (increment == 0 || increment > MAX_BURN_INCREMENT || cooldown == 0 || cooldown > MAX_BURN_COOLDOWN) {
            revert InvalidConfiguration();
        }
        burnIncrement = increment;
        burnCooldown = cooldown;
        emit BurnPacingUpdated(increment, cooldown);
    }

    /**
     * @dev The absolute bounds every bid change answers to, whoever makes it. They mirror the
     * factory's launch gates (decision 0015): a ramp below the minimum never reaches a floor in
     * any useful horizon, one above the maximum resolves faster than anyone can watch, a zero cap
     * leaves the desk unable ever to buy while looking alive, and a cap above `MAX_BID_CAP` is the
     * whole-treasury bid the decision rules out.
     */
    function _requireBidInBounds(uint256 increasePerSecond, uint256 cap) internal pure {
        if (
            increasePerSecond < MIN_BID_INCREASE_PER_SECOND || increasePerSecond > MAX_BID_INCREASE_PER_SECOND
                || cap == 0 || cap > MAX_BID_CAP
        ) {
            revert InvalidConfiguration();
        }
    }

    /// @notice The largest buy one burn pass may make on the pool right now.
    /// @dev Unbounded here, where no pool exists; the desk reads it from its burn router.
    function _burnBound() internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Buys the token on its own pool and sends it to the dead address.
    /// @dev Left to the concrete strategy, which knows the pool and the router. Keeping it out of
    /// the base is what lets every rule above be tested before a pool exists.
    function _executeBurn(uint256 amountIn) internal virtual;

    /**
     * @dev Books a purchase: the treasury pays, and the ramp gives up exactly what was spent.
     *
     * @dev Restarting the ramp from nothing on every purchase let a one-wei purchase erase the
     * whole bid: a holder sold a piece to the desk for one wei and bought it back at a one-wei ask
     * in the same transaction, for gas only, and the desk never reached a real price again (SC-07
     * of the 2 October audit, DD-4 of the deep dive). The ramp now gives up the purchase's cost in
     * wei, carried in `rampSpent` and folded into whole seconds of `lastPurchaseAt` as it adds up.
     * Counting in seconds instead would make every one-wei purchase cost the bid a whole second
     * of ramp, and a loop of them would still empty it. A purchase at the whole bid restarts the
     * ramp at zero; a purchase below the bid leaves exactly the rest standing.
     *
     * @dev Before spending, a ramp that has climbed past the binding ceiling, `min(maxBid,
     * treasury)`, is first brought down to stand exactly at it. Without that, a desk idle for a
     * year would carry a year of ramp above its ceiling, a purchase at the ceiling would use up a
     * sliver of it, and the bid would stay at the ceiling for purchase after purchase in the same
     * block. Brought down, spending can never outrun what the ramp has actually offered.
     */
    function _recordPurchase(uint256 cost) internal {
        uint256 increase = bidIncreasePerSecond;
        uint256 ceiling = maxBid < treasury ? maxBid : treasury;
        uint256 origin = lastPurchaseAt;
        uint256 spent = rampSpent;
        uint256 grown = (block.timestamp - origin) * increase;
        uint256 standing = grown > spent ? grown - spent : 0;
        if (standing > ceiling) {
            uint256 secondsToCeiling = (ceiling + increase - 1) / increase;
            origin = block.timestamp - secondsToCeiling;
            spent = secondsToCeiling * increase - ceiling;
        }
        spent += cost;
        uint256 whole = spent / increase;
        origin += whole;
        spent -= whole * increase;
        if (origin >= block.timestamp) {
            origin = block.timestamp;
            spent = 0;
        }

        treasury -= cost;
        lastPurchaseAt = origin;
        rampSpent = spent;
        emit PurchaseRecorded(cost, treasury);
    }

    /// @dev Books a sale. After graduation the proceeds join the burn queue and never the
    /// treasury. Before it nothing can buy the token to burn, so they go back to the treasury and
    /// buy the floor again (`SaleRecycled`) instead of waiting, forever if the launch never
    /// graduates, for a pool (decision 0021, audit H-1 of PR #74). Recycled through
    /// `_creditTreasury`, so a large sale is released to the bid at the ramp's pace too.
    function _recordSale(uint256 proceeds) internal {
        if (!graduated) {
            _creditTreasury(proceeds);
            emit SaleRecycled(proceeds, treasury);
            return;
        }
        pendingBurn += proceeds;
        emit SaleRecorded(proceeds, pendingBurn);
    }

    /**
     * @dev Moves a retired desk's treasury into the burn queue, never past one increment of queue.
     * Moving it all at retirement would publish a backlog a front-runner can buy ahead of across
     * several blocks (DD-3 of the 3 October deep dive). Topped up this way, the queue a retired
     * desk exposes is never more than one pass plus whatever sales add, and the treasury leaves at
     * the pace `processBurn` already enforces. A queue already holding a full increment, as when
     * the pool's depth bound held the last pass back, receives nothing more.
     */
    function _releaseRetiredTreasury() private {
        if (!retired || treasury == 0 || pendingBurn >= burnIncrement) return;
        uint256 release = burnIncrement - pendingBurn;
        if (release > treasury) release = treasury;
        treasury -= release;
        pendingBurn += release;
        emit TreasuryReleased(release, treasury);
    }
}
