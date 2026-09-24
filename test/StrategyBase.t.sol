// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SweepStrategy} from "../src/SweepStrategy.sol";
import {SweepToken} from "../src/SweepToken.sol";
import {StrategyHarness} from "./mocks/StrategyHarness.sol";
import {SwapSimulator} from "./mocks/SwapSimulator.sol";

/**
 * @title StrategyBaseTest
 * @author 0xDAVZER
 * @notice Pins the token, the transfer lock, the bid and the burn accounting.
 *
 * @dev Weighted toward the time-paced bid, the treasury bound on that bid and the retunable burn
 * pacing, because those are the claims most easily got wrong. Everything else here is a guard rail
 * against regressions.
 */
contract StrategyBaseTest is Test {
    StrategyHarness internal strategy;

    address internal hook = makeAddr("hook");
    address internal poolManager = makeAddr("poolManager");
    address internal router = makeAddr("router");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal burner = makeAddr("burner");

    uint256 internal constant BID_PER_SECOND = 0.001 ether;
    uint256 internal constant MAX_BID = 3 ether;

    /// @dev Foundry starts at timestamp 1, which is unlike any chain and quietly hides bugs in
    /// anything that compares a timestamp against a duration. Start somewhere real.
    function setUp() public {
        vm.warp(1_788_000_000);
        strategy = new StrategyHarness();
        strategy.initialize("Phantom Strategy", "PHSTR", hook, poolManager, BID_PER_SECOND, MAX_BID, owner);
    }

    /* ─────────────────────────── the token ─────────────────────────── */

    /// @notice The whole supply exists at once and lands with the deployer, which is the factory in
    /// production and is what gets pushed into the pool as single-sided liquidity.
    function test_EntireSupplyIsMintedToTheDeployer() public view {
        assertEq(strategy.totalSupply(), strategy.MAX_SUPPLY());
        assertEq(strategy.balanceOf(address(this)), strategy.MAX_SUPPLY());
    }

    /**
     * @notice Circulating supply subtracts what has been burnt.
     * @dev Burnt tokens are sent to a dead address rather than destroyed, so `totalSupply` keeps
     * counting them forever. Any market cap computed from `totalSupply` is wrong by exactly the
     * amount the protocol has burnt, which grows over the life of the strategy.
     */
    function test_CirculatingSupplyExcludesTheDeadBalance() public {
        uint256 burnt = 10_000e18;
        strategy.exposed_moveToDead(burnt);

        assertEq(strategy.totalSupply(), strategy.MAX_SUPPLY(), "totalSupply still counts them");
        assertEq(strategy.circulatingSupply(), strategy.MAX_SUPPLY() - burnt, "circulating does not");
    }

    /* ───────────────────────── the transfer lock ───────────────────── */

    /**
     * @notice A plain wallet-to-wallet send reverts.
     * @dev This is what makes the fee uncontournable: a competing pool with no hook would need
     * tokens moved into it, and they cannot move. The cost is every form of composability, which is
     * a deliberate trade and has to be said plainly wherever a user can see it.
     */
    function test_WalletToWalletTransferReverts() public {
        strategy.transfer(address(strategy), 0);
        strategy.exposed_credit(alice, 1000e18);

        vm.prank(alice);
        vm.expectRevert(SweepToken.TransferNotAllowed.selector);
        strategy.transfer(bob, 1e18);
    }

    /// @notice A whitelisted distributor moves freely, which is how the router works at all.
    function test_DistributorCanTransferFreely() public {
        strategy.exposed_credit(alice, 1000e18);

        vm.prank(owner);
        strategy.setDistributor(alice, true);

        vm.prank(alice);
        strategy.transfer(bob, 1e18);
        assertEq(strategy.balanceOf(bob), 1e18);
    }

    /// @notice Receiving from a distributor is allowed too, or nobody could ever buy.
    function test_TransferToADistributorIsAllowed() public {
        strategy.exposed_credit(alice, 1000e18);

        vm.prank(owner);
        strategy.setDistributor(bob, true);

        vm.prank(alice);
        strategy.transfer(bob, 1e18);
        assertEq(strategy.balanceOf(bob), 1e18);
    }

    /// @notice Only the owner may punch a hole in the transfer lock.
    /// @dev The power exists because the router needs it; anyone else holding it could open the lock
    /// for arbitrary addresses and route around the fee.
    function test_OnlyOwnerCanWhitelistADistributor() public {
        vm.prank(alice);
        vm.expectRevert();
        strategy.setDistributor(alice, true);
    }

    /* ──────────────────────────── the bid ──────────────────────────── */

    /**
     * @notice The bid is paced by seconds, not by blocks.
     * @dev The headline correction. Robinhood Chain produces a block every ~101 ms, so a
     * block-paced ramp climbs 119x faster here than on Ethereum — and an Orbit operator can change
     * block production, moving the economics on the same chain with no warning. Rolling a hundred
     * blocks without advancing the clock must change nothing at all.
     */
    function test_BidIsPacedBySecondsNotBlocks() public {
        strategy.exposed_fund(10 ether);
        uint256 atStart = strategy.currentBid();

        vm.roll(block.number + 100);
        assertEq(strategy.currentBid(), atStart, "blocks alone must not move the bid");

        vm.warp(block.timestamp + 100);
        assertEq(strategy.currentBid(), atStart + 100 * BID_PER_SECOND, "seconds must");
    }

    /**
     * @notice The bid never exceeds its cap, however long nobody buys.
     * @dev Unbounded, the ramp always eventually passes the price above which a purchase cannot be
     * resold, and the protocol condemns itself to holding the asset. We cannot compute that bound
     * on-chain because it needs a floor price, so it is an explicit parameter — this converts an
     * unbounded drift into a number somebody chose.
     */
    function test_BidNeverExceedsMaxBid() public {
        strategy.exposed_fund(1000 ether);

        vm.warp(block.timestamp + 365 days);
        assertEq(strategy.currentBid(), MAX_BID, "a year of waiting still stops at the cap");
    }

    /**
     * @notice The bid never exceeds what the treasury actually holds.
     * @dev A ramp that ignores the treasury publishes a bid the desk cannot pay, and a stored bound
     * that is only re-pinned on large fee deposits never fires in low volume. Computing the bound on
     * read rather than storing it makes that class of bug impossible.
     */
    function test_BidNeverExceedsTheTreasury() public {
        strategy.exposed_fund(0.5 ether);

        vm.warp(block.timestamp + 365 days);
        assertEq(strategy.currentBid(), 0.5 ether, "the treasury is the binding bound here");
    }

    /// @notice With nothing in the treasury there is no bid, so a purchase cannot be attempted.
    function test_BidIsZeroWithAnEmptyTreasury() public {
        vm.warp(block.timestamp + 1 days);
        assertEq(strategy.currentBid(), 0);
    }

    /// @notice A purchase resets the ramp, so the next seller starts from the bottom again.
    function test_BidResetsAfterAPurchase() public {
        strategy.exposed_fund(10 ether);
        vm.warp(block.timestamp + 1000);
        assertGt(strategy.currentBid(), 0.9 ether);

        strategy.exposed_recordPurchase(0.5 ether);
        assertEq(strategy.currentBid(), 0, "the ramp restarts at zero");
        assertEq(strategy.treasury(), 9.5 ether, "and the treasury pays for it");
    }

    /* ─────────────────────────── the treasury ──────────────────────── */

    /// @notice Only the hook may fund the treasury, since it is the only thing that sees a swap.
    function test_OnlyHookCanAddFees() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SweepToken.OnlyHook.selector);
        strategy.addFees{value: 1 ether}();
    }

    /// @notice Fees accumulate rather than replacing one another.
    function test_FeesAccumulate() public {
        vm.deal(hook, 3 ether);
        vm.startPrank(hook);
        strategy.addFees{value: 1 ether}();
        strategy.addFees{value: 2 ether}();
        vm.stopPrank();

        assertEq(strategy.treasury(), 3 ether);
    }

    /* ──────────────────────────── the burn ─────────────────────────── */

    /// @notice A burn pass spends at most one increment, so a large backlog is drained gradually
    /// instead of hitting the pool with a single order that would be trivially sandwiched.
    /// @dev Asserts against all three destinations, not two. A pass splits into what is burnt and
    /// what pays the caller, and an earlier version of this test omitted the reward and read the
    /// difference as loss.
    function test_BurnSpendsAtMostItsIncrement() public {
        strategy.exposed_recordSale(10 ether);

        vm.prank(burner);
        (uint256 spent, uint256 reward) = strategy.processBurn();

        assertEq(spent + reward + strategy.pendingBurn(), 10 ether, "every wei has a destination");
        assertLe(spent + reward, strategy.burnIncrement(), "and no pass exceeds its increment");
    }

    /**
     * @notice The caller is paid exactly their share, and the rest is burnt.
     * @dev The burn needs a bounty because it benefits every holder diffusely and nobody
     * individually — unlike the purchase, which pays nothing because the seller wanting their money
     * is motive enough.
     */
    function test_BurnPaysTheCallerExactly() public {
        strategy.exposed_recordSale(1 ether);
        uint256 before = burner.balance;

        vm.prank(burner);
        (uint256 spent, uint256 reward) = strategy.processBurn();

        uint256 expected = (1 ether * strategy.BURN_CALLER_REWARD_BPS()) / strategy.BPS();
        assertEq(reward, expected, "the reward is the published share");
        assertEq(burner.balance, before + expected, "and it actually arrives");
        assertEq(spent, 1 ether - expected, "the remainder is what gets burnt");
    }

    /// @notice A second pass inside the cooldown is refused, which is what makes it a schedule
    /// rather than a single market order split across one block.
    function test_BurnRefusesInsideTheCooldown() public {
        strategy.exposed_recordSale(10 ether);

        vm.prank(burner);
        strategy.processBurn();

        vm.prank(burner);
        vm.expectRevert(SweepStrategy.BurnCooldownNotElapsed.selector);
        strategy.processBurn();
    }

    /// @notice A pass with nothing pending is refused rather than paying a reward for no work.
    function test_BurnRefusesWithNothingPending() public {
        vm.prank(burner);
        vm.expectRevert(SweepStrategy.NothingToBurn.selector);
        strategy.processBurn();
    }

    /// @notice Proceeds reach the burn queue, never the treasury.
    /// @dev The two pots never mix: the treasury buys assets, the queue destroys supply. Crossing
    /// them would let sale proceeds fund purchases and quietly turn the machine into a fund.
    function test_SaleProceedsGoToTheBurnQueueNotTheTreasury() public {
        strategy.exposed_recordSale(2 ether);

        assertEq(strategy.pendingBurn(), 2 ether);
        assertEq(strategy.treasury(), 0);
    }

    /* ────────────────── the transient pool allowance ───────────────── */

    /**
     * @notice The PoolManager cannot move tokens without the hook having authorised it first.
     * @dev This is the second half of the transfer lock. The first half refuses ordinary wallets;
     * this half means even the pool only moves what the hook accounted for on that specific swap.
     */
    function test_PoolTransferWithoutAllowanceReverts() public {
        strategy.exposed_credit(poolManager, 1000e18);

        vm.prank(poolManager);
        vm.expectRevert(SweepToken.TransferNotAllowed.selector);
        strategy.transfer(alice, 1e18);
    }

    /**
     * @notice With an allowance from the hook, the pool moves exactly that much.
     * @dev Granting and moving happen inside one call because the allowance is transient and cannot
     * outlive the transaction that created it. That is the security property — no standing hole in
     * the lock — and it is also why a test splitting the two across separate calls always fails.
     */
    function test_HookCanAuthoriseAPoolTransfer() public {
        (StrategyHarness s, SwapSimulator pool) = _strategyWithSimulatedPool();
        s.exposed_credit(address(pool), 1000e18);

        pool.authoriseAndMove(s, alice, 5e18, 5e18);
        assertEq(s.balanceOf(alice), 5e18);
    }

    /**
     * @notice The allowance is spent by the transfer it authorised.
     * @dev Without the decrement a single authorisation would cover unlimited movement for the rest
     * of the transaction, which is the whole hole the lock exists to close.
     */
    function test_AllowanceIsConsumedByTheTransfer() public {
        (StrategyHarness s, SwapSimulator pool) = _strategyWithSimulatedPool();
        s.exposed_credit(address(pool), 1000e18);

        vm.expectRevert(SweepToken.TransferNotAllowed.selector);
        pool.authoriseAndMoveTwice(s, alice, 5e18, 3e18, 3e18);
    }

    /// @notice A grant is readable inside the transaction that made it, and nowhere else.
    function test_AllowanceIsVisibleOnlyWithinItsOwnTransaction() public {
        (StrategyHarness s, SwapSimulator pool) = _strategyWithSimulatedPool();

        assertEq(pool.allowanceAfterGranting(s, 7e18), 7e18, "visible while the swap runs");
        assertEq(s.transferAllowance(), 0, "and gone once it ends");
    }

    /// @dev A strategy whose hook and PoolManager are one contract, so a swap can be reproduced in
    /// a single transaction. That the two roles are genuinely distinct is pinned separately by the
    /// `onlyHook` tests.
    function _strategyWithSimulatedPool() private returns (StrategyHarness s, SwapSimulator pool) {
        pool = new SwapSimulator();
        s = new StrategyHarness();
        s.initialize("Simulated", "SIM", address(pool), address(pool), BID_PER_SECOND, MAX_BID, owner);
    }

    /**
     * @notice No allowance is standing before the hook grants one.
     * @dev The allowance lives in transient storage, so it cannot survive the transaction that
     * created it. Foundry runs a test body as one transaction, so this asserts the weaker property
     * that nothing leaks out of `setUp` — the stronger one is a property of `tstore` itself rather
     * than of this contract.
     */
    function test_NoAllowanceStandsByDefault() public view {
        assertEq(strategy.transferAllowance(), 0);
    }

    /// @notice Only the hook may authorise pool movement.
    function test_OnlyHookCanIncreaseTheAllowance() public {
        vm.prank(alice);
        vm.expectRevert(SweepToken.OnlyHook.selector);
        strategy.increaseTransferAllowance(1e18);
    }

    /// @notice Destroying your own balance is always permitted.
    /// @dev Sending to a dead address cannot be a way around a fee, and refusing it would only make
    /// a voluntary burn impossible.
    function test_SendingToTheDeadAddressIsAlwaysAllowed() public {
        strategy.exposed_credit(alice, 1000e18);

        vm.prank(alice);
        strategy.transfer(strategy.DEAD_ADDRESS(), 1e18);
        assertEq(strategy.circulatingSupply(), strategy.MAX_SUPPLY() - 1e18);
    }

    /* ──────────────────────── configuration ────────────────────────── */

    /// @notice A strategy with no hook could never be funded, so it is refused rather than deployed.
    function test_InitRefusesAZeroHook() public {
        StrategyHarness fresh = new StrategyHarness();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize("n", "s", address(0), poolManager, BID_PER_SECOND, MAX_BID, owner);
    }

    /// @notice A zero cap would pin the bid at nothing, so the strategy could never buy.
    function test_InitRefusesAZeroMaxBid() public {
        StrategyHarness fresh = new StrategyHarness();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize("n", "s", hook, poolManager, BID_PER_SECOND, 0, owner);
    }

    /// @notice A zero ramp would leave the bid at zero forever, for the same reason.
    function test_InitRefusesAZeroRamp() public {
        StrategyHarness fresh = new StrategyHarness();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize("n", "s", hook, poolManager, 0, MAX_BID, owner);
    }

    /// @notice Name and symbol survive initialization, which is not free on a proxy where they
    /// cannot be immutables.
    function test_NameAndSymbolAreStored() public view {
        assertEq(strategy.name(), "Phantom Strategy");
        assertEq(strategy.symbol(), "PHSTR");
    }

    /* ─────────────────────── retuning the burn ─────────────────────── */

    /**
     * @notice The owner can retune the burn pace after launch.
     * @dev Without a setter, a strategy launched with the wrong rhythm would be stuck with it for
     * life short of upgrading the proxy — a very large hammer for a very small nail. The unit is not
     * adjustable and never will be: seconds are baked in, and only the duration moves.
     */
    function test_OwnerCanRetuneTheBurnPacing() public {
        vm.prank(owner);
        strategy.setBurnPacing(5 ether, 300);

        assertEq(strategy.burnIncrement(), 5 ether);
        assertEq(strategy.burnCooldown(), 300);
    }

    /// @notice A zero increment would make every pass a no-op that still consumed the cooldown,
    /// freezing the queue while appearing to work.
    function test_BurnPacingRefusesAZeroIncrement() public {
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setBurnPacing(0, 60);
    }

    /// @notice A zero cooldown would allow a whole queue to be drained inside one block, which is
    /// the single market order the pacing exists to prevent.
    function test_BurnPacingRefusesAZeroCooldown() public {
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setBurnPacing(1 ether, 0);
    }

    /// @notice An enormous cooldown would freeze burns for practical purposes, so the same setter
    /// that allows retuning cannot be used to switch the mechanism off.
    function test_BurnPacingRefusesAnExcessiveCooldown() public {
        uint256 tooLong = strategy.MAX_BURN_COOLDOWN() + 1;
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setBurnPacing(1 ether, tooLong);
    }

    /// @notice Only the owner may retune it.
    function test_OnlyOwnerCanRetuneTheBurnPacing() public {
        vm.prank(alice);
        vm.expectRevert();
        strategy.setBurnPacing(1 ether, 60);
    }

    /// @notice A retuned cooldown takes effect on the next pass, not retroactively on the last one.
    function test_RetunedCooldownAppliesToTheNextPass() public {
        strategy.exposed_recordSale(10 ether);

        vm.prank(burner);
        strategy.processBurn();

        vm.prank(owner);
        strategy.setBurnPacing(1 ether, 1);

        vm.warp(block.timestamp + 2);
        vm.prank(burner);
        strategy.processBurn();
    }

    /* ────────────────────── retuning the bid ───────────────────────── */

    /**
     * @notice The owner can retune the bid after launch.
     * @dev This matters more than the burn pacing and was missing for longer. A `maxBid` set too
     * low at launch leaves a strategy unable to ever buy anything, with the treasury filling behind
     * a ceiling it can never cross — and no way out short of upgrading the proxy.
     */
    function test_OwnerCanRetuneTheBid() public {
        vm.prank(owner);
        strategy.setBidParameters(0.05 ether, 20 ether);

        assertEq(strategy.bidIncreasePerSecond(), 0.05 ether);
        assertEq(strategy.maxBid(), 20 ether);
    }

    /// @notice A retuned ramp changes the bid immediately, since nothing is stored.
    function test_RetunedRampChangesTheBidAtOnce() public {
        strategy.exposed_fund(100 ether);
        vm.warp(block.timestamp + 100);
        assertEq(strategy.currentBid(), 100 * BID_PER_SECOND);

        vm.prank(owner);
        strategy.setBidParameters(BID_PER_SECOND * 2, MAX_BID);
        assertEq(strategy.currentBid(), 100 * BID_PER_SECOND * 2, "recomputed on read, not stored");
    }

    /// @notice A zero ramp would pin the bid at nothing forever.
    function test_BidParametersRefuseAZeroRamp() public {
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setBidParameters(0, MAX_BID);
    }

    /// @notice A zero cap would do the same, from the other side.
    function test_BidParametersRefuseAZeroCap() public {
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setBidParameters(BID_PER_SECOND, 0);
    }

    /// @notice Only the owner may retune it.
    function test_OnlyOwnerCanRetuneTheBid() public {
        vm.prank(alice);
        vm.expectRevert();
        strategy.setBidParameters(BID_PER_SECOND, MAX_BID);
    }
}
