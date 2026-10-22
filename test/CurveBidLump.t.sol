// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SweepForkTest} from "./shared/SweepForkTest.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";

/**
 * @title CurveBidLumpTest
 * @author 0xDAVZER
 * @notice Audit C-2 of PR #74, reproduced with the launch terms the site sends: a cap of ten times
 * the floor and a ramp that reaches the floor in 300 seconds. A desk idle on its curve for a day
 * has its whole ramp saved; one large curve buy then credits the treasury in one lump.
 */
contract CurveBidLumpTest is SweepForkTest {
    uint256 internal constant FLOOR = 0.0004 ether;

    function _idleDeskThenLump() internal returns (SweepNFTStrategy s, uint256 treasuryBefore) {
        vm.prank(launcher);
        address strategy =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Lump", "LUMP", FLOOR / 300, FLOOR * 10);
        s = SweepNFTStrategy(payable(strategy));
        SweepBondingCurve curve = SweepBondingCurve(payable(factory.curveOf(strategy)));

        vm.warp(block.timestamp + 5);
        vm.deal(trader, trader.balance + 0.01 ether);
        vm.prank(trader);
        curve.buy{value: 0.01 ether}(0, trader);
        vm.warp(block.timestamp + 1 days);
        treasuryBefore = s.treasury();

        vm.deal(whale, whale.balance + 4 ether);
        vm.prank(whale);
        curve.buy{value: 4 ether}(0, whale);
    }

    /// @notice A lump of fees does not become biddable at once: in the block it arrives, the bid
    /// is at most what was biddable before it, so sellers cannot empty a saved ramp against it.
    function test_ALumpOfFeesIsNotBiddableInTheBlockItArrives() public {
        (SweepNFTStrategy s, uint256 treasuryBefore) = _idleDeskThenLump();
        emit log_named_uint("treasury before the lump", treasuryBefore);
        emit log_named_uint("treasury after the lump", s.treasury());
        emit log_named_uint("bid in the same block", s.currentBid());
        assertLe(s.currentBid(), treasuryBefore, "the lump was biddable in the block it arrived");
    }

    /// @notice How much of a lump floor-priced pieces can take in one block: counts the purchases
    /// at the full bid a seller could make back to back, the pieces each worth the floor.
    function test_HowManyPiecesAtTheCapOneBlockCanSell() public {
        (SweepNFTStrategy s,) = _idleDeskThenLump();
        uint256 sold;
        uint256 paid;
        collection.setApprovalForAll(address(market), true);
        while (s.currentBid() > FLOOR && sold < 100) {
            uint256 bid = s.currentBid();
            uint256 tokenId = collection.mint(address(this));
            market.list(address(collection), tokenId, bid);
            s.buyTargetNFT(
                bid, abi.encodeCall(market.fulfill, (address(collection), tokenId)), tokenId, address(market)
            );
            sold++;
            paid += bid;
        }
        emit log_named_uint("pieces sold in one block", sold);
        emit log_named_uint("ETH paid", paid);
        emit log_named_uint("worth at floor", sold * FLOOR);
        assertLe(paid, sold * FLOOR * 2, "one block paid more than twice the floor per piece");
    }
}
