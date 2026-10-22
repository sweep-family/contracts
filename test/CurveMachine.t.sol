// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SweepForkTest} from "./shared/SweepForkTest.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepStrategy} from "../src/SweepStrategy.sol";

/**
 * @title CurveMachineTest
 * @author 0xDAVZER
 * @notice The machine runs from the curve (decision 0021): the curve's trades fund the treasury
 * from the first buy, the desk buys a piece before graduation, a sale made before graduation waits
 * for the pool to be burnt, and graduation leaves the running desk's bid ramp alone.
 *
 * @dev On the fork, against the real factory, curve, hook and burn router: the claims are about
 * how the pieces fit, which a mock of any of them would assume rather than prove.
 */
contract CurveMachineTest is SweepForkTest {
    /// @dev A launch still on its curve, its strategy, and a curve buy of `value` by the trader
    /// placed past the snipe window, so the treasury's share is exactly 2.4% of it.
    function _launchAndBuy(uint256 value) internal returns (SweepNFTStrategy s, SweepBondingCurve curve) {
        address strategy;
        (strategy, curve) = _launchOnCurve();
        s = SweepNFTStrategy(payable(strategy));
        vm.warp(block.timestamp + 5);
        vm.deal(trader, trader.balance + value);
        vm.prank(trader);
        curve.buy{value: value}(0, trader);
    }

    /// @dev Lists a fresh piece at `price` on the mock marketplace and has the desk buy it.
    function _deskBuys(SweepNFTStrategy s, uint256 price) internal returns (uint256 tokenId) {
        tokenId = collection.mint(address(this));
        collection.setApprovalForAll(address(market), true);
        market.list(address(collection), tokenId, price);
        s.buyTargetNFT(price, abi.encodeCall(market.fulfill, (address(collection), tokenId)), tokenId, address(market));
    }

    /// @notice A curve buy credits the treasury with 80% of its 3% fee in the same transaction,
    /// before any pool exists.
    function test_TheCurveFundsTheTreasuryFromTheFirstBuy() public {
        (SweepNFTStrategy s, SweepBondingCurve curve) = _launchAndBuy(1 ether);

        assertFalse(curve.graduated());
        assertEq(factory.positionIdOf(address(s)), 0, "no pool yet");
        assertEq(s.treasury(), 0.024 ether);
        assertEq(address(s).balance, 0.024 ether, "the treasury is backed by ETH the strategy holds");
    }

    /// @notice With the treasury funded and the bid ramped past a listing, the desk buys the
    /// piece while the launch is still on its curve.
    function test_ADeskBuysAPieceBeforeGraduation() public {
        (SweepNFTStrategy s, SweepBondingCurve curve) = _launchAndBuy(2 ether);
        vm.warp(block.timestamp + 30 minutes);

        uint256 tokenId = _deskBuys(s, 0.04 ether);

        assertFalse(curve.graduated());
        assertEq(collection.ownerOf(tokenId), address(s));
        assertEq(s.treasury(), 0.048 ether - 0.04 ether);
        assertEq(s.inventoryCount(), 1);
    }

    /// @notice A piece sold back before graduation returns its price to the treasury, which buys
    /// the floor again, instead of queueing a burn no pool can run (audit H-1 of PR #74); once
    /// the launch has graduated, a sale queues its burn as always.
    function test_SaleProceedsBeforeGraduationReturnToTheTreasury() public {
        (SweepNFTStrategy s,) = _launchAndBuy(2 ether);
        vm.warp(block.timestamp + 30 minutes);
        uint256 first = _deskBuys(s, 0.04 ether);
        uint256 treasuryBefore = s.treasury();

        uint256 ask = s.askPrice(first);
        vm.deal(trader, trader.balance + ask);
        vm.prank(trader);
        s.sellTargetNFT{value: ask}(first);
        assertEq(s.pendingBurn(), 0, "a curve sale queued a burn no pool can run");
        assertEq(s.treasury(), treasuryBefore + ask, "the proceeds did not return to the treasury");

        _graduate(address(s));
        vm.warp(block.timestamp + 1 days);
        uint256 second = _deskBuys(s, 0.04 ether);
        ask = s.askPrice(second);
        vm.deal(trader, trader.balance + ask);
        vm.prank(trader);
        s.sellTargetNFT{value: ask}(second);
        assertEq(s.pendingBurn(), ask, "a graduated sale did not queue its burn");
    }

    /// @notice A desk on its curve cannot be retired: retirement turns the treasury into burn queue,
    /// which needs a pool, so a desk retired before graduation would only strand its treasury
    /// (audit H-1 and the review's L-1).
    function test_ADeskCannotBeRetiredOnItsCurve() public {
        (SweepNFTStrategy s,) = _launchAndBuy(1 ether);
        vm.warp(block.timestamp + 365 days);
        vm.prank(s.owner());
        vm.expectRevert(SweepStrategy.StillOnCurve.selector);
        s.retire();
    }

    /// @notice A curve sell pays the treasury its 80% of the sell's 3% in the trade, on the real
    /// strategy, exactly as a buy does.
    function test_ACurveSellFundsTheTreasury() public {
        (SweepNFTStrategy s, SweepBondingCurve curve) = _launchAndBuy(1 ether);
        uint256 before = s.treasury();
        uint256 half = s.balanceOf(trader) / 2;
        uint256 gross = curve.quoteSell(half) * 10_000 / 9700;

        vm.startPrank(trader);
        s.approve(address(curve), half);
        curve.sell(half, 0, trader);
        vm.stopPrank();

        assertApproxEqAbs(s.treasury() - before, (gross * 240) / 10_000, 1e3, "a sell did not fund the treasury");
    }

    /// @notice A recursive strategy's curve fees reach `pendingRewards` from the first trade, wait
    /// there while no pool exists to buy on, and are distributed once the launch graduates.
    function test_ARecursiveCurveFundsRewardsThatWaitForThePool() public {
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        vm.prank(launcher);
        address strategy = factory.launchRecursive{value: LAUNCH_FEE}("Curve Recursive", "cREC");
        SweepRecursiveStrategy r = SweepRecursiveStrategy(payable(strategy));
        SweepBondingCurve curve = SweepBondingCurve(payable(factory.curveOf(strategy)));
        vm.warp(block.timestamp + 5);
        vm.deal(trader, trader.balance + 1 ether);
        vm.prank(trader);
        curve.buy{value: 1 ether}(0, trader);
        assertEq(r.pendingRewards(), 0.024 ether, "the curve did not fund the rewards");

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(SweepRecursiveStrategy.NothingToDistribute.selector);
        r.distribute();

        _graduate(strategy);
        vm.warp(block.timestamp + 1 hours);
        uint256 waiting = r.pendingRewards();
        r.distribute();
        assertLt(r.pendingRewards(), waiting, "nothing was distributed once the pool existed");
    }

    /// @notice Graduation no longer restarts the ramp: a desk that has been running on its curve
    /// keeps its bid across the moment the pool opens.
    function test_GraduationLeavesTheBidRampRunning() public {
        (SweepNFTStrategy s,) = _launchAndBuy(1 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 bidBefore = s.currentBid();
        assertGt(bidBefore, 0, "the desk was not running on its curve");

        _graduate(address(s));

        assertGe(s.currentBid(), bidBefore, "graduation reset the ramp");
    }
}
