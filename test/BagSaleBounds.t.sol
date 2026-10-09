// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {MockStrategyHook} from "./mocks/MockStrategyHook.sol";
import {MockSweepFactory} from "./mocks/MockSweepFactory.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {TargetToken} from "./mocks/TargetToken.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";

/**
 * @title BagSaleBoundsTest
 * @notice SC-05: a seller states the least they accept and how long their offer stands, so a
 * purchase that lands after the ramp reset cannot take a whole bag for a fraction of the bid.
 */
contract BagSaleBoundsTest is Test {
    MockSweepFactory internal mockFactory = new MockSweepFactory(address(this));
    address internal hook = address(new MockStrategyHook(address(mockFactory), makeAddr("protocol")));
    MockBurnRouter internal router = new MockBurnRouter();
    TargetToken internal target;
    SweepERC20Strategy internal desk;
    address internal seller = makeAddr("seller");
    address internal rival = makeAddr("rival");

    uint256 internal constant BAG = 1000e18;
    uint256 internal constant BID_PER_SECOND = 0.001 ether;

    function setUp() public {
        vm.warp(1_788_000_000);
        target = new TargetToken();
        desk = SweepERC20Strategy(payable(LibClone.clone(address(new SweepERC20Strategy()))));
        SweepERC20Strategy.Config memory config;
        config.token = address(target);
        config.bagSize = BAG;
        config.burnRouter = address(router);
        config.name = "Bag";
        config.symbol = "BAG";
        config.hook = hook;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = BID_PER_SECOND;
        config.maxBid = 10 ether;
        config.resaleMultiplierBps = 12_000;
        config.askDecayWindow = 0;
        config.owner = makeAddr("owner");
        config.curve = makeAddr("curve");
        desk.initialize(config);

        vm.deal(hook, 100 ether);
        vm.prank(hook);
        desk.addFees{value: 20 ether}();

        target.mint(seller, 10 * BAG);
        target.mint(rival, 10 * BAG);
        vm.prank(seller);
        target.approve(address(desk), type(uint256).max);
        vm.prank(rival);
        target.approve(address(desk), type(uint256).max);
    }

    /// @notice The race the finding describes: a rival's sale resets the ramp a moment before the
    /// seller's lands. With a minimum, the late sale is refused and the seller keeps the bag,
    /// instead of selling it for the second of bid that has climbed since.
    function test_ASellerOvertakenByTheRampResetKeepsTheBag() public {
        vm.warp(block.timestamp + 1000);
        uint256 quoted = desk.currentBid();

        vm.prank(rival);
        desk.buyTokens();
        vm.warp(block.timestamp + 2);

        vm.prank(seller);
        vm.expectRevert(SweepERC20Strategy.PriceBelowMinimum.selector);
        desk.buyTokensBounded(quoted, block.timestamp);

        assertEq(target.balanceOf(seller), 10 * BAG, "the seller keeps every bag");
    }

    /// @notice A bid at or above the seller's minimum pays the whole bid, exactly as before.
    function test_ASaleAtOrAboveTheMinimumPaysTheBid() public {
        vm.warp(block.timestamp + 1000);
        uint256 bid = desk.currentBid();
        uint256 before = seller.balance;

        vm.prank(seller);
        desk.buyTokensBounded(bid, block.timestamp);

        assertEq(seller.balance - before, bid);
        assertEq(desk.bagsHeld(), 1);
    }

    /// @notice An offer that sat past its deadline does not execute, whatever the bid.
    function test_ASaleAfterItsDeadlineIsRefused() public {
        vm.warp(block.timestamp + 1000);
        uint256 deadline = block.timestamp - 1;

        vm.prank(seller);
        vm.expectRevert(SweepERC20Strategy.Expired.selector);
        desk.buyTokensBounded(0, deadline);
    }

    /// @notice The unbounded form stays, so existing callers keep working; it is the bounded form
    /// with no minimum and no deadline.
    function test_TheUnboundedFormStillSells() public {
        vm.warp(block.timestamp + 1000);
        uint256 bid = desk.currentBid();
        uint256 before = seller.balance;

        vm.prank(seller);
        desk.buyTokens();

        assertEq(seller.balance - before, bid);
    }
}
