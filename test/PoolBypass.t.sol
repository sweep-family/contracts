// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SweepHook} from "../src/SweepHook.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepToken} from "../src/SweepToken.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";
import {TargetToken} from "./mocks/TargetToken.sol";

/**
 * @title PoolBypassTest
 * @author 0xDAVZER
 * @notice The attack the fee depends on being impossible: opening a second pool on a strategy's
 * token, one that our hook does not sit on, and trading there for free.
 *
 * @dev This is not hypothetical: a second venue is what a holder reaches for the moment a 10%
 * toll exists, and a token shipped without the lock cannot be fixed. So the property is pinned
 * here, on the real PoolManager rather than a mock, for every kind of strategy: a rival pool can
 * be *created* — v4 lets anyone initialise any pair — and can never be *funded*, which is what
 * makes it harmless.
 *
 * @dev The lock lives in `SweepToken._beforeTokenTransfer` and admits four movements: the mint,
 * a send to the dead address, a whitelisted distributor, and a leg through the PoolManager
 * covered by the transient allowance our hook grants inside a swap on its own pool. Funding a
 * rival pool is none of them: the liquidity router pulls the token straight to the PoolManager,
 * and no swap of ours has authorised a wei of it.
 *
 * @dev **That lock is not the whole story.** v4 also keeps ERC-6909 claim balances, a swapper may
 * take its output as claims instead of ERC-20, and claims move wallet to wallet through the
 * PoolManager without ever touching the token. A test that only ever takes its output as ERC-20
 * cannot fail on that path, so the claim path is exercised here too, and what closes it is a
 * second gate: the hook refuses a swap whose caller is not a router the factory allows, and every
 * allowed router settles in ERC-20. No claim on a strategy's token can come into existence.
 */
contract PoolBypassTest is SweepForkTest {
    /// @dev A pair for the rival pool that is not ours, so the attempt fails on the token's own
    /// rule rather than on anything our hook does.
    TargetToken internal pair;

    function setUp() public override {
        super.setUp();
        pair = new TargetToken();
        pair.mint(trader, 1_000_000e18);
    }

    /// @notice A rival pool opens and then starves: initialising it is permissionless, and the
    /// first attempt to put the strategy's token into it is refused by the token.
    function test_ASecondPoolCannotBeFunded() public {
        (address strategy, PoolKey memory key) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        _buy(key, 1 ether);
        uint256 held = s.balanceOf(trader);
        assertGt(held, 0, "the trader holds nothing to seed with");

        PoolKey memory rival = _rivalKey(strategy);
        manager.initialize(rival, TickMath.getSqrtPriceAtTick(0));

        vm.startPrank(trader);
        s.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert(SweepToken.TransferNotAllowed.selector);
        lpRouter.modifyLiquidity(rival, _singleSided(rival, strategy), "");
        vm.stopPrank();
        assertEq(s.balanceOf(trader), held, "the refusal still moved tokens");
    }

    /// @notice The one hole the lock leaves, written down so it cannot surprise anyone: an address
    /// the owner authorises is exempt, and can fund exactly the pool the test above refuses. The
    /// authorisation is a single owner transaction on any of the three kinds, which is why this
    /// power is the thing to close before mainnet rather than the lock itself.
    function test_AnAuthorisedAddressCanFundASecondPool() public {
        (address strategy, PoolKey memory key) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        _buy(key, 1 ether);

        PoolKey memory rival = _rivalKey(strategy);
        manager.initialize(rival, TickMath.getSqrtPriceAtTick(0));
        s.setDistributor(trader, true);

        uint256 held = s.balanceOf(trader);
        vm.startPrank(trader);
        s.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(rival, _singleSided(rival, strategy), "");
        vm.stopPrank();

        assertLt(s.balanceOf(trader), held, "the authorised address funded nothing");
    }

    /// @notice The same refusal covers every other venue a holder could reach for, since all of
    /// them begin with a plain transfer: a v2 pair, a bridge, a lending market, an exchange's
    /// deposit address, or simply a second wallet. Burning is the one send that is always free.
    function test_TokensCannotLeaveForAnyVenue() public {
        (address strategy, PoolKey memory key) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        _buy(key, 1 ether);

        address[3] memory venues = [address(pair), makeAddr("cexDeposit"), makeAddr("secondWallet")];
        vm.startPrank(trader);
        for (uint256 i = 0; i < venues.length; i++) {
            vm.expectRevert(SweepToken.TransferNotAllowed.selector);
            s.transfer(venues[i], 1e18);
        }

        uint256 deadBefore = s.balanceOf(DEAD_ADDRESS);
        s.transfer(DEAD_ADDRESS, 1e18);
        vm.stopPrank();
        assertEq(s.balanceOf(DEAD_ADDRESS), deadBefore + 1e18, "a holder may always burn");
    }

    /// @notice The reflexive token is the one kind that overrides the transfer hook, to settle its
    /// reward ledger before a balance moves, so it is the one kind that could have lost the lock by
    /// accident. It refuses a rival pool exactly as the desks do.
    function test_ASecondPoolCannotBeFundedForAReflexiveToken() public {
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        vm.prank(trader);
        address strategy = factory.launchRecursive{value: LAUNCH_FEE}("Sweep Reflexive", "sREF");
        SweepRecursiveStrategy s = SweepRecursiveStrategy(payable(strategy));

        _buy(_poolKeyFor(strategy), 1 ether);
        assertGt(s.balanceOf(trader), 0, "the trader holds nothing to seed with");

        PoolKey memory rival = _rivalKey(strategy);
        manager.initialize(rival, TickMath.getSqrtPriceAtTick(0));

        vm.startPrank(trader);
        s.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert(SweepToken.TransferNotAllowed.selector);
        lpRouter.modifyLiquidity(rival, _singleSided(rival, strategy), "");
        vm.stopPrank();
    }

    /// @notice The venue that does work, for contrast: our own pool, where the hook authorises the
    /// exact leg it is about to take a fee on, and the treasury fills.
    function test_TheHookedPoolIsTheOneVenueThatWorks() public {
        (address strategy, PoolKey memory key) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));

        _buy(key, 1 ether);

        assertGt(s.balanceOf(trader), 0, "the trade delivered nothing");
        assertGt(s.treasury(), 0, "the trade paid no fee");
    }

    /* ------------------------------------------------------------------ */
    /*            the claim path, and the gate that closes it              */
    /* ------------------------------------------------------------------ */

    /// @notice The gate itself: the hook refuses a swap whose caller the factory does not know as
    /// a router. This is what makes claims impossible rather than merely unusual — claims can only
    /// be minted from a delta on the PoolManager, a Sweep token can only reach the PoolManager
    /// through a swap on the hooked pool, and every swap on it now comes from a contract we wrote
    /// and that settles in ERC-20. A stranger calling the PoolManager directly, with any settings
    /// at all, does not get that far.
    function test_ASwapFromAnUnapprovedRouterIsRefused() public {
        (address strategy, PoolKey memory key) = _launch();
        PoolSwapTest stranger = new PoolSwapTest(manager);

        vm.deal(trader, trader.balance + 1 ether);
        vm.prank(trader);
        _expectHookRevert(IHooks.afterSwap.selector, SweepHook.RouterNotAllowed.selector);
        stranger.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );

        assertEq(manager.balanceOf(trader, uint256(uint160(strategy))), 0, "a claim was minted");
    }

    /// @notice The claim escape, walked in reverse. Its first step is a buy that takes the output
    /// as ERC-6909 claims, from which a hookless pool is funded and traded on for free, paying us
    /// nothing forever. That first step is the one that reverts, so none of the rest can be
    /// reached: no claim exists to move, to fund with, or to trade.
    function test_TheClaimEscapeNeverStarts() public {
        (address strategy, PoolKey memory key) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));
        vm.warp(block.timestamp + 90 minutes);

        vm.deal(trader, trader.balance + 1 ether);
        vm.prank(trader);
        uint256 out = sweepRouter.buy{value: 1 ether}(strategy, 0, block.timestamp);

        assertGt(out, 0, "the approved router delivered nothing");
        assertEq(s.balanceOf(trader), out, "the output did not arrive as ERC-20");
        assertEq(manager.balanceOf(trader, uint256(uint160(strategy))), 0, "claims exist after a buy");
        assertEq(manager.balanceOf(address(sweepRouter), uint256(uint160(strategy))), 0, "the router holds claims");
        assertGt(s.treasury(), 0, "the buy paid no fee");

        PoolKey memory rival = _rivalKey(strategy);
        manager.initialize(rival, TickMath.getSqrtPriceAtTick(0));

        vm.startPrank(trader);
        manager.setOperator(address(lpRouter), true);
        vm.expectRevert();
        lpRouter.modifyLiquidity(rival, _singleSided(rival, strategy), "", true, true);
        vm.stopPrank();
    }

    /// @notice The residual power, stated rather than hidden: the allow-list is trust, not proof.
    /// The hook asks the factory whether a caller is a router and believes the answer, so an owner
    /// who adds a router that takes its output as claims reopens exactly the claim escape. Both
    /// routers we ship settle in ERC-20 and are the only two the deploy script adds.
    /// This is an owner power of the same weight as `setDistributor`, and it is disclosed with it.
    function test_AnApprovedRouterIsTrustedRatherThanChecked() public {
        (address strategy, PoolKey memory key) = _launch();
        vm.warp(block.timestamp + 90 minutes);
        factory.setRouter(address(swapRouter), true);

        vm.deal(trader, trader.balance + 1 ether);
        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );

        assertGt(
            manager.balanceOf(trader, uint256(uint160(strategy))),
            0,
            "an approved router that takes claims no longer produces them, so this disclosure is stale"
        );
    }

    /// @dev The rival pool: the strategy's token against a token of our own, no hook at all, so
    /// nothing but the token's rule stands between an attacker and a tax-free venue.
    function _rivalKey(address strategy) private view returns (PoolKey memory) {
        (address currency0, address currency1) =
            strategy < address(pair) ? (strategy, address(pair)) : (address(pair), strategy);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /// @dev A range on one side of the opening price, so the position needs only the strategy's
    /// token and the attempt fails on that token rather than on the pair.
    function _singleSided(PoolKey memory rival, address strategy) private pure returns (ModifyLiquidityParams memory) {
        bool strategyIsCurrency1 = Currency.unwrap(rival.currency1) == strategy;
        return ModifyLiquidityParams({
            tickLower: strategyIsCurrency1 ? int24(-6000) : int24(60),
            tickUpper: strategyIsCurrency1 ? int24(-60) : int24(6000),
            liquidityDelta: 1e15,
            salt: bytes32(0)
        });
    }
}
