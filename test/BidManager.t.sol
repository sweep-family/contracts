// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {SweepStrategy} from "../src/SweepStrategy.sol";
import {SweepToken} from "../src/SweepToken.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {StrategyHarness} from "./mocks/StrategyHarness.sol";
import {MockStrategyHook} from "./mocks/MockStrategyHook.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {TargetToken} from "./mocks/TargetToken.sol";

/**
 * @title BidManagerSpec
 * @notice The keeper's narrow bid role (decision 0019). A desk launches with a high ceiling so
 * its restorable highs are high, is lowered at once to near the floor, and from then on a bid
 * manager the factory lists may move the bid anywhere between the absolute minimums and those
 * highs, at once — and never above them.
 *
 * @dev Written once against `SweepStrategy` and run for every kind of desk that has a bid: the
 * base harness, the NFT desk and the bag desk. The recursive strategy has no bid and is not a
 * `SweepStrategy`. Each kind resolves its factory the way production does, through its hook's
 * `factory()`, and the factory here is the real one, so the listing a test writes is the listing
 * the desk reads.
 */
abstract contract BidManagerSpec is Test {
    SweepNFTStrategyFactory internal factory;
    SweepStrategy internal strategy;
    address internal hook;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant HIGH_INCREASE = 0.001 ether;
    uint256 internal constant HIGH_CAP = 10 ether;
    uint256 internal constant LOW_INCREASE = 0.0001 ether;
    uint256 internal constant LOW_CAP = 1.3 ether;

    function setUp() public {
        vm.warp(1_788_000_000);
        factory = _newFactory();
        hook = address(new MockStrategyHook(address(factory), makeAddr("protocol")));
        strategy = _deployStrategy(hook);

        factory.setBidManager(manager, true);

        vm.prank(owner);
        strategy.setBidParameters(LOW_INCREASE, LOW_CAP);
    }

    /// @dev Deploys the kind of desk under test with `HIGH_INCREASE` and `HIGH_CAP` at launch.
    function _deployStrategy(address hook_) internal virtual returns (SweepStrategy);

    /// @dev A real factory, owned by the test, wired with nothing it does not need here.
    function _newFactory() internal returns (SweepNFTStrategyFactory) {
        return new SweepNFTStrategyFactory(
            makeAddr("positionManager"),
            makeAddr("permit2"),
            makeAddr("poolManager"),
            address(new SweepNFTStrategy()),
            makeAddr("launchFeeRecipient"),
            address(this),
            1.68 ether,
            4.2 ether
        );
    }

    /// @notice The launch-high-then-lower pattern leaves the launch values restorable.
    function test_TheLaunchCeilingStaysRestorableAfterTheOwnerLowersIt() public view {
        assertEq(strategy.maxBid(), LOW_CAP);
        assertEq(strategy.restorableMaxBid(), HIGH_CAP);
        assertEq(strategy.restorableIncreasePerSecond(), HIGH_INCREASE);
    }

    /// @notice A listed manager may lower the bid.
    function test_ABidManagerCanLowerTheBid() public {
        vm.prank(manager);
        strategy.manageBid(LOW_INCREASE / 2, 1 ether);

        assertEq(strategy.bidIncreasePerSecond(), LOW_INCREASE / 2);
        assertEq(strategy.maxBid(), 1 ether);
    }

    /// @notice A listed manager may raise the bid back up to the restorable highs in the same
    /// block, with no 2x step and no cooldown, which is what lets a keeper follow a rising floor.
    function test_ABidManagerCanRestoreUpToTheRestorableHighsAtOnce() public {
        vm.prank(manager);
        strategy.manageBid(HIGH_INCREASE, HIGH_CAP);

        assertEq(strategy.bidIncreasePerSecond(), HIGH_INCREASE);
        assertEq(strategy.maxBid(), HIGH_CAP);
    }

    /// @notice One wei of ceiling above the restorable high is refused.
    function test_ABidManagerCannotExceedTheRestorableMaxBid() public {
        vm.prank(manager);
        vm.expectRevert(SweepStrategy.BidAboveRestorable.selector);
        strategy.manageBid(LOW_INCREASE, HIGH_CAP + 1);
    }

    /// @notice One wei per second of ramp above the restorable high is refused.
    function test_ABidManagerCannotExceedTheRestorableIncrease() public {
        vm.prank(manager);
        vm.expectRevert(SweepStrategy.BidAboveRestorable.selector);
        strategy.manageBid(HIGH_INCREASE + 1, LOW_CAP);
    }

    /// @notice Waiting out the owner's raise cooldown opens nothing for a manager: there is no
    /// paced raise on this path at all.
    function test_ABidManagerCannotRaiseEvenAfterTheRaiseCooldown() public {
        vm.warp(block.timestamp + strategy.BID_RAISE_COOLDOWN());
        vm.prank(manager);
        vm.expectRevert(SweepStrategy.BidAboveRestorable.selector);
        strategy.manageBid(HIGH_INCREASE, HIGH_CAP + 1);
    }

    /// @notice Nothing a manager does moves the restorable highs or the raise clock; only the
    /// owner's paced `setBidParameters` can.
    function test_ABidManagerNeverMovesTheRestorableHighsOrTheRaiseClock() public {
        uint256 lastRaise = strategy.lastBidRaiseAt();
        vm.startPrank(manager);
        strategy.manageBid(LOW_INCREASE / 2, 1);
        strategy.manageBid(HIGH_INCREASE, HIGH_CAP);
        vm.stopPrank();

        assertEq(strategy.restorableIncreasePerSecond(), HIGH_INCREASE);
        assertEq(strategy.restorableMaxBid(), HIGH_CAP);
        assertEq(strategy.lastBidRaiseAt(), lastRaise);
    }

    /// @notice Whatever a manager asks for, the terms in force and the restorable highs end at or
    /// below the highs the owner set.
    function testFuzz_AManagedBidNeverEndsAboveTheRestorableHighs(uint256 increase, uint256 cap) public {
        vm.prank(manager);
        try strategy.manageBid(increase, cap) {} catch {}

        assertLe(strategy.bidIncreasePerSecond(), HIGH_INCREASE);
        assertLe(strategy.maxBid(), HIGH_CAP);
        assertEq(strategy.restorableIncreasePerSecond(), HIGH_INCREASE);
        assertEq(strategy.restorableMaxBid(), HIGH_CAP);
    }

    /// @notice An address the factory does not list is refused.
    function test_AStrangerCannotManageTheBid() public {
        vm.prank(stranger);
        vm.expectRevert(SweepStrategy.NotBidManager.selector);
        strategy.manageBid(LOW_INCREASE, LOW_CAP);
    }

    /// @notice Revocation takes effect on the next call, with nothing to do on the desk.
    function test_ARevokedBidManagerIsRefused() public {
        factory.setBidManager(manager, false);

        vm.prank(manager);
        vm.expectRevert(SweepStrategy.NotBidManager.selector);
        strategy.manageBid(LOW_INCREASE, LOW_CAP);
    }

    /// @notice The listing a desk honours is its own factory's, read through its hook. A manager
    /// listed on some other factory is a stranger here.
    function test_AManagerListedOnAnotherFactoryIsRefused() public {
        address elsewhere = makeAddr("elsewhere");
        _newFactory().setBidManager(elsewhere, true);

        vm.prank(elsewhere);
        vm.expectRevert(SweepStrategy.NotBidManager.selector);
        strategy.manageBid(LOW_INCREASE, LOW_CAP);
    }

    /// @notice The owner may use the same narrow path without being listed.
    function test_TheOwnerMayManageTheBidWithoutBeingListed() public {
        vm.prank(owner);
        strategy.manageBid(HIGH_INCREASE, HIGH_CAP);

        assertEq(strategy.maxBid(), HIGH_CAP);
    }

    /// @notice The absolute bounds of `setBidParameters` bind a manager too.
    function test_ManageBidKeepsTheAbsoluteBounds() public {
        uint256 minIncrease = strategy.MIN_BID_INCREASE_PER_SECOND();
        vm.startPrank(manager);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.manageBid(minIncrease - 1, LOW_CAP);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.manageBid(LOW_INCREASE, 0);
        vm.stopPrank();
    }

    /// @notice A managed change is announced with the event every bid change already uses.
    function test_ManageBidEmitsBidParametersUpdated() public {
        vm.expectEmit(address(strategy));
        emit SweepStrategy.BidParametersUpdated(HIGH_INCREASE, 2 ether);
        vm.prank(manager);
        strategy.manageBid(HIGH_INCREASE, 2 ether);
    }

    /// @notice A managed change is a bid change, so it restarts the wait `retire` imposes after
    /// one: a manager lowering a desk never makes it retirable at once.
    function test_ManageBidRestartsTheRetireGraceClock() public {
        vm.warp(block.timestamp + 1 days);
        vm.prank(manager);
        strategy.manageBid(LOW_INCREASE, 1 ether);

        assertEq(strategy.lastBidChangeAt(), block.timestamp);
    }

    /// @notice The owner's path is untouched: a raise above the highs is still paced at 2x.
    function test_TheOwnerPathStillPacesRaisesAboveTheHighs() public {
        vm.prank(owner);
        vm.expectRevert(SweepStrategy.BidRaiseTooLarge.selector);
        strategy.setBidParameters(LOW_INCREASE, HIGH_CAP + 1);
    }

    /// @notice Only the owner of the desk retunes the burn; a bid manager holds nothing else.
    function test_ABidManagerHoldsNoOtherOwnerPower() public {
        vm.startPrank(manager);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setBidParameters(LOW_INCREASE, LOW_CAP);
        vm.expectRevert(Ownable.Unauthorized.selector);
        strategy.setBurnPacing(0.1 ether, 12);
        vm.stopPrank();
    }
}

/// @notice The spec against the bare base, through the harness.
contract BidManagerBaseTest is BidManagerSpec {
    function _deployStrategy(address hook_) internal override returns (SweepStrategy) {
        StrategyHarness s = StrategyHarness(payable(LibClone.clone(address(new StrategyHarness()))));
        s.initialize(
            "Managed", "MGD", hook_, makeAddr("poolManager"), makeAddr("curve"), HIGH_INCREASE, HIGH_CAP, owner
        );
        return s;
    }
}

/// @notice The spec against the NFT desk.
contract BidManagerNFTTest is BidManagerSpec {
    function _deployStrategy(address hook_) internal override returns (SweepStrategy) {
        SweepNFTStrategy s = SweepNFTStrategy(payable(LibClone.clone(address(new SweepNFTStrategy()))));
        SweepNFTStrategy.Config memory config;
        config.collection = address(new SweepTestCollection("Managed", "MGD", ""));
        config.burnRouter = address(new MockBurnRouter());
        config.name = "Managed Strategy";
        config.symbol = "MGSTR";
        config.hook = hook_;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = HIGH_INCREASE;
        config.maxBid = HIGH_CAP;
        config.resaleMultiplierBps = 14_000;
        config.askDecayWindow = 30 days;
        config.owner = owner;
        config.curve = makeAddr("curve");
        s.initialize(config);
        return s;
    }
}

/// @notice The spec against the bag desk.
contract BidManagerERC20Test is BidManagerSpec {
    function _deployStrategy(address hook_) internal override returns (SweepStrategy) {
        SweepERC20Strategy s = SweepERC20Strategy(payable(LibClone.clone(address(new SweepERC20Strategy()))));
        SweepERC20Strategy.Config memory config;
        config.token = address(new TargetToken());
        config.bagSize = 100_000e18;
        config.burnRouter = address(new MockBurnRouter());
        config.name = "Managed Bag";
        config.symbol = "MGBAG";
        config.hook = hook_;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = HIGH_INCREASE;
        config.maxBid = HIGH_CAP;
        config.resaleMultiplierBps = 14_000;
        config.askDecayWindow = 30 days;
        config.owner = owner;
        config.curve = makeAddr("curve");
        s.initialize(config);
        return s;
    }
}

/**
 * @title BidManagerFactoryTest
 * @notice The listing itself: only the factory's owner writes it, never for the zero address,
 * and every write is announced.
 */
contract BidManagerFactoryTest is Test {
    SweepNFTStrategyFactory internal factory;
    address internal manager = makeAddr("manager");

    function setUp() public {
        factory = new SweepNFTStrategyFactory(
            makeAddr("positionManager"),
            makeAddr("permit2"),
            makeAddr("poolManager"),
            address(new SweepNFTStrategy()),
            makeAddr("launchFeeRecipient"),
            address(this),
            1.68 ether,
            4.2 ether
        );
    }

    /// @notice A fresh factory lists nobody.
    function test_AFreshFactoryListsNoBidManager() public view {
        assertFalse(factory.isBidManager(manager));
    }

    /// @notice The owner lists and delists.
    function test_TheOwnerCanListAndRevokeABidManager() public {
        factory.setBidManager(manager, true);
        assertTrue(factory.isBidManager(manager));
        factory.setBidManager(manager, false);
        assertFalse(factory.isBidManager(manager));
    }

    /// @notice Nobody else can, the would-be manager included.
    function test_OnlyTheOwnerCanSetABidManager() public {
        vm.prank(manager);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setBidManager(manager, true);
    }

    /// @notice The zero address is refused.
    function test_TheZeroAddressCannotBeABidManager() public {
        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setBidManager(address(0), true);
    }

    /// @notice Both directions are announced.
    function test_SettingABidManagerEmitsBidManagerSet() public {
        vm.expectEmit(address(factory));
        emit SweepNFTStrategyFactory.BidManagerSet(manager, true);
        factory.setBidManager(manager, true);

        vm.expectEmit(address(factory));
        emit SweepNFTStrategyFactory.BidManagerSet(manager, false);
        factory.setBidManager(manager, false);
    }
}
