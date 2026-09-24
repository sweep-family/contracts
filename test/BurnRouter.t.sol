// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";

/// @dev Reads the transient allowance from inside the burn's own transaction. See `SwapProbe`.
contract BurnProbe {
    function burnAndReadAllowance(SweepNFTStrategy strategy) external returns (uint256) {
        strategy.processBurn();
        return strategy.transferAllowance();
    }

    receive() external payable {}
}

/**
 * @title BurnRouterTest
 * @author 0xDAVZER
 * @notice The strategy's `processBurn` is the caller throughout, because that is the only
 * caller the router will ever have and the accounting is theirs jointly.
 */
contract BurnRouterTest is SweepForkTest {
    using CurrencyLibrary for Currency;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    SweepNFTStrategy internal s;
    PoolKey internal key;
    uint256 internal pending;

    /// @dev A launched strategy with resale proceeds waiting, at the resting fee rate.
    function setUp() public override {
        super.setUp();
        (address strategy, PoolKey memory k) = _launch();
        s = SweepNFTStrategy(payable(strategy));
        key = k;
        vm.warp(block.timestamp + 90 minutes);
        pending = _seedPendingBurn();
    }

    /// @notice The cycle closes: ETH that came from a resale becomes tokens at the dead address.
    function test_BurnBuysTheTokenAndSendsItToTheDeadAddress() public {
        uint256 deadBefore = s.balanceOf(DEAD);
        uint256 circulatingBefore = s.circulatingSupply();

        (uint256 spent, uint256 reward) = s.processBurn();

        assertGt(s.balanceOf(DEAD), deadBefore, "nothing reached the dead address");
        assertEq(s.circulatingSupply(), circulatingBefore - (s.balanceOf(DEAD) - deadBefore));
        assertEq(spent + reward, pending);
        assertEq(s.pendingBurn(), 0);
    }

    /// @notice The burn goes through the pool, the pool names the hook, and the router is not the
    /// hook — so the burn pays the fee, and eighty percent of it comes straight back as treasury.
    /// A number, not a sentence: the treasury rises during a burn with no trade having happened.
    function test_BurnPaysTheHookFeeAndRecyclesEightyPercentOfIt() public {
        uint256 treasuryBefore = s.treasury();
        uint256 protocolBefore = hook.accruedFees(feeTo);
        uint256 creatorBefore = hook.accruedFees(launcher);

        (uint256 spent,) = s.processBurn();

        uint256 toTreasury = s.treasury() - treasuryBefore;
        uint256 toProtocol = hook.accruedFees(feeTo) - protocolBefore;
        uint256 toCreator = hook.accruedFees(launcher) - creatorBefore;
        uint256 fee = toTreasury + toProtocol + toCreator;

        assertGt(fee, 0, "the burn paid no fee");
        assertEq(toTreasury, (fee * 80) / 100, "the treasury did not get its eighty percent");
        assertEq(toCreator, (fee * 10) / 100, "the collection did not get its tenth");
        assertApproxEqRel(fee, spent / 10, 0.02e18, "the fee is not a tenth of the burn");
    }

    /// @notice The hook's invariant, read from inside the transaction: the router takes to itself
    /// rather than straight to the dead address precisely so the hook's authorisation is spent.
    function test_BurnLeavesNoTransferAllowanceBehind() public {
        BurnProbe probe = new BurnProbe();
        assertEq(probe.burnAndReadAllowance(s), 0);
    }

    /// @notice Anything left here would be proceeds collected and then lost, invisible to a test
    /// that only watches the dead address.
    function test_BurnLeavesNothingInTheRouter() public {
        s.processBurn();
        assertEq(address(burnRouter).balance, 0, "ETH stranded");
        assertEq(s.balanceOf(address(burnRouter)), 0, "tokens stranded");
        assertEq(manager.balanceOf(address(burnRouter), key.currency1.toId()), 0, "claims stranded");
    }

    /// @notice It closes one loop for tokens the factory launched. An arbitrary token would mean an
    /// arbitrary pool key, and a swap into whatever answered to it.
    function test_BurnRefusesATokenTheFactoryNeverLaunched() public {
        vm.expectRevert(SweepBurnRouter.UnknownStrategy.selector);
        burnRouter.buyTokenWithEth{value: 1 ether}(address(0xBEEF), DEAD);
    }

    /// @notice v4 rejects a zero swap three frames down as `SwapAmountCannotBeZero`; ours says so at
    /// the door.
    function test_BurnRefusesZeroValue() public {
        vm.expectRevert(SweepBurnRouter.NothingToSpend.selector);
        burnRouter.buyTokenWithEth(address(s), DEAD);
    }

    /// @notice The callback settles ETH and takes tokens on the strength of its argument. Only the
    /// PoolManager may be the one supplying it.
    function test_UnlockCallbackRefusesEveryoneButThePoolManager() public {
        vm.prank(trader);
        vm.expectRevert(SweepBurnRouter.NotPoolManager.selector);
        burnRouter.unlockCallback(abi.encode(address(s), DEAD, 1 ether));
    }

    /// @notice A router with no PoolManager or no factory could never swap anything.
    function test_ConstructorRefusesZeroDependencies() public {
        vm.expectRevert(SweepBurnRouter.UnknownStrategy.selector);
        new SweepBurnRouter(IPoolManager(address(0)), ISweepFactory(address(factory)));
        vm.expectRevert(SweepBurnRouter.UnknownStrategy.selector);
        new SweepBurnRouter(manager, ISweepFactory(address(0)));
    }

    /// @dev Puts proceeds on the queue the only way they can get there: a trade funds the treasury,
    /// the desk buys a piece below the bid, and someone buys it back at the ask. What lands on
    /// `pendingBurn` is the resale price — 0.6 ETH for a 0.5 ETH purchase at the 1.2x default.
    function _seedPendingBurn() internal returns (uint256 proceeds) {
        _buy(key, 10 ether);
        vm.warp(block.timestamp + 30 minutes);

        uint256 tokenId = collection.mint(address(this));
        collection.setApprovalForAll(address(market), true);
        market.list(address(collection), tokenId, 0.5 ether);
        s.buyTargetNFT(
            0.5 ether, abi.encodeCall(market.fulfill, (address(collection), tokenId)), tokenId, address(market)
        );

        proceeds = s.askPrice(tokenId);
        vm.deal(trader, trader.balance + proceeds);
        vm.prank(trader);
        s.sellTargetNFT{value: proceeds}(tokenId);
        assertEq(s.pendingBurn(), proceeds);
    }
}
