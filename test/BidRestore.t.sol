// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {SweepStrategy} from "../src/SweepStrategy.sol";
import {StrategyHarness} from "./mocks/StrategyHarness.sol";

/**
 * @title BidRestoreTest
 * @notice SC-09: lowering the bid is the owner's only brake, and it must be releasable. A value
 * that was already in force can be restored at once; anything above it still climbs at most 2x
 * per `BID_RAISE_COOLDOWN`.
 */
contract BidRestoreTest is Test {
    StrategyHarness internal strategy;
    address internal owner = makeAddr("owner");

    uint256 internal constant INCREASE = 0.001 ether;
    uint256 internal constant CAP = 5 ether;

    function setUp() public {
        vm.warp(1_788_000_000);
        strategy = StrategyHarness(payable(LibClone.clone(address(new StrategyHarness()))));
        strategy.initialize(
            "Brake", "BRK", makeAddr("hook"), makeAddr("poolManager"), makeAddr("curve"), INCREASE, CAP, owner
        );
    }

    /// @notice The finding: after an emergency lowering to the minimum, the previous terms come
    /// back in one call, not after a year of doublings.
    function test_ALoweredBidCanBeRestoredAtOnce() public {
        uint256 minIncrease = strategy.MIN_BID_INCREASE_PER_SECOND();
        vm.startPrank(owner);
        strategy.setBidParameters(minIncrease, 1);
        strategy.setBidParameters(INCREASE, CAP);
        vm.stopPrank();

        assertEq(strategy.bidIncreasePerSecond(), INCREASE);
        assertEq(strategy.maxBid(), CAP);
    }

    /// @notice Restoring does not spend the raise clock, so a genuine raise is still available.
    function test_ARestoreLeavesTheRaiseClockAlone() public {
        uint256 lastRaise = strategy.lastBidRaiseAt();
        vm.startPrank(owner);
        strategy.setBidParameters(INCREASE, 1);
        strategy.setBidParameters(INCREASE, CAP);
        vm.stopPrank();

        assertEq(strategy.lastBidRaiseAt(), lastRaise);
    }

    /// @notice Anything above what was in force is still a raise: bounded at 2x of the current
    /// value and paced by the cooldown.
    function test_AboveWhatWasInForceIsStillARaise() public {
        vm.startPrank(owner);
        strategy.setBidParameters(INCREASE, 1);
        vm.expectRevert(SweepStrategy.BidRaiseTooLarge.selector);
        strategy.setBidParameters(INCREASE, CAP + 1);
        vm.stopPrank();
    }

    /// @notice A genuine raise, once made, becomes a value that may later be restored too.
    function test_ARaisedValueBecomesRestorable() public {
        vm.warp(block.timestamp + strategy.BID_RAISE_COOLDOWN());
        vm.startPrank(owner);
        strategy.setBidParameters(INCREASE, CAP * 2);
        strategy.setBidParameters(INCREASE, 1);
        strategy.setBidParameters(INCREASE, CAP * 2);
        vm.stopPrank();

        assertEq(strategy.maxBid(), CAP * 2);
    }
}
