// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SweepHook} from "../src/SweepHook.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {MockSweepFactory} from "./mocks/MockSweepFactory.sol";
import {OwnedCollection} from "./mocks/OwnedCollection.sol";
import {StrategyHarness} from "./mocks/StrategyHarness.sol";
import {SwapProbe} from "./mocks/SwapProbe.sol";

/// @dev A recipient that refuses ETH, standing in for a broken or hostile fee address.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

/**
 * @title HookTest
 * @author 0xDAVZER
 * @notice Everything the toll booth must do, against a real PoolManager deployed in the
 * test rather than a fork, so the whole suite runs in a second and can jump forward in time.
 *
 * @dev The hook is the first contract here that cannot be tested in isolation: its behaviour only
 * exists inside somebody else's swap. So the fixture builds the real thing — PoolManager, a pool,
 * liquidity, and a trader who is deliberately NOT a distributor, so every swap has to pass through
 * the strategy's transfer lock exactly as a stranger's would.
 */
contract HookTest is Test {
    /// @dev `FeeCollected`'s signature, so a test can read the rate the hook charged off the log.
    bytes32 internal constant FEE_COLLECTED_TOPIC = keccak256("FeeCollected(bytes32,address,address,uint256,uint256)");

    /// @dev `0x2444` is beforeInitialize | afterAddLiquidity | afterSwap | afterSwapReturnsDelta.
    /// The high bits are arbitrary; they only push the address clear of the precompiles.
    address internal constant HOOK_ADDRESS = address(uint160(0x4444 << 144 | 0x2444));

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant LP_FEE = 3000;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    MockSweepFactory internal factory;
    StrategyHarness internal strategy;
    SweepHook internal hook;
    OwnedCollection internal collection;

    PoolKey internal key;
    SwapProbe internal probe;

    address internal creator = makeAddr("creator");
    address internal protocol = makeAddr("protocol");
    address internal trader = makeAddr("trader");

    /**
     * @dev Order is forced. The strategy has to know the hook's address before the hook exists, so
     * the address is chosen up front and the code is placed there afterwards — which is exactly
     * what the mined CREATE2 salt does in production, minus the mining.
     *
     * The pool is opened and loaded with the factory's `loadingLiquidity` flag raised, because the
     * hook refuses both operations otherwise. Lowering it again at the end is what makes every
     * later test a test of the world as it will actually be.
     */
    function setUp() public {
        vm.warp(1_700_000_000);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        factory = new MockSweepFactory(address(this));
        factory.setRouter(address(swapRouter), true);
        collection = new OwnedCollection(creator);

        strategy = new StrategyHarness();
        strategy.initialize("Sweep Test", "SWEEP", HOOK_ADDRESS, address(manager), 0.001 ether, 10 ether, address(this));

        deployCodeTo(
            "SweepHook.sol:SweepHook",
            abi.encode(IPoolManager(address(manager)), ISweepFactory(address(factory)), protocol),
            HOOK_ADDRESS
        );
        hook = SweepHook(payable(HOOK_ADDRESS));

        factory.setStrategyCollection(address(strategy), address(collection));

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(strategy)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });

        vm.deal(address(this), 1000 ether);
        strategy.approve(address(lpRouter), type(uint256).max);

        factory.setLoadingLiquidity(true);
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 100 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e19, salt: bytes32(0)}),
            ""
        );
        factory.setLoadingLiquidity(false);

        probe = new SwapProbe(swapRouter);
        strategy.exposed_credit(address(probe), 1_000_000e18);
        probe.approveRouter(address(strategy));
        vm.deal(address(probe), 100 ether);

        strategy.exposed_credit(trader, 1_000_000e18);
        vm.prank(trader);
        strategy.approve(address(swapRouter), type(uint256).max);
        vm.deal(trader, 100 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                         the address IS the config                   */
    /* ------------------------------------------------------------------ */

    /// @notice v4 reads a hook's callbacks from the low 14 bits of its address and never from
    /// storage, so the address and the permission struct must agree or the pool calls the wrong
    /// things. Both sides are asserted here rather than one being trusted.
    function test_HookAddressEncodesExactlyTheFourPermissions() public view {
        assertEq(uint160(address(hook)) & 0x3FFF, 0x2444, "address does not encode 0x2444");

        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize, "beforeInitialize");
        assertTrue(p.afterAddLiquidity, "afterAddLiquidity");
        assertTrue(p.afterSwap, "afterSwap");
        assertTrue(p.afterSwapReturnDelta, "afterSwapReturnDelta");

        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    /// @notice The mistake this makes impossible is shipping a hook to an ordinary address, where
    /// the pool would silently skip every callback and the fee would simply not be charged.
    function test_DeployingAtAWrongAddressReverts() public {
        address wrong = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        new SweepHook(IPoolManager(address(manager)), ISweepFactory(address(factory)), protocol);
    }

    /* ------------------------------------------------------------------ */
    /*                          who may open a pool                        */
    /* ------------------------------------------------------------------ */

    /// @notice The whole system assumes currency0 is ETH: the fee lands on the unspecified side,
    /// the treasury is denominated in ETH, and the burn buys with ETH. A token/token pool would
    /// silently fund the treasury in something it cannot spend.
    function test_InitializeRefusesAPoolThatIsNotEthPaired() public {
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(address(uint160(1))),
            currency1: Currency.wrap(address(strategy)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });

        factory.setLoadingLiquidity(true);
        _expectHookRevert(IHooks.beforeInitialize.selector, SweepHook.NotEthPaired.selector);
        manager.initialize(bad, SQRT_PRICE_1_1);
    }

    /// @notice Without this a stranger could open a second pool naming our hook, and the hook would
    /// happily skim fees into a strategy that never agreed to it — or into an address that is not a
    /// strategy at all, bricking every swap on a pool that looks legitimate.
    function test_InitializeRefusesACallerThatIsNotTheFactory() public {
        PoolKey memory second = key;
        second.fee = 500;

        _expectHookRevert(IHooks.beforeInitialize.selector, SweepHook.NotLaunching.selector);
        manager.initialize(second, SQRT_PRICE_1_1);
    }

    /// @notice One deposit, ever. The launch position is the bonding curve and its ownership NFT
    /// goes to the dead address; a second position would let someone add liquidity they can still
    /// remove, and the curve would stop being a one-way street.
    function test_AddLiquidityRefusesEveryoneButTheFactoryLoading() public {
        _expectHookRevert(IHooks.afterAddLiquidity.selector, SweepHook.NotLaunching.selector);
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );
    }

    /* ------------------------------------------------------------------ */
    /*                              the fee curve                          */
    /* ------------------------------------------------------------------ */

    /// @notice Ten percent on a buy, from the first block of a strategy's life. There is one rate,
    /// it is a constant, and nothing about the clock or the strategy changes it.
    function test_BuyFeeIsTenPercentFromTheFirstBlock() public view {
        assertEq(hook.FEE_BPS(), 1000);
    }

    /// @notice And the same on a sell. The two sides do not differ at all, which is the honest
    /// statement of a flat fee.
    function test_SellFeeIsTenPercentFromTheFirstBlock() public {
        _buy(1 ether);
        vm.recordLogs();
        _sell(10_000e18);
        assertEq(_feeBpsCharged(), 1000, "a sell paid something other than the flat rate");
    }

    /// @notice The rate the hook actually applies is the constant, observed on the swap rather than
    /// read off a getter: the first buy of the pool's life and one ten years later both pay ten
    /// percent. This is the test that would catch a ramp coming back under another name.
    function test_TheFirstBuyPaysTheSameRateAsOneTenYearsLater() public {
        vm.recordLogs();
        _buy(1 ether);
        assertEq(_feeBpsCharged(), 1000, "the first buy paid a launch premium");

        vm.warp(block.timestamp + 3650 days);
        vm.recordLogs();
        _buy(1 ether);
        assertEq(_feeBpsCharged(), 1000, "the rate moved with the clock");
    }

    /* ------------------------------------------------------------------ */
    /*                                 swaps                               */
    /* ------------------------------------------------------------------ */

    /// @notice Every line after this guard assumes `amountSpecified < 0`. Banning exact output is
    /// what lets the hook carry no branches for it, rather than code that can never run.
    function test_ExactOutputSwapReverts() public {
        _expectHookRevert(IHooks.afterSwap.selector, SweepHook.ExactOutputNotAllowed.selector);
        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice The buy path end to end: the fee arrives as tokens, gets sold back to the pool, and
    /// what comes out is ETH the strategy can actually spend on an NFT.
    function test_BuyFundsTheTreasuryInEth() public {
        uint256 before = strategy.treasury();

        _buy(1 ether);

        assertGt(strategy.treasury(), before, "treasury took nothing from the swap");
    }

    /// @notice Eighty percent of every fee reaches the treasury, whichever currency the fee arrived
    /// in. Asserted as a ratio of the total actually collected, because the ETH a token-denominated
    /// fee converts to depends on the pool and cannot be predicted from the swap size.
    function test_BuyRoutesEightyPercentOfTheFeeToTheTreasury() public {
        _nameCreator(creator);

        uint256 treasuryBefore = strategy.treasury();
        _buy(1 ether);

        uint256 toTreasury = strategy.treasury() - treasuryBefore;
        uint256 toCreator = hook.accruedFees(creator);
        uint256 toProtocol = hook.accruedFees(protocol);
        uint256 total = toTreasury + toCreator + toProtocol;

        assertGt(total, 0, "no fee was collected at all");
        assertEq(toTreasury, (total * 80) / 100, "treasury share");
        assertEq(toCreator, (total * 10) / 100, "creator share");
        assertEq(toProtocol, total - toTreasury - toCreator, "protocol share");
    }

    /// @notice Same split on the other side of the book, where the fee is already ETH and no
    /// conversion happens. Pinned separately because the two paths share only their last step.
    function test_SellRoutesEightyPercentOfTheFeeToTheTreasury() public {
        uint256 treasuryBefore = strategy.treasury();
        _sell(100_000e18);

        uint256 toTreasury = strategy.treasury() - treasuryBefore;
        uint256 total = toTreasury + hook.accruedFees(creator) + hook.accruedFees(protocol);

        assertGt(total, 0, "no fee was collected at all");
        assertEq(toTreasury, (total * 80) / 100, "treasury share");
    }

    /// @notice The resting rate, observed as money rather than as a number returned by a view: the
    /// trader keeps nine tenths of what the pool produced and the hook takes the tenth.
    function test_SellTakesOneTenthOfWhatThePoolProduced() public {
        uint256 traderBefore = trader.balance;
        uint256 treasuryBefore = strategy.treasury();

        _sell(100_000e18);

        uint256 traderGain = trader.balance - traderBefore;
        uint256 fee = (strategy.treasury() - treasuryBefore) + hook.accruedFees(creator) + hook.accruedFees(protocol);

        assertEq(fee, (traderGain + fee) / 10, "the fee is not a tenth of the gross");
    }

    /// @notice What a first-block buyer gets is what every later buyer gets: nine tenths of the
    /// pool's output. A flat fee funds the strategy from everyone equally, without a schedule that
    /// only bots read to the minute.
    function test_TheFirstBuyKeepsNineTenthsLikeAnyOther() public {
        uint256 treasuryBefore = strategy.treasury();
        _buy(1 ether);

        uint256 collected =
            (strategy.treasury() - treasuryBefore) + hook.accruedFees(creator) + hook.accruedFees(protocol);

        assertLt(collected, 0.11 ether, "the first buy paid a launch premium");
        assertGt(collected, 0.09 ether, "the first buy paid less than the flat rate");
    }

    /* ------------------------------------------------------------------ */
    /*                  the fee never leaves the manager                   */
    /* ------------------------------------------------------------------ */

    /// @notice The hook nets the fee against the swap's deltas rather than taking it out of the
    /// PoolManager as real tokens, so it never holds a token at all and no movement of its own has
    /// to be authorised against the strategy's transfer lock. Asserted here as a balance, including
    /// the ERC-6909 claim balance, so neither form of custody can hide.
    function test_HookMovesNoTokensOfItsOwn() public {
        _buy(1 ether);
        _sell(100_000e18);

        assertEq(strategy.balanceOf(address(hook)), 0, "hook holds tokens");
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0, "hook holds claims");
    }

    /// @notice The only ETH the hook keeps is what it owes somebody. Anything else sitting here
    /// would be fees that were collected and then lost, which no test measuring only the treasury
    /// would ever notice.
    function test_HookHoldsExactlyWhatItOwes() public {
        _buy(1 ether);
        _sell(100_000e18);

        assertEq(address(hook).balance, hook.accruedFees(creator) + hook.accruedFees(protocol));
    }

    /// @notice The lock is the only thing making the fee uncontournable, so the amount authorised
    /// must be exactly what the swap spends. A surviving allowance is a hole standing open for the
    /// rest of the transaction — and on a buy it is exactly the fee, because the trader receives
    /// the output minus the fee and never the gross.
    ///
    /// @dev Read from inside the swap's own transaction. The allowance is transient storage, which
    /// Foundry clears between test-level calls, so reading it afterwards reads zero against a
    /// correct hook and against a broken one alike. This assertion was vacuous until it was moved.
    function test_BuyAuthorisesExactlyWhatTheTraderReceives() public {
        assertEq(probe.buyAndReadAllowance{value: 1 ether}(key), 0);
    }

    /// @notice Same property on the other side, where the fee is ETH and the whole token leg is the
    /// trader's own settlement into the PoolManager.
    function test_SellAuthorisesExactlyWhatTheTraderSettles() public {
        assertEq(probe.sellAndReadAllowance(key, 100_000e18), 0);
    }

    /* ------------------------------------------------------------------ */
    /*              the creator and protocol are paid by pull              */
    /* ------------------------------------------------------------------ */

    /// @notice Accrual, not transfer. Nothing calls out to a recipient in the middle of a swap, so
    /// no recipient can make a trade revert or spend its gas.
    function test_FeeSplitAccruesTheCreatorAndProtocolShares() public {
        _nameCreator(creator);

        _buy(1 ether);

        assertGt(hook.accruedFees(creator), 0, "creator accrued nothing");
        assertGt(hook.accruedFees(protocol), 0, "protocol accrued nothing");
    }

    /// @notice Paid once. A claim that could be replayed would drain every other recipient's share,
    /// since they all sit in the same ETH balance.
    function test_ClaimFeesPaysTheAccruedBalanceOnce() public {
        _nameCreator(creator);
        _buy(1 ether);

        uint256 owed = hook.accruedFees(creator);
        assertGt(owed, 0);

        uint256 before = creator.balance;
        vm.prank(creator);
        hook.claimFees();
        assertEq(creator.balance, before + owed, "did not pay what was owed");
        assertEq(hook.accruedFees(creator), 0, "balance survived the claim");

        vm.prank(creator);
        vm.expectRevert(SweepHook.NothingAccrued.selector);
        hook.claimFees();
    }

    /// @notice The keeper's entry point: anyone pays the gas, the recipient gets the money. The
    /// caller decides nothing — amount and destination are already in `accruedFees` — which is
    /// exactly what makes it safe to hand to a key with no privileges.
    function test_AnyoneCanClaimFeesForARecipientAndTheRecipientIsPaid() public {
        _nameCreator(creator);
        _buy(1 ether);

        uint256 owed = hook.accruedFees(creator);
        uint256 creatorBefore = creator.balance;
        uint256 traderBefore = trader.balance;

        vm.prank(trader);
        hook.claimFeesFor(creator);

        assertEq(creator.balance, creatorBefore + owed, "the recipient was not paid");
        assertEq(trader.balance, traderBefore, "the caller received something");
        assertEq(hook.accruedFees(creator), 0);
    }

    /// @notice A recipient that rejects ETH fails its own claim and nothing else — the keeper skips
    /// it, and the accrual stays intact for a later pull by hand.
    function test_ClaimForARecipientThatRejectsEthRevertsAndKeepsTheAccrual() public {
        RejectsEth wall = new RejectsEth();
        _nameCreator(address(wall));
        _buy(1 ether);

        uint256 owed = hook.accruedFees(address(wall));
        assertGt(owed, 0);
        vm.expectRevert();
        hook.claimFeesFor(address(wall));
        assertEq(hook.accruedFees(address(wall)), owed, "the accrual was lost");
    }

    /// @notice Registration is the factory's to do and nobody else's: it redirects a tenth of every
    /// trade of a strategy the caller may not own. And it is the only writer there is: no
    /// `claimCreatorFeeRecipient` exists that would let a collection's current `owner()` take a
    /// live revenue stream from the address that paid the launch fee and opened the market. The
    /// call is asserted dead on the deployed hook, because an ABI that carries it is what a front
    /// end would go on believing.
    function test_TheFactoryIsTheOnlyWriterOfTheCreatorRecipient() public {
        vm.prank(trader);
        vm.expectRevert(SweepHook.NotFactory.selector);
        hook.registerCreatorFeeRecipient(address(strategy), trader);

        _nameCreator(creator);

        vm.prank(creator);
        (bool ok,) = address(hook)
            .call(abi.encodeWithSignature("claimCreatorFeeRecipient(address,address)", address(strategy), trader));

        assertFalse(ok, "the removed claim is still callable");
        assertEq(hook.creatorFeeRecipient(address(strategy)), creator, "the recipient moved");
    }

    /// @notice A collection that never claims its share does not strand it. The money keeps moving
    /// to the protocol until somebody turns up to take it, which also means a launch needs no
    /// action from the collection owner to work.
    function test_UnclaimedCreatorShareFallsThroughToTheProtocol() public {
        _buy(1 ether);

        assertEq(hook.accruedFees(creator), 0, "creator was paid without ever claiming");
        assertGt(hook.accruedFees(protocol), 0);
    }

    /// @notice The protocol's own share is the one thing the factory owner controls here, and the
    /// gate is the factory's owner rather than a second owner stored on the hook — one authority,
    /// not two that can disagree.
    function test_OnlyTheFactoryOwnerCanMoveTheProtocolRecipient() public {
        vm.prank(trader);
        vm.expectRevert(SweepHook.NotFactoryOwner.selector);
        hook.setProtocolFeeRecipient(trader);

        hook.setProtocolFeeRecipient(address(0xCAFE));
        assertEq(hook.protocolFeeRecipient(), address(0xCAFE));
    }

    /* ------------------------------------------------------------------ */
    /*                          the remaining edges                        */
    /* ------------------------------------------------------------------ */

    /// @notice A dust trade rounds its fee to nothing, and the early return has to happen after the
    /// settlement is authorised. Returning before it would leave the trader unable to settle a swap
    /// the pool has already executed — a swap that costs nothing bricking one that pays.
    function test_DustSwapTakesNoFeeButStillAuthorisesTheSettlement() public {
        uint256 treasuryBefore = strategy.treasury();

        _sell(1);

        assertEq(strategy.treasury(), treasuryBefore, "a fee was taken on dust");
        assertEq(strategy.transferAllowance(), 0, "the settlement was over-authorised");
    }

    /// @notice The hook's ETH balance is an accounting ledger, so anything arriving outside the
    /// PoolManager would make it wrong. Refusing turns a silent discrepancy into a failed send.
    function test_DirectPaymentIsRefused() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok, bytes memory reason) = address(hook).call{value: 1 ether}("");
        assertFalse(ok, "the hook accepted a donation");
        assertEq(bytes4(reason), SweepHook.DirectPaymentRejected.selector);
    }

    /// @notice Every fee routed to the zero address would be permanently stranded, and the hook has
    /// no way to move an accrual once it is made.
    function test_SetProtocolFeeRecipientRefusesZero() public {
        vm.expectRevert(SweepHook.InvalidRecipient.selector);
        hook.setProtocolFeeRecipient(address(0));
    }

    /// @notice A hook with no factory can never be told a launch is in progress, so no pool could
    /// ever be opened on it; one with no protocol recipient would strand a fifth of every fee. Both
    /// are unrecoverable after deployment, since the factory is immutable and the recipient setter
    /// is gated on a factory that does not exist.
    function test_ConstructorRefusesAZeroFactoryOrRecipient() public {
        assertEq(_deployWith(address(0), protocol), SweepHook.InvalidRecipient.selector);
        assertEq(_deployWith(address(factory), address(0)), SweepHook.InvalidRecipient.selector);
    }

    /* ------------------------------------------------------------------ */
    /*                               helpers                               */
    /* ------------------------------------------------------------------ */

    /// @dev Names where the creator tenth accrues, the only way there is to: through the factory,
    /// once.
    function _nameCreator(address recipient) internal {
        vm.prank(address(factory));
        hook.registerCreatorFeeRecipient(address(strategy), recipient);
    }

    /// @dev The rate the hook applied to the last recorded swap, read off `FeeCollected` rather
    /// than off a getter, so a test observes what was charged and not what was advertised.
    function _feeBpsCharged() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].emitter == address(hook) && logs[i - 1].topics[0] == FEE_COLLECTED_TOPIC) {
                (uint256 feeBps,) = abi.decode(logs[i - 1].data, (uint256, uint256));
                return feeBps;
            }
        }
        revert("no FeeCollected event");
    }

    /// @dev A stranger buying: ETH in, tokens out, and the lock crossed on the way out.
    function _buy(uint256 ethIn) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev A stranger selling: tokens in, ETH out, and the lock crossed on the way in.
    function _sell(uint256 tokensIn) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev v4 wraps whatever a hook reverts with, so a test that expects the bare selector passes
    /// on any revert at all — including the wrong one. This rebuilds the wrapper so the assertion
    /// stays exact.
    function _expectHookRevert(bytes4 callback, bytes4 inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                abi.encodeWithSelector(inner),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Runs the hook's constructor at a valid hook address and returns what it reverted with.
    /// `deployCodeTo` swallows the reason behind its own `require`, which would leave the assertion
    /// unable to tell one constructor guard from the other.
    function _deployWith(address factory_, address recipient_) internal returns (bytes4) {
        address slot = address(uint160(0x5555 << 144 | 0x2444));
        vm.etch(
            slot,
            abi.encodePacked(
                vm.getCode("SweepHook.sol:SweepHook"),
                abi.encode(IPoolManager(address(manager)), ISweepFactory(factory_), recipient_)
            )
        );
        (bool ok, bytes memory reason) = slot.call("");
        assertFalse(ok, "the constructor accepted a zero address");
        return bytes4(reason);
    }

    receive() external payable {}
}
