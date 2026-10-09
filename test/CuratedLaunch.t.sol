// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {TargetToken} from "./mocks/TargetToken.sol";

/// @notice The two hook calls a launch makes, and nothing else: enough to launch on a local
/// factory without a PoolManager.
contract LaunchOnlyHook {
    address public immutable factory;
    address public protocolFeeRecipient;
    mapping(address => address) public creatorFeeRecipient;

    constructor(address factory_, address protocol_) {
        factory = factory_;
        protocolFeeRecipient = protocol_;
    }

    function registerCreatorFeeRecipient(address strategy, address recipient) external {
        creatorFeeRecipient[strategy] = recipient;
    }
}

/**
 * @title CuratedLaunchTest
 * @notice Decision 0018: the public launch paths accept only a target the owner has admitted,
 * until the owner opens launches to every target.
 */
contract CuratedLaunchTest is Test {
    SweepNFTStrategyFactory internal factory;
    SweepTestCollection internal collection;
    TargetToken internal token;
    address internal launcher = makeAddr("launcher");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant FEE = 0.001 ether;
    uint256 internal constant BID_PER_SECOND = 0.0001 ether;
    uint256 internal constant MAX_BID = 1 ether;

    function setUp() public {
        vm.warp(1_788_000_000);
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
        factory.setHook(address(new LaunchOnlyHook(address(factory), makeAddr("protocol"))));
        factory.setBurnRouter(address(new MockBurnRouter()));
        factory.setERC20Implementation(address(new SweepERC20Strategy()));
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        factory.setCurveImplementation(address(new SweepBondingCurve(1.68 ether, 4.2 ether)));

        collection = new SweepTestCollection("Curated", "CUR", "");
        token = new TargetToken();
        token.mint(address(this), 1_000_000e18);
        vm.deal(launcher, 1 ether);
    }

    /// @notice A fresh factory admits no target, so nothing a stranger points it at can launch
    /// while the deploy is still being wired.
    function test_TheFactoryDeploysCurated() public view {
        assertFalse(factory.openLaunches());
        assertFalse(factory.isLaunchTarget(address(collection)));
    }

    /// @notice A collection the owner has not admitted cannot be launched on.
    function test_ALaunchOnAnUnadmittedCollectionIsRefused() public {
        vm.prank(launcher);
        vm.expectRevert(SweepNFTStrategyFactory.TargetNotAdmitted.selector);
        factory.launch{value: FEE}(address(collection), "Sweep", "SWP", BID_PER_SECOND, MAX_BID);
    }

    /// @notice An admitted collection launches as it always did.
    function test_ALaunchOnAnAdmittedCollectionSucceeds() public {
        factory.setLaunchTarget(address(collection), true);

        vm.prank(launcher);
        address strategy = factory.launch{value: FEE}(address(collection), "Sweep", "SWP", BID_PER_SECOND, MAX_BID);

        assertTrue(factory.isStrategy(strategy));
    }

    /// @notice A bag desk on a token the owner has not admitted is refused the same way.
    function test_AnERC20LaunchOnAnUnadmittedTokenIsRefused() public {
        vm.prank(launcher);
        vm.expectRevert(SweepNFTStrategyFactory.TargetNotAdmitted.selector);
        factory.launchERC20{value: FEE}(address(token), "Bag", "BAG", BID_PER_SECOND, MAX_BID);
    }

    /// @notice An admitted token launches a bag desk as it always did.
    function test_AnERC20LaunchOnAnAdmittedTokenSucceeds() public {
        factory.setLaunchTarget(address(token), true);

        vm.prank(launcher);
        address strategy = factory.launchERC20{value: FEE}(address(token), "Bag", "BAG", BID_PER_SECOND, MAX_BID);

        assertTrue(factory.isStrategy(strategy));
    }

    /// @notice Opening launches restores decision 0009: any target, no list.
    function test_OpenLaunchesAdmitEveryTarget() public {
        factory.setOpenLaunches(true);

        vm.prank(launcher);
        address strategy = factory.launch{value: FEE}(address(collection), "Sweep", "SWP", BID_PER_SECOND, MAX_BID);

        assertTrue(factory.isStrategy(strategy));
    }

    /// @notice Withdrawing a target stops future launches on it and leaves the ones it already
    /// carries exactly as they were.
    function test_WithdrawingATargetLeavesItsStrategiesAlone() public {
        factory.setLaunchTarget(address(collection), true);
        vm.prank(launcher);
        address strategy = factory.launch{value: FEE}(address(collection), "Sweep", "SWP", BID_PER_SECOND, MAX_BID);

        factory.setLaunchTarget(address(collection), false);

        assertTrue(factory.isStrategy(strategy));
        assertEq(factory.strategyToCollection(strategy), address(collection));
        vm.prank(launcher);
        vm.expectRevert(SweepNFTStrategyFactory.TargetNotAdmitted.selector);
        factory.launch{value: FEE}(address(collection), "Again", "AGN", BID_PER_SECOND, MAX_BID);
    }

    /// @notice The owner is the curator, so its own launch paths are not gated.
    function test_OwnerLaunchesAreNotGated() public {
        address strategy = factory.ownerLaunch{value: FEE}(
            address(collection), "Sweep", "SWP", BID_PER_SECOND, MAX_BID, makeAddr("creator")
        );
        address bagDesk = factory.ownerLaunchERC20{value: FEE}(
            address(token), 1000e18, "Bag", "BAG", BID_PER_SECOND, MAX_BID, makeAddr("creator")
        );

        assertTrue(factory.isStrategy(strategy));
        assertTrue(factory.isStrategy(bagDesk));
    }

    /// @notice A recursive strategy has no target to lie about, so it is not gated.
    function test_RecursiveLaunchesAreNotGated() public {
        vm.prank(launcher);
        address strategy = factory.launchRecursive{value: FEE}("Loop", "LOOP");

        assertTrue(factory.isStrategy(strategy));
    }

    /// @notice Only the owner admits targets or opens launches.
    function test_OnlyTheOwnerCurates() public {
        vm.startPrank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setLaunchTarget(address(collection), true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setOpenLaunches(true);
        vm.stopPrank();
    }

    /// @notice Both setters are announced, so an indexer and a watcher see the list change.
    function test_CurationIsAnnounced() public {
        vm.expectEmit(true, false, false, true, address(factory));
        emit SweepNFTStrategyFactory.LaunchTargetSet(address(collection), true);
        factory.setLaunchTarget(address(collection), true);

        vm.expectEmit(false, false, false, true, address(factory));
        emit SweepNFTStrategyFactory.OpenLaunchesSet(true);
        factory.setOpenLaunches(true);
    }

    /// @notice The zero address is never a target, so admitting it is refused rather than recorded.
    function test_TheZeroAddressCannotBeAdmitted() public {
        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setLaunchTarget(address(0), true);
    }
}
