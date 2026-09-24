// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";

/**
 * @title EndToEndTest
 * @author 0xDAVZER
 * @notice The whole machine, once around, on the real chain. Every contract has its own suite; this is
 * the one test that says they fit together. It prints what it sees, because the numbers are the
 * point: what a trade costs, what the treasury holds, what the bid says, what a burn destroys.
 */
contract EndToEndTest is SweepForkTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    SweepNFTStrategy internal s;
    PoolKey internal key;
    uint256 internal tokenId;
    uint256 internal floor;
    uint256 internal ask;

    /**
     * @notice launch → first buy → later buy → the bid climbs → the desk buys → someone buys it back →
     * the burn lands, and the treasury is richer for it.
     *
     * @dev Each stage asserts the one thing that stage is for, and the whole is asserted at the
     * end as a conservation law: every wei in the strategy is accounted for by its own ledger. The
     * stages are functions and the state is storage only because the whole thing in one frame is
     * more locals than the EVM's stack holds without `via_ir`.
     */
    function test_TheWholeCycle() public {
        _stage1Launch();
        _stage2FirstBuy();
        _stage3LaterTrade();
        _stage4Bid();
        _stage5Sweep();
        _stage6Resell();
        _stage7Burn();
        _stage8Conservation();
    }

    function _stage1Launch() internal {
        (address strategy, PoolKey memory k) = _launch();
        s = SweepNFTStrategy(payable(strategy));
        key = k;
        assertEq(IERC721(address(factory.positionManager())).ownerOf(factory.positionIdOf(strategy)), DEAD);
        console2.log("1. launched         fee paid %s wei, position owned by 0x...dEaD", LAUNCH_FEE);
    }

    /// @dev The first buy of the pool's life pays the flat 10%, 80% of it into the treasury —
    /// the same deal as every buy after it, since the fee has no launch ramp.
    function _stage2FirstBuy() internal {
        _buy(key, 1 ether);
        assertGt(s.treasury(), 0.07 ether, "the first buy funded less than eight percent");
        assertLt(s.treasury(), 0.09 ether, "the first buy paid a launch premium");
        console2.log("2. bought 1 ETH     treasury %s wei, buyer holds %s tokens", s.treasury(), s.balanceOf(trader));
    }

    /// @dev Ninety minutes on, another buy pays exactly the same rate; the clock moves the bid,
    /// never the fee.
    function _stage3LaterTrade() internal {
        vm.warp(block.timestamp + 90 minutes);
        assertEq(hook.FEE_BPS(), 1000);
        uint256 before = s.treasury();
        _buy(key, 1 ether);
        console2.log("3. bought 1 ETH     at 10%%: treasury +%s wei", s.treasury() - before);
    }

    /// @dev The bid has climbed with the clock, bounded by the treasury.
    function _stage4Bid() internal {
        uint256 bid = s.currentBid();
        assertGt(bid, 0);
        assertLe(bid, s.treasury());
        floor = bid / 2;
        console2.log("4. bid now          %s wei  (treasury %s wei)", bid, s.treasury());
    }

    /// @dev A seller lists below the bid; the desk sweeps it, and the ramp restarts.
    function _stage5Sweep() internal {
        tokenId = collection.mint(address(this));
        collection.setApprovalForAll(address(market), true);
        market.list(address(collection), tokenId, floor);
        s.buyTargetNFT(floor, abi.encodeCall(market.fulfill, (address(collection), tokenId)), tokenId, address(market));
        assertEq(collection.ownerOf(tokenId), address(s));
        assertEq(s.currentBid(), 0, "the ramp did not restart");
        ask = s.askPrice(tokenId);
        assertEq(ask, (floor * 12_000) / 10_000, "ask is not 1.2x");
        console2.log("5. swept #%s         paid %s wei, ask now %s wei", tokenId, floor, ask);
    }

    /// @dev Someone buys it back at the ask; the proceeds queue for burning, never the treasury.
    function _stage6Resell() internal {
        uint256 treasuryBefore = s.treasury();
        vm.deal(trader, trader.balance + ask);
        vm.prank(trader);
        s.sellTargetNFT{value: ask}(tokenId);
        assertEq(collection.ownerOf(tokenId), trader);
        assertEq(s.pendingBurn(), ask);
        assertEq(s.treasury(), treasuryBefore, "proceeds leaked into the treasury");
        console2.log("6. resold #%s        for %s wei -> pendingBurn", tokenId, ask);
    }

    /// @dev Anyone triggers the burn; the caller is paid, the fee recycles, the supply shrinks.
    function _stage7Burn() internal {
        uint256 deadBefore = s.balanceOf(DEAD);
        uint256 circulatingBefore = s.circulatingSupply();
        uint256 treasuryBefore = s.treasury();
        address keeper = makeAddr("keeper");

        vm.prank(keeper);
        (uint256 spent, uint256 reward) = s.processBurn();

        uint256 burnt = s.balanceOf(DEAD) - deadBefore;
        assertEq(spent + reward, ask);
        assertEq(keeper.balance, reward);
        assertGt(burnt, 0);
        assertEq(s.circulatingSupply(), circulatingBefore - burnt);
        assertGt(s.treasury(), treasuryBefore, "the burn's fee did not recycle");
        console2.log("7. burnt            %s tokens; keeper paid %s wei", burnt, reward);
        console2.log("   treasury         +%s wei recycled from the burn's own fee", s.treasury() - treasuryBefore);
    }

    /// @dev Every wei in the strategy and the hook is one its ledger names.
    function _stage8Conservation() internal view {
        assertEq(address(s).balance, s.treasury() + s.pendingBurn(), "ETH in the strategy is not accounted for");
        assertEq(
            address(hook).balance,
            hook.accruedFees(feeTo) + hook.accruedFees(launcher),
            "ETH in the hook is not accounted for"
        );
        console2.log("8. conserved        strategy holds %s wei = treasury + pendingBurn", address(s).balance);
        console2.log("   collection owed  %s wei, claimable by anyone on its behalf", hook.accruedFees(launcher));
    }
}
