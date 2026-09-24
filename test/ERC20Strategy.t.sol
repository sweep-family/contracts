// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SweepStrategy} from "../src/SweepStrategy.sol";
import {SweepToken} from "../src/SweepToken.sol";
import {SweepDesk} from "../src/SweepDesk.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {TargetToken, SkimmingToken, LyingToken} from "./mocks/TargetToken.sol";

/**
 * @title ERC20StrategyTest
 * @author 0xDAVZER
 * @notice Pins the bag desk: what it pays for a bag, what it checks arrived, what it asks for the
 * bag afterwards, and where the proceeds go.
 *
 * @dev The desk has no venue and no arbitrary call, so there is no hostile marketplace here. The
 * adversaries are tokens: one that skims on transfer, one that lies about transferring. Each of
 * them is exactly the kind of token somebody will point a strategy at.
 */
contract ERC20StrategyTest is Test {
    SweepERC20Strategy internal strategy;
    TargetToken internal target;
    MockBurnRouter internal router;

    address internal hook = makeAddr("hook");
    address internal poolManager = makeAddr("poolManager");
    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant BID_PER_SECOND = 0.01 ether;
    uint256 internal constant MAX_BID = 10 ether;
    uint256 internal constant MULTIPLIER = 14_000;
    uint256 internal constant BAG = 100_000e18;

    function setUp() public {
        vm.warp(1_788_000_000);

        target = new TargetToken();
        router = new MockBurnRouter();

        strategy = _deploy(address(target), BAG, 0);

        vm.prank(owner);
        strategy.setDistributor(address(this), true);
        strategy.transfer(address(router), 100_000_000e18);

        vm.deal(hook, 100 ether);
        vm.deal(buyer, 100 ether);
        target.mint(seller, 10 * BAG);
        vm.prank(seller);
        target.approve(address(strategy), type(uint256).max);
    }

    /* ───────────────────────── initialisation ──────────────────────── */

    function test_InitializeRefusesAZeroToken() public {
        SweepERC20Strategy fresh = new SweepERC20Strategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(_config(address(0), BAG, address(router), MULTIPLIER, 0));
    }

    function test_InitializeRefusesAnEmptyBag() public {
        SweepERC20Strategy fresh = new SweepERC20Strategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(_config(address(target), 0, address(router), MULTIPLIER, 0));
    }

    function test_InitializeRefusesAZeroRouter() public {
        SweepERC20Strategy fresh = new SweepERC20Strategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(_config(address(target), BAG, address(0), MULTIPLIER, 0));
    }

    /// @notice A multiplier under 100% would list a bag below what it cost, a loss on every cycle.
    function test_InitializeRefusesAMultiplierBelowCost() public {
        SweepERC20Strategy fresh = new SweepERC20Strategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(_config(address(target), BAG, address(router), 9999, 0));
    }

    function test_InitializeRecordsTheTarget() public view {
        assertEq(address(strategy.token()), address(target));
        assertEq(strategy.bagSize(), BAG);
        assertEq(strategy.burnRouter(), address(router));
        assertEq(strategy.resaleMultiplierBps(), MULTIPLIER);
        assertEq(strategy.lastBagId(), 0);
        assertEq(strategy.bagsHeld(), 0);
    }

    /* ───────────────────────────── buying ───────────────────────────── */

    /// @notice A seller is paid exactly the published bid, and the desk holds exactly one bag more.
    function test_PurchasePaysTheBidAndTakesExactlyOneBag() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);
        uint256 bid = strategy.currentBid();
        assertEq(bid, 1 ether);

        uint256 sellerEthBefore = seller.balance;
        uint256 sellerTokensBefore = target.balanceOf(seller);

        vm.prank(seller);
        uint256 bagId = strategy.buyTokens();

        assertEq(bagId, 1);
        assertEq(seller.balance - sellerEthBefore, bid);
        assertEq(sellerTokensBefore - target.balanceOf(seller), BAG);
        assertEq(target.balanceOf(address(strategy)), BAG);
        assertEq(strategy.bagsHeld(), 1);
        assertEq(strategy.lastBagId(), 1);
    }

    /// @notice A purchase records what was paid and when, which is what the ask is derived from.
    function test_PurchaseRecordsTheHolding() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);

        vm.prank(seller);
        uint256 bagId = strategy.buyTokens();

        (uint256 cost, uint256 acquiredAt) = strategy.bags(bagId);
        assertEq(cost, 1 ether);
        assertEq(acquiredAt, block.timestamp);
        assertEq(strategy.askPrice(bagId), 1.4 ether);
    }

    /// @notice The treasury pays, and the bid restarts from nothing for the next seller.
    function test_PurchaseSpendsTheTreasuryAndResetsTheBid() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);

        vm.prank(seller);
        strategy.buyTokens();

        assertEq(strategy.treasury(), 4 ether);
        assertEq(strategy.currentBid(), 0);
        assertEq(strategy.lastPurchaseAt(), block.timestamp);
    }

    /// @notice Bag ids are sequential and never reused: the second bag is #2, whatever happened to #1.
    function test_BagIdsAreSequential() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);
        vm.prank(seller);
        uint256 first = strategy.buyTokens();

        vm.prank(buyer);
        strategy.sellTokens{value: strategy.askPrice(first)}(first);

        vm.warp(block.timestamp + 100);
        vm.prank(seller);
        uint256 second = strategy.buyTokens();

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(strategy.bagsHeld(), 1);
    }

    /**
     * @notice With nothing to spend, the desk refuses rather than buying for free.
     * @dev A bag bought for zero would be listed at zero, and a zero ask is how "not held" is
     * spelled — the bag would be stuck forever.
     */
    function test_PurchaseRefusesWhenTheBidIsZero() public {
        vm.prank(seller);
        vm.expectRevert(SweepERC20Strategy.NothingToSpend.selector);
        strategy.buyTokens();

        _fund(5 ether);
        vm.warp(block.timestamp + 100);
        vm.prank(seller);
        strategy.buyTokens();

        vm.prank(seller);
        vm.expectRevert(SweepERC20Strategy.NothingToSpend.selector);
        strategy.buyTokens();
    }

    /// @notice The bid is bounded by the treasury, so a purchase can never spend more than it holds.
    function test_PurchaseNeverExceedsTheTreasury() public {
        _fund(0.3 ether);
        vm.warp(block.timestamp + 1_000_000);
        assertEq(strategy.currentBid(), 0.3 ether);

        vm.prank(seller);
        strategy.buyTokens();

        assertEq(strategy.treasury(), 0);
        assertEq(address(strategy).balance, 0);
    }

    /// @notice A seller who has not approved the bag is refused before any ETH moves.
    function test_PurchaseNeedsAnApprovedBag() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);
        address stranger = makeAddr("stranger");
        target.mint(stranger, BAG);

        vm.prank(stranger);
        vm.expectRevert();
        strategy.buyTokens();

        assertEq(strategy.treasury(), 5 ether);
        assertEq(strategy.bagsHeld(), 0);
    }

    /**
     * @notice A token that delivers less than a bag is refused, and the seller keeps their tokens.
     * @dev A fee-on-transfer token would leave the desk reselling a bag it does not fully hold; the
     * check is on what arrived, never on what was sent.
     */
    function test_PurchaseRefusesAShortBag() public {
        SkimmingToken skim = new SkimmingToken();
        SweepERC20Strategy desk = _deploy(address(skim), BAG, 0);
        vm.prank(hook);
        desk.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 100);

        skim.mint(seller, BAG);
        vm.startPrank(seller);
        skim.approve(address(desk), type(uint256).max);
        vm.expectRevert(SweepERC20Strategy.BagNotDelivered.selector);
        desk.buyTokens();
        vm.stopPrank();

        assertEq(skim.balanceOf(seller), BAG);
        assertEq(desk.treasury(), 5 ether);
        assertEq(desk.bagsHeld(), 0);
    }

    /// @notice A seller that cannot receive ETH is refused, and keeps the bag.
    function test_PurchaseRefusesASellerThatRejectsEth() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);
        RejectingSeller rejecting = new RejectingSeller(target, strategy);
        target.mint(address(rejecting), BAG);

        vm.expectRevert();
        rejecting.sell();

        assertEq(target.balanceOf(address(rejecting)), BAG);
        assertEq(strategy.bagsHeld(), 0);
    }

    function test_PurchaseEmitsTheBagAndItsOpeningAsk() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 100);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit SweepERC20Strategy.BagBought(1, 1 ether, seller, 1.4 ether);
        vm.prank(seller);
        strategy.buyTokens();
    }

    /* ───────────────────────────── selling ──────────────────────────── */

    /// @notice A sale hands over the bag, takes exactly the ask, and queues every wei for the burn.
    function test_SaleMovesTheBagAndQueuesTheProceeds() public {
        uint256 bagId = _fundAndBuy(5 ether);
        uint256 ask = strategy.askPrice(bagId);
        assertEq(ask, 1.4 ether);

        vm.prank(buyer);
        strategy.sellTokens{value: ask}(bagId);

        assertEq(target.balanceOf(buyer), BAG);
        assertEq(target.balanceOf(address(strategy)), 0);
        assertEq(strategy.pendingBurn(), ask);
        assertEq(strategy.treasury(), 4 ether);
        assertEq(strategy.bagsHeld(), 0);
        assertEq(strategy.askPrice(bagId), 0);
    }

    /// @notice The price is exact in both directions: the desk quotes, the buyer does not.
    function test_SaleDemandsTheExactAsk() public {
        uint256 bagId = _fundAndBuy(5 ether);
        uint256 ask = strategy.askPrice(bagId);

        vm.startPrank(buyer);
        vm.expectRevert(SweepDesk.WrongPayment.selector);
        strategy.sellTokens{value: ask - 1}(bagId);
        vm.expectRevert(SweepDesk.WrongPayment.selector);
        strategy.sellTokens{value: ask + 1}(bagId);
        vm.stopPrank();
    }

    function test_SaleOfAnUnknownBagIsRefused() public {
        vm.prank(buyer);
        vm.expectRevert(SweepDesk.NotForSale.selector);
        strategy.sellTokens{value: 1 ether}(7);
    }

    function test_SoldBagCannotBeSoldTwice() public {
        uint256 bagId = _fundAndBuy(5 ether);
        uint256 ask = strategy.askPrice(bagId);
        vm.startPrank(buyer);
        strategy.sellTokens{value: ask}(bagId);
        vm.expectRevert(SweepDesk.NotForSale.selector);
        strategy.sellTokens{value: ask}(bagId);
        vm.stopPrank();
    }

    /**
     * @notice A token that returns false from `transfer` cannot take the buyer's ETH.
     * @dev A desk that deletes the listing and calls `transfer` unchecked would, against this token,
     * keep the ETH, keep the bag, and destroy the listing in one transaction.
     */
    function test_SaleRevertsWhenTheTokenLiesAboutTransferring() public {
        LyingToken liar = new LyingToken();
        SweepERC20Strategy desk = _deploy(address(liar), BAG, 0);
        vm.prank(hook);
        desk.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 100);
        liar.mint(seller, BAG);
        vm.startPrank(seller);
        liar.approve(address(desk), type(uint256).max);
        uint256 bagId = desk.buyTokens();
        vm.stopPrank();

        uint256 ask = desk.askPrice(bagId);
        vm.prank(buyer);
        vm.expectRevert();
        desk.sellTokens{value: ask}(bagId);

        assertEq(desk.askPrice(bagId), ask);
        assertEq(desk.bagsHeld(), 1);
        assertEq(desk.pendingBurn(), 0);
    }

    function test_SaleEmitsThePriceAndTheCost() public {
        uint256 bagId = _fundAndBuy(5 ether);
        vm.expectEmit(true, true, false, true, address(strategy));
        emit SweepERC20Strategy.BagSold(bagId, 1.4 ether, buyer, 1 ether);
        vm.prank(buyer);
        strategy.sellTokens{value: 1.4 ether}(bagId);
    }

    /* ─────────────────────────── the listing ────────────────────────── */

    /// @notice The list reports the live ask of every bag in a range, and zero for one that is gone.
    function test_ListReportsLiveAsksAndZeroForSoldBags() public {
        uint256 first = _fundAndBuy(5 ether);
        vm.warp(block.timestamp + 200);
        vm.prank(seller);
        uint256 second = strategy.buyTokens();

        vm.prank(buyer);
        strategy.sellTokens{value: strategy.askPrice(first)}(first);

        uint256[] memory asks = strategy.list(1, 2);
        assertEq(asks.length, 2);
        assertEq(asks[0], 0);
        assertEq(asks[1], strategy.askPrice(second));

        uint256[] memory all = strategy.list();
        assertEq(all.length, 2);
        assertEq(all[1], asks[1]);
    }

    function test_ListRefusesAnInvertedRange() public {
        vm.expectRevert(SweepERC20Strategy.InvalidRange.selector);
        strategy.list(3, 2);
    }

    /* ─────────────────────────── the ask ────────────────────────────── */

    /// @notice With a window, the ask falls from the markup toward the cost and stops there.
    function test_AskDecaysTowardCostAndNeverBelow() public {
        SweepERC20Strategy desk = _deploy(address(target), BAG, 30 days);
        vm.prank(hook);
        desk.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 100);
        vm.startPrank(seller);
        target.approve(address(desk), type(uint256).max);
        desk.buyTokens();
        vm.stopPrank();

        assertEq(desk.askPrice(1), 1.4 ether);
        vm.warp(block.timestamp + 15 days);
        assertEq(desk.askPrice(1), 1.2 ether);
        vm.warp(block.timestamp + 30 days);
        assertEq(desk.askPrice(1), 1 ether);
    }

    /// @notice A change of terms moves every held bag at once, since the ask is computed on read.
    function test_ResaleTermsApplyToHeldBags() public {
        uint256 bagId = _fundAndBuy(5 ether);
        vm.prank(owner);
        strategy.setResaleTerms(20_000, 0);
        assertEq(strategy.askPrice(bagId), 2 ether);
    }

    function test_ResaleTermsAreTheOwners() public {
        vm.expectRevert();
        strategy.setResaleTerms(20_000, 0);
    }

    /* ─────────────────────────── the burn ───────────────────────────── */

    /// @notice Proceeds go through the router to the dead address, one increment per pass; the
    /// caller earns half a percent of the pass.
    function test_BurnSpendsTheProceedsThroughTheRouter() public {
        uint256 bagId = _fundAndBuy(5 ether);
        vm.prank(buyer);
        strategy.sellTokens{value: 1.4 ether}(bagId);

        uint256 pass = strategy.burnIncrement();
        assertEq(pass, 1 ether);
        uint256 deadBefore = strategy.balanceOf(strategy.DEAD_ADDRESS());
        (uint256 spent, uint256 reward) = strategy.processBurn();

        assertEq(spent + reward, pass);
        assertEq(reward, (pass * strategy.BURN_CALLER_REWARD_BPS()) / strategy.BPS());
        assertEq(router.ethReceived(), spent);
        assertGt(strategy.balanceOf(strategy.DEAD_ADDRESS()), deadBefore);
        assertEq(strategy.pendingBurn(), 0.4 ether);
        assertEq(target.balanceOf(address(strategy)), 0);
    }

    /* ───────────────────────── conservation ─────────────────────────── */

    /**
     * @notice After any sequence of purchases and sales, every wei the desk holds is either
     * treasury or pending burn, and no purchase ever paid more than the treasury held.
     */
    function testFuzz_EthIsAlwaysTreasuryPlusPendingBurn(uint96 fees, uint32 wait, uint8 rounds) public {
        fees = uint96(bound(fees, 0.01 ether, 50 ether));
        wait = uint32(bound(wait, 1, 30 days));
        rounds = uint8(bound(rounds, 1, 6));

        _fund(fees);
        for (uint256 i = 0; i < rounds; i++) {
            vm.warp(block.timestamp + wait);
            uint256 treasuryBefore = strategy.treasury();
            uint256 bid = strategy.currentBid();
            if (bid == 0) break;

            vm.prank(seller);
            uint256 bagId = strategy.buyTokens();
            (uint256 cost,) = strategy.bags(bagId);
            assertLe(cost, treasuryBefore);
            assertEq(strategy.treasury(), treasuryBefore - cost);

            if (i % 2 == 0) {
                vm.prank(buyer);
                strategy.sellTokens{value: strategy.askPrice(bagId)}(bagId);
            }
            assertEq(address(strategy).balance, strategy.treasury() + strategy.pendingBurn());
        }
        assertEq(target.balanceOf(address(strategy)), strategy.bagsHeld() * BAG);
    }

    /* ───────────────────────────── helpers ──────────────────────────── */

    function _fund(uint256 amount) private {
        vm.prank(hook);
        strategy.addFees{value: amount}();
    }

    function _fundAndBuy(uint256 amount) private returns (uint256 bagId) {
        _fund(amount);
        vm.warp(block.timestamp + 100);
        vm.prank(seller);
        bagId = strategy.buyTokens();
    }

    function _deploy(address token, uint256 bag, uint256 decayWindow) private returns (SweepERC20Strategy desk) {
        desk = new SweepERC20Strategy();
        desk.initialize(_config(token, bag, address(router), MULTIPLIER, decayWindow));
    }

    function _config(address token, uint256 bag, address burnRouter, uint256 multiplierBps, uint256 decayWindow)
        private
        view
        returns (SweepERC20Strategy.Config memory config)
    {
        config.token = token;
        config.bagSize = bag;
        config.burnRouter = burnRouter;
        config.name = "Target Sweep";
        config.symbol = "sTGT";
        config.hook = hook;
        config.poolManager = poolManager;
        config.bidIncreasePerSecond = BID_PER_SECOND;
        config.maxBid = MAX_BID;
        config.resaleMultiplierBps = multiplierBps;
        config.askDecayWindow = decayWindow;
        config.owner = owner;
    }
}

/// @dev A seller with no `receive`, so the desk's payment to it fails.
contract RejectingSeller {
    TargetToken private immutable token;
    SweepERC20Strategy private immutable desk;

    constructor(TargetToken token_, SweepERC20Strategy desk_) {
        token = token_;
        desk = desk_;
    }

    function sell() external {
        token.approve(address(desk), type(uint256).max);
        desk.buyTokens();
    }
}
