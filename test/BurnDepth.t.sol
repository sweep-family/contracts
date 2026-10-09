// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {SweepForkTest} from "./shared/SweepForkTest.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {SweepStrategy} from "../src/SweepStrategy.sol";
import {BurnSandwicher} from "./mocks/BurnSandwicher.sol";

/// @notice Buys, triggers a distribution, and sells into the price it pushed up, in one call.
contract DistributionSandwicher {
    /// @notice Runs the sandwich and returns the ETH it ended with.
    function run(SweepSwapRouter router, SweepRecursiveStrategy strategy) external payable returns (uint256) {
        uint256 bought = router.buy{value: msg.value}(address(strategy), 0, block.timestamp);
        strategy.distribute();
        strategy.approve(address(router), bought);
        router.sell(address(strategy), bought, 0, block.timestamp);
        uint256 out = address(this).balance;
        payable(msg.sender).transfer(out);
        return out;
    }

    receive() external payable {}
}

/**
 * @title BurnDepthTest
 * @author 0xDAVZER
 * @notice Every buy the protocol makes on its own pool — a desk's burn pass, a recursive
 * strategy's distribution — is bounded by a fixed share of the pool's live ETH depth, so no
 * sandwich around it pays, whatever the price has done since graduation.
 *
 * @dev A constant cap was not enough. A full-range position's ETH side shrinks with the square
 * root of the price, and a memecoin at a tenth of its graduation price has a third of the depth
 * it opened with: on that pool, a 0.25 ETH pass was sandwiched at about 7%. Sizing the buy off
 * the depth it is about to move keeps the ratio — and the attacker's arithmetic — the same at
 * every price.
 */
contract BurnDepthTest is SweepForkTest {
    using stdStorage for StdStorage;
    using PoolIdLibrary for *;
    using StateLibrary for IPoolManager;

    /// @dev The whale that graduated the launch sells nine tenths of its bag: the price falls
    /// to a fraction of the graduation price and the pool's ETH side with it.
    function _dump(address strategy) internal {
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        uint256 dump = (s.balanceOf(whale) * 9) / 10;
        vm.startPrank(whale);
        s.approve(address(sweepRouter), dump);
        sweepRouter.sell(strategy, dump, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev The pool's ETH reserve as a full-range position holds it: `L / sqrtP`.
    function _ethDepth(address strategy) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(_poolKeyFor(strategy).toId());
        uint128 liquidity = manager.getLiquidity(_poolKeyFor(strategy).toId());
        return FixedPointMathLib.fullMulDiv(liquidity, 1 << 96, sqrtPriceX96);
    }

    function _launchRecursive() internal returns (SweepRecursiveStrategy s) {
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        vm.prank(launcher);
        address strategy = factory.launchRecursive{value: LAUNCH_FEE}("Depth Recursive", "dREC");
        _graduate(strategy);
        s = SweepRecursiveStrategy(payable(strategy));
    }

    /// @notice The bound is a fixed share of the pool's ETH reserve, read live.
    function test_MaxBurnBuyIsAFixedShareOfThePoolsEthDepth() public {
        (address strategy,) = _launch();
        uint256 share = burnRouter.MAX_BURN_DEPTH_BPS();
        assertEq(burnRouter.maxBurnBuy(strategy), (_ethDepth(strategy) * share) / 10_000);
        _dump(strategy);
        assertEq(burnRouter.maxBurnBuy(strategy), (_ethDepth(strategy) * share) / 10_000);
    }

    /// @notice Once the price has fallen, a pass is the depth bound, below the owner's cap, and
    /// the rest of the queue waits for the next pass.
    function test_ABurnPassIsBoundedByThePoolsLiveDepth() public {
        (address strategy,) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        vm.warp(block.timestamp + 1 hours);
        _dump(strategy);

        uint256 cap = burnRouter.maxBurnBuy(strategy);
        uint256 maximum = s.MAX_BURN_INCREMENT();
        assertLt(cap, maximum, "the fallen pool's bound is not below the owner's cap");
        s.setBurnPacing(maximum, s.burnCooldown());
        stdstore.target(strategy).sig("pendingBurn()").checked_write(uint256(1 ether));
        vm.deal(strategy, strategy.balance + 1 ether);

        (uint256 spent, uint256 reward) = s.processBurn();
        assertEq(spent + reward, cap);
        assertEq(s.pendingBurn(), 1 ether - cap);
    }

    /// @notice After the price falls, no front-run from 0.05 to 3 ETH profits from a burn pass at
    /// the owner's maximum increment.
    function test_NoBurnPassIsSandwichedAtAProfitAfterThePriceFalls() public {
        (address strategy,) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        vm.warp(block.timestamp + 1 hours);
        _dump(strategy);
        s.setBurnPacing(s.MAX_BURN_INCREMENT(), s.burnCooldown());
        stdstore.target(strategy).sig("pendingBurn()").checked_write(uint256(1 ether));
        vm.deal(strategy, strategy.balance + 1 ether);

        BurnSandwicher attacker = new BurnSandwicher();
        for (uint256 i = 1; i <= 60; ++i) {
            uint256 frontRun = i * 0.05 ether;
            uint256 snap = vm.snapshotState();
            vm.deal(address(this), frontRun);
            uint256 out = attacker.run{value: frontRun}(sweepRouter, s);
            assertLt(out, frontRun, "a sandwich around a burn pass turned a profit");
            vm.revertToState(snap);
        }
    }

    /// @notice A distribution spends at most the depth bound; the rest stays pending.
    function test_ADistributionIsBoundedByThePoolsLiveDepth() public {
        SweepRecursiveStrategy s = _launchRecursive();
        vm.warp(block.timestamp + 1 hours);
        _dump(address(s));

        uint256 cap = burnRouter.maxBurnBuy(address(s));
        stdstore.target(address(s)).sig("pendingRewards()").checked_write(uint256(1 ether));
        vm.deal(address(s), address(s).balance + 1 ether);

        vm.recordLogs();
        s.distribute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("RewardsDistributed(uint256,uint256,uint256)");
        uint256 spent;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(s) && logs[i].topics[0] == topic) {
                (spent,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertEq(spent, cap, "the distribution did not spend exactly the depth bound");
        assertGt(s.pendingRewards(), 1 ether - cap - 1, "the rest did not stay pending");
    }

    /// @notice Distributions are paced: without it, one transaction could chain bounded
    /// distributions into one unbounded buy and sandwich the sum.
    function test_DistributionsArePacedByACooldown() public {
        SweepRecursiveStrategy s = _launchRecursive();
        vm.warp(block.timestamp + 1 hours);
        stdstore.target(address(s)).sig("pendingRewards()").checked_write(uint256(1 ether));
        vm.deal(address(s), address(s).balance + 1 ether);

        s.distribute();
        vm.expectRevert(SweepRecursiveStrategy.DistributeCooldownNotElapsed.selector);
        s.distribute();

        vm.warp(block.timestamp + s.DISTRIBUTE_COOLDOWN());
        s.distribute();
    }

    /// @notice After the price falls, no front-run from 0.05 to 3 ETH profits from a distribution.
    function test_NoDistributionIsSandwichedAtAProfitAfterThePriceFalls() public {
        SweepRecursiveStrategy s = _launchRecursive();
        vm.warp(block.timestamp + 1 hours);
        _dump(address(s));
        stdstore.target(address(s)).sig("pendingRewards()").checked_write(uint256(1 ether));
        vm.deal(address(s), address(s).balance + 1 ether);

        DistributionSandwicher attacker = new DistributionSandwicher();
        for (uint256 i = 1; i <= 60; ++i) {
            uint256 frontRun = i * 0.05 ether;
            uint256 snap = vm.snapshotState();
            vm.deal(address(this), frontRun);
            uint256 out = attacker.run{value: frontRun}(sweepRouter, s);
            assertLt(out, frontRun, "a sandwich around a distribution turned a profit");
            vm.revertToState(snap);
        }
    }
}
