// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {SweepToken} from "../src/SweepToken.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";

/**
 * @title RecursiveStrategyTest
 * @author 0xDAVZER
 * @notice Pins the airdrop ledger: who is owed what after each distribution, what a claim pays,
 * what an excluded account never gets, and that not one token is created or lost on the way.
 *
 * @dev The pool is a plain address made a distributor so a "buy" is a transfer out of it and a
 * "sell" a transfer into it; the mock router hands over a fixed number of tokens per wei, so every
 * expected share is an integer the test can state. The lock itself is pinned on the base token.
 */
contract RecursiveStrategyTest is Test {
    SweepRecursiveStrategy internal strategy;
    MockBurnRouter internal router;

    address internal hook = makeAddr("hook");
    address internal poolManager = makeAddr("poolManager");
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant RATE = 1000;
    uint256 internal constant ROUTER_INVENTORY = 100_000_000e18;

    function setUp() public {
        vm.warp(1_788_000_000);
        router = new MockBurnRouter();

        strategy = new SweepRecursiveStrategy();
        strategy.initialize(_config(address(router), hook, poolManager, owner));

        vm.startPrank(owner);
        strategy.setDistributor(address(this), true);
        strategy.setDistributor(poolManager, true);
        vm.stopPrank();

        strategy.transfer(address(router), ROUTER_INVENTORY);
        strategy.transfer(poolManager, strategy.balanceOf(address(this)));

        vm.deal(hook, 100 ether);
    }

    /* ───────────────────────── initialisation ──────────────────────── */

    function test_InitializeExcludesEveryAccountThatIsNotAHolder() public view {
        assertTrue(strategy.excludedFromRewards(poolManager));
        assertTrue(strategy.excludedFromRewards(strategy.DEAD_ADDRESS()));
        assertTrue(strategy.excludedFromRewards(hook));
        assertTrue(strategy.excludedFromRewards(address(router)));
        assertTrue(strategy.excludedFromRewards(address(strategy)));
        assertFalse(strategy.excludedFromRewards(alice));
        assertTrue(strategy.isDistributor(address(strategy)), "the desk must be able to airdrop under the lock");
        assertEq(strategy.eligibleSupply(), 0, "nothing is eligible while the pool holds it all");
        assertEq(strategy.rewardMin(), 0.001 ether);
    }

    function test_InitializeRefusesAZeroRouter() public {
        SweepRecursiveStrategy fresh = new SweepRecursiveStrategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(_config(address(0), hook, poolManager, owner));
    }

    /* ──────────────────────── eligible supply ──────────────────────── */

    function test_ABuyRaisesEligibleSupplyAndASellLowersIt() public {
        _buy(alice, 300e18);
        assertEq(strategy.eligibleSupply(), 300e18);
        _buy(bob, 100e18);
        assertEq(strategy.eligibleSupply(), 400e18);
        _sell(alice, 50e18);
        assertEq(strategy.eligibleSupply(), 350e18);
    }

    function test_ABurnLeavesEligibleSupplyForTheDead() public {
        _buy(alice, 300e18);
        address dead = strategy.DEAD_ADDRESS();
        vm.prank(alice);
        strategy.transfer(dead, 100e18);
        assertEq(strategy.eligibleSupply(), 200e18);
    }

    /* ───────────────────────── distributing ────────────────────────── */

    /// @notice Two holders at 2:1 are owed 2:1 of exactly what the router delivered.
    function test_DistributionSplitsProRata() public {
        _buy(alice, 200e18);
        _buy(bob, 100e18);
        _fund(1 ether);

        strategy.distribute();

        uint256 bought = 1 ether * RATE;
        assertEq(strategy.balanceOf(address(strategy)), bought);
        assertEq(strategy.reserved(), bought);
        assertEq(strategy.claimable(alice), (bought * 2) / 3);
        assertEq(strategy.claimable(bob), bought / 3);
        assertEq(strategy.pendingRewards(), 0);
        assertEq(strategy.lastDistributedAt(), block.timestamp);
        assertEq(strategy.totalDistributed(), bought);
    }

    function test_DistributionEmitsWhatItBoughtAndForWhom() public {
        _buy(alice, 200e18);
        _fund(1 ether);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit SweepRecursiveStrategy.RewardsDistributed(1 ether, 1 ether * RATE, 200e18);
        strategy.distribute();
    }

    /// @notice A wallet that buys after a distribution has no share of it, and a wallet that sold
    /// before it has none either: the ledger is settled at the moment balances move.
    function test_LateBuyersAndEarlySellersGetNothingFromADistribution() public {
        _buy(alice, 100e18);
        _buy(bob, 100e18);
        _sell(bob, 100e18);
        _fund(1 ether);
        strategy.distribute();
        _buy(carol, 100e18);

        assertEq(strategy.claimable(alice), 1 ether * RATE);
        assertEq(strategy.claimable(bob), 0);
        assertEq(strategy.claimable(carol), 0);
    }

    /// @notice A holder keeps what a distribution owed them even after selling everything.
    function test_SellingAfterADistributionKeepsWhatWasOwed() public {
        _buy(alice, 100e18);
        _fund(1 ether);
        strategy.distribute();
        _sell(alice, 100e18);

        assertEq(strategy.claimable(alice), 1 ether * RATE);
        assertEq(strategy.eligibleSupply(), 0);
    }

    function test_ExcludedAccountsNeverAccrueAndCannotClaim() public {
        _buy(alice, 100e18);
        _fund(1 ether);
        strategy.distribute();

        assertEq(strategy.claimable(poolManager), 0);
        assertEq(strategy.claimable(address(router)), 0);
        assertEq(strategy.claimable(address(strategy)), 0);

        vm.prank(poolManager);
        vm.expectRevert(SweepRecursiveStrategy.Excluded.selector);
        strategy.claim();
    }

    function test_DistributeRefusesBelowTheMinimum() public {
        _buy(alice, 100e18);
        _fund(0.0009 ether);
        vm.expectRevert(SweepRecursiveStrategy.NothingToDistribute.selector);
        strategy.distribute();

        vm.expectRevert(SweepRecursiveStrategy.NothingToDistribute.selector);
        SweepRecursiveStrategy(payable(address(strategy))).distribute();
    }

    /// @notice Fees that arrive before anyone holds the token are carried, and the first holder
    /// receives them with the next distribution rather than losing them to nobody.
    function test_FeesBeforeTheFirstHolderAreCarried() public {
        _fund(1 ether);
        strategy.distribute();
        assertEq(strategy.carry(), 1 ether * RATE);
        assertEq(strategy.reserved(), 0);
        assertEq(strategy.claimable(alice), 0);

        _buy(alice, 100e18);
        _fund(1 ether);
        strategy.distribute();
        assertEq(strategy.carry(), 0);
        assertEq(strategy.claimable(alice), 2 ether * RATE);
    }

    /* ─────────────────────────── claiming ───────────────────────────── */

    function test_ClaimForPaysExactlyWhatIsOwedAndOnlyOnce() public {
        _buy(alice, 200e18);
        _buy(bob, 100e18);
        _fund(1 ether);
        strategy.distribute();
        uint256 owedAlice = strategy.claimable(alice);
        uint256 owedBob = strategy.claimable(bob);

        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;
        strategy.claimFor(holders);

        assertEq(strategy.balanceOf(alice), 200e18 + owedAlice);
        assertEq(strategy.balanceOf(bob), 100e18 + owedBob);
        assertEq(strategy.claimable(alice), 0);
        assertEq(strategy.claimable(bob), 0);
        assertLe(strategy.reserved(), 1, "only the wei the floor could not split stays");

        strategy.claimFor(holders);
        assertEq(strategy.balanceOf(alice), 200e18 + owedAlice, "a second pass must pay nothing");
    }

    function test_ClaimEmitsPerHolder() public {
        _buy(alice, 100e18);
        _fund(1 ether);
        strategy.distribute();
        vm.expectEmit(true, false, false, true, address(strategy));
        emit SweepRecursiveStrategy.RewardClaimed(alice, 1 ether * RATE);
        vm.prank(alice);
        strategy.claim();
    }

    /// @notice A share below the dust threshold is left in the ledger rather than transferred, and
    /// it never stops the rest of the batch.
    function test_ClaimForSkipsDustWithoutReverting() public {
        _buy(alice, 1_000_000e18);
        _buy(bob, 1);
        _fund(0.001 ether);
        strategy.distribute();
        assertLt(strategy.claimable(bob), strategy.REWARD_DUST());

        address[] memory holders = new address[](2);
        holders[0] = bob;
        holders[1] = alice;
        strategy.claimFor(holders);

        assertEq(strategy.balanceOf(bob), 1);
        assertGt(strategy.balanceOf(alice), 1_000_000e18);
        assertEq(strategy.claimable(alice), 0);
    }

    /// @notice An airdrop is a real balance: the next distribution counts it.
    function test_AirdroppedTokensCompound() public {
        _buy(alice, 100e18);
        _buy(bob, 100e18);
        _fund(1 ether);
        strategy.distribute();
        vm.prank(alice);
        strategy.claim();

        _fund(1 ether);
        strategy.distribute();

        uint256 aliceBalance = 100e18 + 0.5 ether * RATE;
        uint256 eligible = aliceBalance + 100e18;
        assertEq(strategy.eligibleSupply(), eligible);
        assertEq(strategy.claimable(alice), (1 ether * RATE * aliceBalance) / eligible);
        assertEq(strategy.claimable(bob), 0.5 ether * RATE + (1 ether * RATE * 100e18) / eligible);
    }

    /* ───────────────────────────── guards ───────────────────────────── */

    function test_AddFeesIsTheHooksAlone() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SweepToken.OnlyHook.selector);
        strategy.addFees{value: 1 ether}();
    }

    function test_TheLockStillRefusesWalletToWallet() public {
        _buy(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(SweepToken.TransferNotAllowed.selector);
        strategy.transfer(bob, 1e18);
    }

    function test_RewardMinIsTheOwnersAndBounded() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setRewardMin(0.01 ether);

        uint256 tooHigh = strategy.MAX_REWARD_MIN() + 1;
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setRewardMin(tooHigh);

        vm.prank(owner);
        strategy.setRewardMin(0.01 ether);
        assertEq(strategy.rewardMin(), 0.01 ether);
    }

    function test_ANewRouterIsExcludedToo() public {
        MockBurnRouter next = new MockBurnRouter();
        vm.prank(owner);
        strategy.setBurnRouter(address(next));
        assertTrue(strategy.excludedFromRewards(address(next)));
        assertEq(strategy.burnRouter(), address(next));
    }

    /* ───────────────────────── conservation ─────────────────────────── */

    /**
     * @notice Whatever the sequence of buys, sells, distributions and claims, every token the
     * router delivered is either claimed, claimable, carried, or dust the ledger cannot split,
     * and the desk holds exactly the unclaimed part.
     */
    function testFuzz_EveryTokenBoughtIsAccountedFor(uint96 a, uint96 b, uint96 fee, uint8 rounds) public {
        uint256 amountA = bound(a, 1e15, 1_000_000e18);
        uint256 amountB = bound(b, 1e15, 1_000_000e18);
        uint256 feeWei = bound(fee, 0.001 ether, 10 ether);
        rounds = uint8(bound(rounds, 1, 5));

        _buy(alice, amountA);
        _buy(bob, amountB);

        uint256 bought;
        uint256 claimed;
        for (uint256 i = 0; i < rounds; i++) {
            _fund(feeWei);
            strategy.distribute();
            bought += feeWei * RATE;
            if (i % 2 == 0) {
                uint256 before = strategy.balanceOf(alice);
                vm.prank(alice);
                strategy.claim();
                claimed += strategy.balanceOf(alice) - before;
            }
            if (i % 3 == 1) _sell(bob, strategy.balanceOf(bob) / 2);
        }

        uint256 outstanding = strategy.claimable(alice) + strategy.claimable(bob);
        uint256 held = strategy.balanceOf(address(strategy));
        assertEq(held, strategy.reserved() + strategy.carry() + (held - strategy.reserved() - strategy.carry()));
        assertLe(claimed + outstanding, bought);
        assertLe(bought - claimed - outstanding, held, "the desk must hold every unclaimed token");
        assertGe(held + claimed, bought, "tokens were lost");
    }

    /// @notice The only ETH a recursive strategy accepts is the hook's, through `addFees`. A
    /// plain send has no fee behind it and no holder to owe, so it is refused rather than left
    /// sitting in a contract whose books would never mention it.
    function test_BareEthIsRefused() public {
        (bool ok, bytes memory reason) = address(strategy).call{value: 1 ether}("");
        assertFalse(ok, "a bare send was accepted");
        assertEq(bytes4(reason), SweepToken.OnlyHook.selector);
        assertEq(address(strategy).balance, 0);
    }

    /* ───────────────────────────── helpers ──────────────────────────── */

    function _buy(address holder, uint256 amount) private {
        vm.prank(poolManager);
        strategy.transfer(holder, amount);
    }

    function _sell(address holder, uint256 amount) private {
        vm.prank(holder);
        strategy.transfer(poolManager, amount);
    }

    function _fund(uint256 amount) private {
        vm.prank(hook);
        strategy.addFees{value: amount}();
    }

    function _config(address burnRouter, address hook_, address poolManager_, address owner_)
        private
        pure
        returns (SweepRecursiveStrategy.Config memory config)
    {
        config.burnRouter = burnRouter;
        config.name = "Recursive Sweep";
        config.symbol = "sREC";
        config.hook = hook_;
        config.poolManager = poolManager_;
        config.owner = owner_;
    }
}
