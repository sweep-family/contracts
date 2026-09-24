// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";

/// @dev Sells and then reads the allowance from inside the same transaction. See `SwapProbe`.
contract SellProbe {
    function sellAndReadAllowance(SweepSwapRouter router, SweepNFTStrategy s, uint256 amount)
        external
        returns (uint256)
    {
        s.approve(address(router), amount);
        router.sell(address(s), amount, 0, block.timestamp);
        return s.transferAllowance();
    }

    receive() external payable {}
}

/**
 * @title SwapRouterTest
 * @author 0xDAVZER
 * @notice The wallet's road onto the pool, against the real PoolManager.
 */
contract SwapRouterTest is SweepForkTest {
    bytes32 internal constant TRADE_TOPIC = keccak256("Trade(address,address,uint160,int128,int128)");

    SweepSwapRouter internal router;
    SweepNFTStrategy internal s;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        router = new SweepSwapRouter(manager, ISweepFactory(address(factory)));
        factory.setRouter(address(router), true);
        (address strategy, PoolKey memory k) = _launch();
        s = SweepNFTStrategy(payable(strategy));
        key = k;
        vm.warp(block.timestamp + 90 minutes);
    }

    /// @notice A buy delivers tokens to the wallet, net of the fee, and funds the treasury.
    function test_BuyDeliversTokensToTheWallet() public {
        uint256 treasuryBefore = s.treasury();
        vm.prank(trader);
        uint256 out = router.buy{value: 1 ether}(address(s), 0, block.timestamp);

        assertGt(out, 0);
        assertEq(s.balanceOf(trader), out, "delivered something other than it reported");
        assertGt(s.treasury(), treasuryBefore, "the buy paid no fee");
        assertEq(s.balanceOf(address(router)), 0, "the router kept tokens");
        assertEq(address(router).balance, 0, "the router kept ETH");
    }

    /// @notice A sell pulls the tokens from the wallet on an ordinary approval and delivers ETH.
    function test_SellDeliversEthToTheWallet() public {
        vm.prank(trader);
        uint256 bought = router.buy{value: 1 ether}(address(s), 0, block.timestamp);

        uint256 ethBefore = trader.balance;
        vm.startPrank(trader);
        s.approve(address(router), bought);
        uint256 out = router.sell(address(s), bought, 0, block.timestamp);
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(trader.balance, ethBefore + out, "delivered something other than it reported");
        assertEq(s.balanceOf(trader), 0, "tokens were not all pulled");
        assertEq(s.balanceOf(address(router)), 0, "the router kept tokens");
    }

    /// @notice The hook records the wallet, not the router, because the router names it.
    function test_TradeIsAttributedToTheWalletNotTheRouter() public {
        vm.recordLogs();
        vm.prank(trader);
        router.buy{value: 0.1 ether}(address(s), 0, block.timestamp);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == TRADE_TOPIC) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(s));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), trader, "trade attributed to the wrong address");
                found = true;
            }
        }
        assertTrue(found, "no Trade event");
    }

    /// @notice The hook's invariant on the sell side: the tokens go wallet to PoolManager, exactly
    /// what the hook authorised, and nothing stands open afterwards.
    function test_SellLeavesNoTransferAllowanceBehind() public {
        SellProbe probe = new SellProbe();
        vm.deal(address(probe), 1 ether);
        vm.prank(address(probe));
        uint256 bought = router.buy{value: 0.5 ether}(address(s), 0, block.timestamp);
        assertEq(probe.sellAndReadAllowance(router, s, bought), 0);
    }

    /// @notice The slippage bound is checked against what actually happened.
    function test_BuyRefusesToDeliverLessThanTheMinimum() public {
        vm.prank(trader);
        uint256 quote = router.buy{value: 0.1 ether}(address(s), 0, block.timestamp);
        vm.prank(trader);
        vm.expectRevert();
        router.buy{value: 0.1 ether}(address(s), quote * 2, block.timestamp);
    }

    /// @notice A transaction that sat in the mempool past its deadline does not execute late.
    function test_ExpiredDeadlineReverts() public {
        vm.prank(trader);
        vm.expectRevert(SweepSwapRouter.Expired.selector);
        router.buy{value: 0.1 ether}(address(s), 0, block.timestamp - 1);
    }

    /// @notice Not a general-purpose router.
    function test_RefusesATokenTheFactoryNeverLaunched() public {
        vm.prank(trader);
        vm.expectRevert(SweepSwapRouter.UnknownStrategy.selector);
        router.buy{value: 0.1 ether}(address(0xBEEF), 0, block.timestamp);
    }

    /// @notice Only the PoolManager may drive the settlement.
    function test_UnlockCallbackRefusesEveryoneButThePoolManager() public {
        vm.prank(trader);
        vm.expectRevert(SweepSwapRouter.NotPoolManager.selector);
        router.unlockCallback(abi.encode(address(s), trader, true, 1 ether));
    }

    /// @notice The sell side carries the same three guards as the buy side.
    function test_SellGuardsMirrorTheBuySide() public {
        vm.prank(trader);
        uint256 bought = router.buy{value: 0.1 ether}(address(s), 0, block.timestamp);

        vm.startPrank(trader);
        s.approve(address(router), bought);
        vm.expectRevert(SweepSwapRouter.Expired.selector);
        router.sell(address(s), bought, 0, block.timestamp - 1);
        vm.expectRevert(SweepSwapRouter.UnknownStrategy.selector);
        router.sell(address(0xBEEF), bought, 0, block.timestamp);
        vm.expectRevert();
        router.sell(address(s), bought, 1 ether, block.timestamp);
        vm.stopPrank();
    }

    /// @notice A router with no PoolManager or no factory could never swap anything.
    function test_ConstructorRefusesZeroDependencies() public {
        vm.expectRevert(SweepSwapRouter.UnknownStrategy.selector);
        new SweepSwapRouter(IPoolManager(address(0)), ISweepFactory(address(factory)));
        vm.expectRevert(SweepSwapRouter.UnknownStrategy.selector);
        new SweepSwapRouter(manager, ISweepFactory(address(0)));
    }

    /// @notice A quote is what the swap then delivers, to the wei, in both directions — the same
    /// code path through the same hook, unwound instead of settled.
    function test_QuoteMatchesTheSwapExactly() public {
        uint256 quoted = router.quote(address(s), true, 0.3 ether);
        vm.prank(trader);
        uint256 bought = router.buy{value: 0.3 ether}(address(s), 0, block.timestamp);
        assertEq(bought, quoted, "buy quote");

        uint256 quotedSell = router.quote(address(s), false, bought);
        vm.startPrank(trader);
        s.approve(address(router), bought);
        uint256 sold = router.sell(address(s), bought, 0, block.timestamp);
        vm.stopPrank();
        assertEq(sold, quotedSell, "sell quote");
    }

    /// @notice A quote settles nothing and leaves nothing behind.
    function test_QuoteHasNoSideEffects() public {
        uint256 treasury = s.treasury();
        uint256 balance = address(router).balance;
        router.quote(address(s), true, 1 ether);
        assertEq(s.treasury(), treasury);
        assertEq(address(router).balance, balance);
        assertEq(s.balanceOf(address(router)), 0);
    }

    /// @notice A quote for nothing, or for a token that is not ours, says so.
    function test_QuoteGuards() public {
        vm.expectRevert(SweepSwapRouter.NothingToSwap.selector);
        router.quote(address(s), true, 0);
        vm.expectRevert(SweepSwapRouter.UnknownStrategy.selector);
        router.quote(address(0xBEEF), true, 1);
    }

    /// @notice A simulation that fails for any reason other than carrying its result back is
    /// wrapped in `QuoteFailed`, so a front end can tell "no quote" from "the quote is zero".
    /// An amount past the int128 a v4 delta is carried in is the simplest way to make one fail.
    function test_QuoteFailureIsWrapped() public {
        uint256 tooMuch = uint256(uint128(type(int128).max)) + 1;
        try router.quote(address(s), true, tooMuch) returns (uint256) {
            revert("a quote of an impossible size must not succeed");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), SweepSwapRouter.QuoteFailed.selector, "the failure was not wrapped");
        }
    }

    /// @notice Zero is refused at the door in both directions.
    function test_ZeroAmountsAreRefused() public {
        vm.startPrank(trader);
        vm.expectRevert(SweepSwapRouter.NothingToSwap.selector);
        router.buy(address(s), 0, block.timestamp);
        vm.expectRevert(SweepSwapRouter.NothingToSwap.selector);
        router.sell(address(s), 0, 0, block.timestamp);
        vm.stopPrank();
    }
}
