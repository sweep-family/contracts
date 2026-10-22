// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {CurveTestToken} from "./mocks/CurveTestToken.sol";
import {SweepCurveMath} from "../src/libraries/SweepCurveMath.sol";
import {
    Donor,
    GasEater,
    ICurveLike,
    MockFeeHook,
    ReenteringRecipient,
    RejectingSink
} from "./mocks/CurveTestActors.sol";

/**
 * @title BondingCurveTest
 * @author 0xDAVZER
 * @notice Pins the launch market of decision 0013: pricing over a phantom reserve, the fee and
 * snipe-tax legs, the clamped crossing buy, and a graduation that leaves nothing behind for
 * anyone to rescue.
 *
 * @dev The test contract plays the factory — it is `msg.sender` at initialize, so
 * `completeGraduation` pays out to it, which is why it carries a `receive`. The token is a plain
 * mintable ERC-20: the transfer lock's interaction with the curve is brick 12's property, pinned
 * there against the real `SweepToken`.
 */
contract BondingCurveTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant PHANTOM = 1.68 ether;
    uint256 internal constant THRESHOLD = 4.2 ether;
    uint256 internal constant RESERVED = (SUPPLY * 2) / 7;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant START = 1_788_000_000;

    SweepBondingCurve internal implementation;
    SweepBondingCurve internal curve;
    CurveTestToken internal token;
    MockFeeHook internal feeHook;

    address internal protocolRecipient = makeAddr("protocolRecipient");
    address internal creator = makeAddr("creator");
    address internal launcher = makeAddr("launcher");
    address internal alice = makeAddr("alice");
    address internal whale = makeAddr("whale");

    /// @dev Foundry starts at timestamp 1, which would make every buy in every test a snipe-taxed
    /// buy. Start somewhere real; tests that want the tax warp back inside the window explicitly.
    function setUp() public {
        vm.warp(START);
        feeHook = new MockFeeHook(protocolRecipient);
        implementation = new SweepBondingCurve(PHANTOM, THRESHOLD);
        (curve, token) = _deployCurve(creator);
        vm.deal(alice, 100 ether);
        vm.deal(whale, 100 ether);
    }

    /// @dev Every curve gets its own token: the initializer compares the curve's balance against
    /// `totalSupply()`, so two curves sharing one token would read each other's mints.
    function _deployCurve(address creatorRecipient)
        internal
        returns (SweepBondingCurve deployed, CurveTestToken freshToken)
    {
        freshToken = new CurveTestToken(address(feeHook));
        deployed = SweepBondingCurve(payable(LibClone.deployERC1967(address(implementation))));
        freshToken.mint(address(deployed), SUPPLY);
        deployed.initialize(address(freshToken), creatorRecipient, launcher);
    }

    /// @dev A buy past the snipe window, from a funded wallet, as most tests want one.
    function _buy(address buyer, uint256 value) internal returns (uint256 tokensOut) {
        vm.warp(block.timestamp < START + 5 ? START + 5 : block.timestamp);
        vm.prank(buyer);
        tokensOut = curve.buy{value: value}(0, buyer);
    }

    /* ────────────────────────── initialize ────────────────────────── */

    /// @notice `P/(P+T)` is exactly two sevenths, so the pool's allocation is a round fraction of
    /// the supply and the arithmetic below is checkable by hand.
    function test_InitializeComputesTheReservedAllocationExactly() public view {
        assertEq(curve.reservedTokens(), RESERVED);
        assertEq(curve.sellableTokens(), SUPPLY - RESERVED);
        assertEq(curve.trackedTokens(), SUPPLY);
    }

    /// @notice The factory is whoever called initialize, never a parameter someone could spoof,
    /// and the hook is read off the token rather than trusted from calldata.
    function test_InitializeRecordsTheFactoryAndReadsTheHookOffTheToken() public view {
        assertEq(curve.factory(), address(this));
        assertEq(curve.hook(), address(feeHook));
        assertEq(curve.launchedAt(), START);
    }

    /// @notice A curve initialized without the whole supply would misprice every trade and seed a
    /// wrong pool, so a partial delivery is refused by name.
    function test_InitializeRefusesAPartialSupplyDelivery() public {
        CurveTestToken freshToken = new CurveTestToken(address(feeHook));
        SweepBondingCurve bare = SweepBondingCurve(payable(LibClone.deployERC1967(address(implementation))));
        freshToken.mint(address(bare), SUPPLY - 1);
        freshToken.mint(alice, 1);
        vm.expectRevert(SweepBondingCurve.SupplyNotDelivered.selector);
        bare.initialize(address(freshToken), creator, launcher);
    }

    /// @notice A zero token or launcher is a wiring mistake, refused before anything is read.
    function test_InitializeRefusesZeroAddresses() public {
        SweepBondingCurve bare = SweepBondingCurve(payable(LibClone.deployERC1967(address(implementation))));
        vm.expectRevert(SweepBondingCurve.ZeroAddress.selector);
        bare.initialize(address(0), creator, launcher);
        vm.expectRevert(SweepBondingCurve.ZeroAddress.selector);
        bare.initialize(address(token), creator, address(0));
    }

    /// @notice A supply so small the reserved allocation rounds to nothing has no graduation
    /// price, and is refused rather than launched broken.
    function test_InitializeRefusesASupplyTooSmallToReserve() public {
        CurveTestToken dust = new CurveTestToken(address(feeHook));
        SweepBondingCurve bare = SweepBondingCurve(payable(LibClone.deployERC1967(address(implementation))));
        dust.mint(address(bare), 1);
        vm.expectRevert(SweepBondingCurve.InvalidLaunchEconomics.selector);
        bare.initialize(address(dust), creator, launcher);
    }

    /// @notice One initialize per clone, and none at all on the published implementation, so
    /// nobody can own a contract at an address a deployment record names.
    function test_TheCurveInitializesOnceAndTheImplementationNever() public {
        vm.expectRevert();
        curve.initialize(address(token), creator, launcher);
        vm.expectRevert();
        implementation.initialize(address(token), creator, launcher);
    }

    /* ────────────────────────── pricing ────────────────────────── */

    /// @notice The first buy prices against the phantom reserve alone: `net · S / (P + net)`,
    /// which for a small spend is within a hair of the 1.68e−9 ETH opening price.
    function test_AnEarlyBuyPaysTheOpeningPrice() public {
        uint256 value = 0.001 ether;
        uint256 net = value - (value * 300) / BPS;

        uint256 tokensOut = _buy(alice, value);

        assertEq(tokensOut, (net * SUPPLY) / (PHANTOM + net));
        assertEq(token.balanceOf(alice), tokensOut);
    }

    /// @notice The 3% still comes off the gross spend, and is split like the pool's fee: 80% to
    /// the strategy's treasury in the trade itself, 10% to each bucket (decision 0021). The
    /// treasury's share leaves the tracked quote at once; the buckets stay earmarked inside it
    /// until a sweep. The real reserve, and so the price and the graduation, is unchanged.
    function test_FeesComeOffTheGrossAndSplitEightyTenTen() public {
        _buy(alice, 1 ether);

        assertEq(token.feesReceived(), 0.024 ether, "treasury share");
        assertEq(curve.creatorFeeBalance(), 0.003 ether, "creator share");
        assertEq(curve.protocolFeeBalance(), 0.003 ether, "protocol share");
        assertEq(curve.trackedQuote(), 0.976 ether);
        assertEq(curve.realQuoteReserve(), 0.97 ether);
        assertEq(address(curve).balance, 0.976 ether);
    }

    /// @notice The treasury's share is credited by the curve itself, inside the trade: the desk
    /// can spend it before the transaction that paid it has been followed by any other.
    function test_TheTreasuryShareReachesTheStrategyInTheTrade() public {
        _buy(alice, 0.5 ether);

        assertEq(token.lastFeeSender(), address(curve));
        assertEq(address(token).balance, 0.012 ether);
    }

    /// @notice A strategy that refuses the treasury's share cannot freeze the curve: buys and sells
    /// still trade, the share is owed on the curve instead, priced out of the reserves like the
    /// buckets, and paid by the next sweep once the strategy takes it (audit C-1 of PR #74).
    function test_ARefusingStrategyCannotFreezeTheCurve() public {
        token.setRefuseFees(true);
        uint256 bought = _buy(alice, 1 ether);
        assertEq(curve.treasuryFeeBalance(), 0.024 ether, "the share was not owed");
        assertEq(curve.realQuoteReserve(), 0.97 ether, "the owed share moved the price");

        vm.startPrank(alice);
        token.approve(address(curve), bought / 2);
        curve.sell(bought / 2, 0, alice);
        vm.stopPrank();
        assertGt(curve.treasuryFeeBalance(), 0.024 ether);
        assertEq(token.feesReceived(), 0);

        uint256 owed = curve.treasuryFeeBalance();
        token.setRefuseFees(false);
        curve.sweepFees();
        assertEq(token.feesReceived(), owed, "the sweep did not pay the owed share");
        assertEq(curve.treasuryFeeBalance(), 0);
    }

    /// @notice A sell's fee is split the same way and the treasury is paid from it in the trade;
    /// the seller's payout and the real reserve move exactly as before the split.
    function test_ASellSplitsItsFeesEightyTenTen() public {
        uint256 bought = _buy(alice, 1 ether);
        uint256 treasuryBefore = token.feesReceived();
        (uint256 quoteReserve, uint256 tokenReserve) = curve.getReserves();
        uint256 gross = SweepCurveMath.getAmountOut(bought, tokenReserve, quoteReserve);
        uint256 fees = (gross * 100) / BPS + (gross * 200) / BPS;
        uint256 realBefore = curve.realQuoteReserve();

        vm.startPrank(alice);
        token.approve(address(curve), bought);
        uint256 ethOut = curve.sell(bought, 0, alice);
        vm.stopPrank();

        assertEq(ethOut, gross - (gross * 100) / BPS - (gross * 200) / BPS, "payout");
        assertEq(token.feesReceived() - treasuryBefore, (fees * 80) / 100, "treasury share");
        assertEq(curve.realQuoteReserve(), realBefore - gross, "real reserve");
    }

    /// @notice A sell pays the same two fees out of the quote leg and returns the net.
    function test_ASellTakesItsFeesFromTheQuoteLeg() public {
        uint256 held = _buy(alice, 1 ether);
        (uint256 quoteReserve, uint256 tokenReserve) = curve.getReserves();
        uint256 gross = (held * quoteReserve) / (tokenReserve + held);
        uint256 expected = gross - (gross * 100) / BPS - (gross * 200) / BPS;

        vm.startPrank(alice);
        token.approve(address(curve), held);
        vm.expectRevert(abi.encodeWithSelector(SweepBondingCurve.SlippageExceeded.selector, expected, expected + 1));
        curve.sell(held, expected + 1, alice);
        uint256 ethOut = curve.sell(held, 0, alice);
        vm.stopPrank();

        assertEq(ethOut, expected);
        assertEq(alice.balance, 100 ether - 1 ether + expected);
    }

    /// @notice The economics are fixed per implementation and scale together: a curve at a tenth
    /// of the scale reserves the same 2/7 and graduates at its own threshold, refunding the rest.
    function test_ATenthScaleCurveKeepsEveryRatio() public {
        implementation = new SweepBondingCurve(PHANTOM / 10, THRESHOLD / 10);
        (SweepBondingCurve small,) = _deployCurve(creator);
        assertEq(small.PHANTOM_QUOTE(), PHANTOM / 10);
        assertEq(small.reservedTokens(), RESERVED);

        vm.warp(START + 5);
        uint256 before = whale.balance;
        vm.prank(whale);
        small.buy{value: 1 ether}(0, whale);
        assertTrue(small.graduated());
        assertGe(small.trackedQuote(), THRESHOLD / 10);
        assertLt(before - whale.balance, 0.45 ether, "the crossing buy was not clamped to the smaller threshold");
    }

    /// @notice A zero reserve or threshold is refused at deployment.
    function test_ConstructorRefusesZeroEconomics() public {
        vm.expectRevert(SweepBondingCurve.InvalidLaunchEconomics.selector);
        new SweepBondingCurve(0, THRESHOLD);
        vm.expectRevert(SweepBondingCurve.InvalidLaunchEconomics.selector);
        new SweepBondingCurve(PHANTOM, 0);
    }

    /// @notice A sale cannot name the factory as its recipient. The factory accepts ETH from any
    /// curve it deployed, because that is how graduation reserves arrive, and has no function
    /// that moves ETH out again: a sale paid there would strand the seller's ETH for good and
    /// break "the factory holds no ETH between transactions" (audit 2026-10-02, L-2).
    function test_SellRefusesTheFactoryAsRecipient() public {
        uint256 held = _buy(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(curve), held);
        vm.expectRevert(SweepBondingCurve.InvalidRecipient.selector);
        curve.sell(held, 0, address(this));
        vm.stopPrank();
    }

    /// @notice Nor the token: a desk strategy is the token, and its `receive` takes any ETH with
    /// no ledger that records or returns it, so a sale paid there strands the seller's ETH.
    function test_SellRefusesTheTokenAsRecipient() public {
        uint256 held = _buy(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(curve), held);
        vm.expectRevert(SweepBondingCurve.InvalidRecipient.selector);
        curve.sell(held, 0, address(token));
        vm.stopPrank();
    }

    /// @notice A buy-then-sell round trip never profits: the invariant's rounding and both fee
    /// legs always leave the curve richer than the trader.
    function testFuzz_ABuySellRoundTripNeverProfits(uint256 value) public {
        value = bound(value, 0.0001 ether, 3 ether);
        uint256 tokensOut = _buy(alice, value);

        vm.startPrank(alice);
        token.approve(address(curve), tokensOut);
        uint256 ethOut = curve.sell(tokensOut, 0, alice);
        vm.stopPrank();

        assertLt(ethOut, value);
    }

    /// @notice The view quotes are the trade paths' own arithmetic, so a front end quoting with
    /// them never disagrees with the fill in the same block.
    function test_TheQuotesMatchTheTrades() public {
        vm.warp(START + 5);
        (uint256 quotedTokens,) = curve.quoteBuy(1 ether, alice);
        uint256 bought = _buy(alice, 1 ether);
        assertEq(bought, quotedTokens);

        uint256 quotedEth = curve.quoteSell(bought / 2);
        vm.startPrank(alice);
        token.approve(address(curve), bought / 2);
        uint256 sold = curve.sell(bought / 2, 0, alice);
        vm.stopPrank();
        assertEq(sold, quotedEth);
    }

    /// @notice Zero-value and zero-recipient trades are mistakes, refused by name.
    function test_EmptyTradesAreRefused() public {
        vm.expectRevert(SweepBondingCurve.ZeroAddress.selector);
        curve.buy{value: 1 ether}(0, address(0));

        vm.expectRevert(SweepBondingCurve.ZeroAmount.selector);
        curve.buy(0, alice);

        vm.expectRevert(SweepBondingCurve.ZeroAmount.selector);
        curve.sell(0, 0, alice);

        vm.expectRevert(SweepBondingCurve.ZeroAmount.selector);
        curve.quoteSell(0);

        vm.expectRevert(SweepBondingCurve.ZeroAddress.selector);
        curve.sell(1, 0, address(0));
    }

    /* ────────────────────────── snipe tax ────────────────────────── */

    /// @notice Fourteen halvings across five seconds: 99%, then about
    /// 25% at one second and 3% at two, under half a percent at three, gone at five. At ~101 ms
    /// blocks that is about fifty taxed blocks, and the second that matters to a bot costs a
    /// quarter of the buy rather than the 6% a three-second window charged.
    function test_SnipeTaxDecaysToZeroInsideFiveSeconds() public {
        assertEq(curve.currentSnipeTaxBps(alice), 9900);
        vm.warp(START + 1);
        assertEq(curve.currentSnipeTaxBps(alice), 2475);
        vm.warp(START + 2);
        assertEq(curve.currentSnipeTaxBps(alice), 309);
        vm.warp(START + 3);
        assertEq(curve.currentSnipeTaxBps(alice), 38);
        vm.warp(START + 4);
        assertEq(curve.currentSnipeTaxBps(alice), 4);
        vm.warp(START + 5);
        assertEq(curve.currentSnipeTaxBps(alice), 0);
    }

    /// @notice The tax is clamped so even the second-zero buyer nets one percent of their spend,
    /// and the clamp is what keeps the clamped crossing buy's gross-up from dividing by zero.
    function test_SnipeTaxNetsTheBuyerAtLeastOnePercent() public {
        vm.prank(alice);
        uint256 tokensOut = curve.buy{value: 1 ether}(0, alice);

        uint256 net = 0.01 ether;
        assertEq(tokensOut, (net * SUPPLY) / (PHANTOM + net));
        assertEq(curve.protocolFeeBalance(), 0.003 ether + 0.96 ether, "the snipe tax stays the protocol's");
        assertEq(curve.creatorFeeBalance(), 0.003 ether);
        assertEq(token.feesReceived(), 0.024 ether);
    }

    /// @notice The launcher set the terms, so taxing their own opening buy protects nobody.
    function test_TheLauncherIsExemptFromTheSnipeTax() public {
        assertEq(curve.currentSnipeTaxBps(launcher), 0);

        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        curve.buy{value: 1 ether}(0, launcher);

        assertEq(curve.protocolFeeBalance(), 0.003 ether);
        assertEq(curve.creatorFeeBalance(), 0.003 ether);
    }

    /// @notice The creator recipient is exempt too, and separately from the launcher: on a bag
    /// desk the recipient is the target token's owner, a different wallet from whoever sent the
    /// launch, and both are the launch's own side.
    function test_TheCreatorRecipientIsExemptFromTheSnipeTax() public {
        assertEq(curve.currentSnipeTaxBps(creator), 0);

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        curve.buy{value: 1 ether}(0, creator);

        assertEq(curve.protocolFeeBalance(), 0.003 ether);
    }

    /// @notice A launch with no creator recipient exempts the launcher alone; the zero address
    /// is never a buyer, so it exempts nobody else by accident.
    function test_AZeroCreatorRecipientExemptsOnlyTheLauncher() public {
        (SweepBondingCurve orphan,) = _deployCurve(address(0));
        assertEq(orphan.currentSnipeTaxBps(launcher), 0);
        assertEq(orphan.currentSnipeTaxBps(alice), 9900);
    }

    /// @notice The exemption keys on the recipient, so routing a taxed buy to a stranger through
    /// the launcher's wallet buys no discount.
    function test_TheExemptionFollowsTheRecipientNotTheSender() public {
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        curve.buy{value: 1 ether}(0, alice);

        assertEq(curve.protocolFeeBalance(), 0.963 ether);
    }

    /* ────────────────────── the crossing buy ────────────────────── */

    /// @notice The buy that crosses the line is clamped to what the curve still has, charged only
    /// for that, refunded the rest, and graduates the launch in the same transaction.
    function test_FinalBuyClampsToSellableAndRefundsTheExcess() public {
        vm.warp(START + 5);
        uint256 sellable = curve.sellableTokens();
        uint256 balanceBefore = whale.balance;

        vm.prank(whale);
        uint256 tokensOut = curve.buy{value: 20 ether}(0, whale);

        assertEq(tokensOut, sellable);
        assertEq(curve.trackedTokens(), RESERVED);
        assertTrue(curve.graduated());
        assertLt(balanceBefore - whale.balance, 5 ether);
    }

    /// @notice After the crossing buy the real reserve sits on the threshold to within trade
    /// rounding, which is the ETH the pool will be seeded with. The fees stay owed in their
    /// buckets: graduation only flips the flag, and pays nobody (e2e fork finding, 2026-10-05).
    ///
    /// @dev This replaced `test_TheCrossingBuyGraduatesAndSweepsInOneTransaction`, which pinned
    /// the sweep inside graduation — the very coupling that let a gas-burning fee recipient starve
    /// the crossing buy's auto-graduation. The payout is pinned by
    /// `test_FeesOwedAtGraduationAreSweptToTheirFixedRecipients`.
    function test_TheCrossingBuyGraduatesAndLeavesTheFeesOwed() public {
        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);

        assertTrue(curve.graduated());
        uint256 owed = curve.protocolFeeBalance() + curve.creatorFeeBalance();
        assertGt(curve.protocolFeeBalance(), 0);
        assertGt(curve.creatorFeeBalance(), 0);
        assertApproxEqAbs(curve.realQuoteReserve(), THRESHOLD, 1e3);
        assertEq(curve.trackedQuote(), curve.realQuoteReserve() + owed);
        assertEq(address(curve).balance, curve.trackedQuote());
        assertEq(protocolRecipient.balance, 0);
        assertEq(creator.balance, 0);
    }

    /// @notice Slippage is a bound on the price paid, not the quantity received: a clamped fill
    /// that beats the caller's price passes even though it delivers fewer tokens than asked, and
    /// a fill that would breach the price is refused.
    function test_SlippageIsAPriceBoundOnPartialFills() public {
        _buy(alice, 3 ether);
        (uint256 quoteReserve, uint256 tokenReserve) = curve.getReserves();
        uint256 sellable = curve.sellableTokens();
        uint256 net = (sellable * quoteReserve) / (tokenReserve - sellable) + 1;
        uint256 spent = (net * BPS + 9699) / 9700;
        uint256 generous = (10 ether * sellable) / spent + 2;

        vm.prank(whale);
        vm.expectRevert(abi.encodeWithSelector(SweepBondingCurve.SlippageExceeded.selector, sellable, generous));
        curve.buy{value: 10 ether}(generous, whale);

        vm.prank(whale);
        uint256 tokensOut = curve.buy{value: 10 ether}(sellable + 1, whale);
        assertEq(tokensOut, sellable);
        assertTrue(curve.graduated());
    }

    /// @notice Once graduated, both directions refuse: a buy would sell tokens the pool is owed
    /// and a sell would drain the ETH it is owed.
    function test_TradingIsClosedOnceGraduated() public {
        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);

        vm.expectRevert(SweepBondingCurve.CurveGraduated.selector);
        vm.prank(alice);
        curve.buy{value: 1 ether}(0, alice);

        vm.startPrank(whale);
        token.approve(address(curve), 1e18);
        vm.expectRevert(SweepBondingCurve.CurveGraduated.selector);
        curve.sell(1e18, 0, whale);
        vm.stopPrank();

        vm.expectRevert(SweepBondingCurve.CurveGraduated.selector);
        curve.quoteSell(1e18);
    }

    /// @notice A crossing buy whose graduation fails cannot be allowed to fail: the buy lands,
    /// the flag stays down, both trade directions refuse the ready-but-unflagged window, and
    /// anyone can then settle the launch permissionlessly.
    ///
    /// @dev Graduation used to pay the fee recipients, which made it expensive enough for a
    /// gas-burning creator to starve under the 63/64 rule, and this test walked the gas limit to
    /// find that window. Graduation now only flips the flag, so no gas limit opens the window
    /// any more (`test_NoGasLimitCompletesTheCrossingBuyWithoutGraduating`); the try/catch still
    /// guards the buy against any other failure of the self-call, so the failure is injected
    /// here directly by mocking the self-call to revert, and the rest of the property — the buy
    /// survives, the window is closed, anyone settles — is pinned exactly as before.
    function test_AutoGraduationFailureNeverRevertsTheCrossingBuy() public {
        (SweepBondingCurve starved, CurveTestToken starvedToken) = _deployCurve(address(new GasEater()));
        vm.warp(START + 5);

        vm.mockCallRevert(address(starved), abi.encodeCall(SweepBondingCurve.graduate, ()), "starved");
        vm.expectEmit(false, false, false, false, address(starved));
        emit SweepBondingCurve.AutoGraduationFailed(0);
        vm.prank(whale);
        starved.buy{value: 20 ether}(0, whale);
        vm.clearMockedCalls();

        assertFalse(starved.graduated());
        assertEq(starved.sellableTokens(), 0);
        assertTrue(starved.readyToGraduate());

        vm.expectRevert(SweepBondingCurve.CurveGraduated.selector);
        vm.prank(alice);
        starved.buy{value: 1 ether}(0, alice);

        vm.startPrank(whale);
        starvedToken.approve(address(starved), 1e18);
        vm.expectRevert(SweepBondingCurve.CurveGraduated.selector);
        starved.sell(1e18, 0, whale);
        vm.stopPrank();

        starved.graduate();
        assertTrue(starved.graduated());
    }

    /// @notice A creator recipient that burns every drop of gas it is paid with cannot make the
    /// crossing buy leave its graduation failed at the gas limit a wallet actually sends.
    ///
    /// @dev The e2e mainnet-fork finding of 2026-10-05: with such a creator, the crossing buy
    /// sent at the wallet's estimate (257,603) or the web's estimate + 25% (322,004) landed but
    /// emitted `AutoGraduationFailed`, because graduation paid the fee recipients by force and
    /// the force-send burnt its whole 100k stipend inside the 63/64 share the self-call gets. The
    /// call gas here is those transaction limits less the 21,000 intrinsic and a 1,000 allowance
    /// for the buy's calldata, which is what reaches the curve.
    ///
    /// @dev Since decision 0021 the buy also sends the treasury its share, so a wallet's estimate
    /// for the same buy is higher by that send; both limits move up by its cost, measured here as
    /// a first-ever send to a fresh token, which bounds what it costs inside the buy.
    function test_AGasBurningCreatorCannotStarveTheCrossingBuysGraduation() public {
        uint256 push = _treasuryPushGas();
        uint256[2] memory txGasLimits = [uint256(257_603) + push, uint256(322_004) + push];
        for (uint256 i = 0; i < txGasLimits.length; ++i) {
            (SweepBondingCurve hostile,) = _deployCurve(address(new GasEater()));
            vm.warp(block.timestamp + 5);

            vm.recordLogs();
            vm.prank(whale);
            hostile.buy{value: 20 ether, gas: txGasLimits[i] - 21_000 - 1000}(0, whale);

            assertTrue(hostile.graduated(), "the crossing buy left graduation failed");
            assertFalse(_emittedAutoGraduationFailed(address(hostile)), "AutoGraduationFailed was emitted");
        }
    }

    /// @notice There is no gas limit at all that completes the crossing buy and leaves the
    /// launch ungraduated, whoever the fee recipients are: graduation pays nobody, so the 63/64
    /// share the self-call gets always covers it whenever the remaining sixty-fourth could have
    /// carried the catch and the rest of the buy.
    ///
    /// @dev Both recipients burn their stipend — the protocol's through the hook's live
    /// recipient — so this is the most expensive payout the old graduation could have faced. The
    /// walk runs from below the cheapest successful buy to well past the old window, in steps of
    /// a thousand gas.
    function test_NoGasLimitCompletesTheCrossingBuyWithoutGraduating() public {
        feeHook.setProtocolFeeRecipient(address(new GasEater()));
        (SweepBondingCurve hostile,) = _deployCurve(address(new GasEater()));
        vm.warp(START + 5);

        uint256 landed;
        for (uint256 gas = 60_000; gas <= 600_000; gas += 1000) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(whale);
            try hostile.buy{value: 20 ether, gas: gas}(0, whale) {
                ++landed;
                assertTrue(hostile.graduated(), "a crossing buy landed without graduating");
            } catch {}
            vm.revertToState(snapshot);
        }
        assertGt(landed, 0, "no gas limit completed the crossing buy");
    }

    /// @dev The gas a curve's send of the treasury's share costs at most: a first-ever `addFees`
    /// with value to a fresh token, cold account and cold slots included.
    function _treasuryPushGas() internal returns (uint256) {
        CurveTestToken fresh = new CurveTestToken(address(feeHook));
        vm.deal(address(this), 1);
        uint256 before = gasleft();
        fresh.addFees{value: 1}();
        return before - gasleft();
    }

    /// @dev True when `emitter` logged `AutoGraduationFailed` since the last `vm.recordLogs`.
    function _emittedAutoGraduationFailed(address emitter) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == SweepBondingCurve.AutoGraduationFailed.selector) {
                return true;
            }
        }
        return false;
    }

    /* ────────────────────────── donations ────────────────────────── */

    /// @notice Reserves are counters, not balances: forced ETH and donated tokens sit outside the
    /// books, move no price, bring graduation no closer, and are stranded rather than pooled.
    ///
    /// @dev The factory receives the real reserve; the owed fees stay until swept, after which
    /// the donation is all the curve holds.
    function test_DonationsNeverMoveThePriceAndNeverReachThePool() public {
        uint256 held = _buy(alice, 1 ether);
        (uint256 quoteBefore, uint256 tokensBefore) = curve.getReserves();
        (uint256 quotedBefore,) = curve.quoteBuy(1 ether, alice);

        new Donor{value: 5 ether}(payable(address(curve)));
        vm.prank(alice);
        token.transfer(address(curve), held / 2);

        (uint256 quoteAfter, uint256 tokensAfter) = curve.getReserves();
        (uint256 quotedAfter,) = curve.quoteBuy(1 ether, alice);
        assertEq(quoteAfter, quoteBefore);
        assertEq(tokensAfter, tokensBefore);
        assertEq(quotedAfter, quotedBefore);

        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);
        uint256 realQuote = curve.realQuoteReserve();
        uint256 trackedTokens = curve.trackedTokens();
        uint256 ethBefore = address(this).balance;

        (uint256 ethOut, uint256 tokenOut) = curve.completeGraduation();

        assertEq(ethOut, realQuote);
        assertEq(tokenOut, trackedTokens);
        assertEq(address(this).balance, ethBefore + ethOut);
        curve.sweepFees();
        assertEq(address(curve).balance, 5 ether);
        assertEq(token.balanceOf(address(curve)), held / 2);
    }

    /// @notice Plain ETH transfers are refused so the books stay the only way money enters.
    function test_PlainEthSendsAreRefused() public {
        (bool ok,) = address(curve).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /* ────────────────────────── fees ────────────────────────── */

    /// @notice Anyone may sweep; the protocol's share follows the hook's live recipient and the
    /// creator's goes where the launch pointed it, so the keeper is a convenience, never a
    /// dependency.
    function test_AnyoneMaySweepAndBothBucketsArePaid() public {
        _buy(alice, 1 ether);

        vm.prank(makeAddr("stranger"));
        curve.sweepFees();

        assertEq(protocolRecipient.balance, 0.003 ether);
        assertEq(creator.balance, 0.003 ether);
        assertEq(curve.protocolFeeBalance(), 0);
        assertEq(curve.creatorFeeBalance(), 0);
        assertEq(curve.trackedQuote(), 0.97 ether);
    }

    /// @notice Sweeping empty buckets reverts, so a keeper mis-schedule reads as a revert rather
    /// than a silent success.
    function test_SweepingEmptyBucketsIsRefused() public {
        vm.expectRevert(SweepBondingCurve.NothingToSweep.selector);
        curve.sweepFees();
    }

    /// @notice A zero creator recipient folds the creator's share into the protocol's, mirroring
    /// the hook's own `_distribute`.
    function test_AZeroCreatorRecipientFoldsIntoTheProtocol() public {
        (SweepBondingCurve orphan,) = _deployCurve(address(0));
        vm.warp(START + 5);
        vm.prank(alice);
        orphan.buy{value: 1 ether}(0, alice);

        orphan.sweepFees();

        assertEq(protocolRecipient.balance, 0.006 ether, "both 10% shares, the treasury's 80% aside");
    }

    /// @notice A recipient that reverts on receive cannot hold graduation hostage, and is still
    /// paid by force when the buckets are swept.
    ///
    /// @dev Graduation no longer pays anyone, so the sink cannot even be reached from it; the
    /// force payment it used to be pinned by moved to `sweepFees`, and is pinned there.
    function test_ARevertingCreatorRecipientCannotBlockGraduation() public {
        RejectingSink sink = new RejectingSink();
        (SweepBondingCurve guarded,) = _deployCurve(address(sink));
        vm.warp(START + 5);

        vm.prank(whale);
        guarded.buy{value: 10 ether}(0, whale);
        assertTrue(guarded.graduated());

        uint256 owed = guarded.creatorFeeBalance();
        assertGt(owed, 0);
        guarded.sweepFees();
        assertEq(address(sink).balance, owed);
        assertEq(guarded.creatorFeeBalance(), 0);
    }

    /// @notice Fees owed when the launch graduates still reach their fixed recipients, exactly,
    /// through the permissionless sweep — on a graduated curve, after the factory has taken the
    /// reserves, and with nothing left behind.
    function test_FeesOwedAtGraduationAreSweptToTheirFixedRecipients() public {
        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);
        uint256 protocolOwed = curve.protocolFeeBalance();
        uint256 creatorOwed = curve.creatorFeeBalance();

        curve.completeGraduation();
        vm.prank(makeAddr("stranger"));
        curve.sweepFees();

        assertEq(protocolRecipient.balance, protocolOwed);
        assertEq(creator.balance, creatorOwed);
        assertEq(curve.protocolFeeBalance(), 0);
        assertEq(curve.creatorFeeBalance(), 0);
        assertEq(curve.trackedQuote(), 0);
        assertEq(address(curve).balance, 0, "ETH stranded on the curve");
    }

    /// @notice A creator that burns all the gas it is paid with is still paid, by force, in
    /// full, and cannot keep the protocol's share from being paid alongside it.
    function test_AGasBurningCreatorIsPaidByForceWhenTheFeesAreSwept() public {
        GasEater eater = new GasEater();
        (SweepBondingCurve hostile,) = _deployCurve(address(eater));
        vm.warp(START + 5);
        vm.prank(whale);
        hostile.buy{value: 20 ether}(0, whale);
        uint256 protocolOwed = hostile.protocolFeeBalance();
        uint256 creatorOwed = hostile.creatorFeeBalance();

        hostile.sweepFees();

        assertEq(address(eater).balance, creatorOwed);
        assertEq(protocolRecipient.balance, protocolOwed);
        assertEq(hostile.protocolFeeBalance() + hostile.creatorFeeBalance(), 0);
    }

    /// @notice The factory receives exactly the real reserve — the same 4.2 ETH whether the fees
    /// were swept before the handover or are still owed — and the curve keeps exactly the owed
    /// fees, so the books still match the balance wei for wei on both sides of the handover.
    function test_CompleteGraduationHandsOverTheRealReserveAndKeepsTheOwedFees() public {
        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);
        uint256 owed = curve.protocolFeeBalance() + curve.creatorFeeBalance();
        uint256 realReserve = curve.realQuoteReserve();

        uint256 snapshot = vm.snapshotState();
        curve.sweepFees();
        (uint256 ethOutAfterSweep,) = curve.completeGraduation();
        vm.revertToState(snapshot);

        uint256 factoryBefore = address(this).balance;
        (uint256 ethOut, uint256 tokenOut) = curve.completeGraduation();

        assertEq(ethOut, realReserve);
        assertEq(ethOut, ethOutAfterSweep, "the seed depends on when the fees were swept");
        assertApproxEqAbs(ethOut, THRESHOLD, 1e3);
        assertEq(tokenOut, RESERVED);
        assertEq(address(this).balance, factoryBefore + ethOut);
        assertEq(curve.trackedQuote(), owed);
        assertEq(address(curve).balance, owed);
        assertEq(curve.realQuoteReserve(), 0);
        (uint256 quoteReserve, uint256 tokenReserve) = curve.getReserves();
        assertEq(quoteReserve, PHANTOM);
        assertEq(tokenReserve, 0);
    }

    /* ────────────────────────── graduation ────────────────────────── */

    /// @notice Graduation hands control to nobody: a fee recipient armed to re-enter is never
    /// called by `graduate`, whoever calls it, so there is no instant at which it could trade
    /// against a half-graduated curve.
    ///
    /// @dev This replaced `test_GraduatedIsSetBeforeFeesLeave`. That ordering defended the sweep
    /// graduation used to run, whose ETH sends could hand control to a recipient while only the
    /// flag closed the market. Graduation no longer sweeps, so the property it protected is now
    /// stronger — no external call at all — and the re-entry it modelled moved to `sweepFees`,
    /// pinned by `test_ARecipientReenteringTheSweepOfAGraduatedCurveMeetsAClosedMarket`. The
    /// ready-but-unflagged state a direct `graduate` needs is built by injecting the self-call
    /// failure, since no gas limit produces it any more.
    function test_GraduateHandsControlToNobody() public {
        ReenteringRecipient reenter = new ReenteringRecipient();
        (SweepBondingCurve hot,) = _deployCurve(address(reenter));
        vm.deal(address(reenter), 1 ether);
        vm.warp(START + 5);

        vm.mockCallRevert(address(hot), abi.encodeCall(SweepBondingCurve.graduate, ()), "starved");
        vm.prank(whale);
        hot.buy{value: 20 ether}(0, whale);
        vm.clearMockedCalls();
        assertTrue(hot.readyToGraduate());

        reenter.arm(ICurveLike(address(hot)));
        hot.graduate();

        assertTrue(hot.graduated());
        assertFalse(reenter.attempted(), "graduate handed control to a fee recipient");
        assertGt(hot.creatorFeeBalance(), 0);
    }

    /// @notice A creator recipient re-entering from inside the sweep of a graduated curve meets a
    /// closed market: its buy is refused and the books it could have refilled stay zeroed.
    function test_ARecipientReenteringTheSweepOfAGraduatedCurveMeetsAClosedMarket() public {
        ReenteringRecipient reenter = new ReenteringRecipient();
        (SweepBondingCurve hot,) = _deployCurve(address(reenter));
        vm.deal(address(reenter), 1 ether);
        vm.warp(START + 5);
        vm.prank(whale);
        hot.buy{value: 20 ether}(0, whale);
        uint256 trackedTokens = hot.trackedTokens();

        reenter.arm(ICurveLike(address(hot)));
        hot.sweepFees();

        assertTrue(reenter.attempted());
        assertTrue(reenter.observedGraduated());
        assertGt(reenter.buyRevertReason().length, 0, "the re-entering buy was not refused");
        assertEq(hot.protocolFeeBalance() + hot.creatorFeeBalance(), 0);
        assertEq(hot.trackedTokens(), trackedTokens);
        assertEq(address(hot).balance, hot.trackedQuote());
    }

    /// @notice A gas-burning creator cannot block a direct `graduate` either: it costs the same
    /// one storage write whoever the recipients are, well inside 50,000 gas, where paying the
    /// creator by force used to need more than its whole 100,000-gas stipend.
    function test_AGasBurningCreatorCannotBlockGraduate() public {
        (SweepBondingCurve hostile,) = _deployCurve(address(new GasEater()));
        vm.warp(START + 5);
        vm.mockCallRevert(address(hostile), abi.encodeCall(SweepBondingCurve.graduate, ()), "starved");
        vm.prank(whale);
        hostile.buy{value: 20 ether}(0, whale);
        vm.clearMockedCalls();

        hostile.graduate{gas: 50_000}();

        assertTrue(hostile.graduated());
    }

    /// @notice Graduating twice, or before the curve is full, is refused by name.
    function test_GraduateRefusesTheWrongMoment() public {
        vm.expectRevert(SweepBondingCurve.NotReadyToGraduate.selector);
        curve.graduate();

        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);

        vm.expectRevert(SweepBondingCurve.AlreadyGraduated.selector);
        curve.graduate();
    }

    /// @notice Only the factory may take the reserves, only after the flag, and the handover
    /// zeroes the books and tells the token — which is what resets the desk's bid ramp.
    ///
    /// @dev Since graduation stopped sweeping (2026-10-05), the handover leaves `trackedQuote`
    /// holding exactly the fees still owed, and the books reach zero once they are swept.
    function test_CompleteGraduationIsOnlyForTheFactoryAndOnlyAfterTheFlag() public {
        vm.expectRevert(SweepBondingCurve.NotGraduated.selector);
        curve.completeGraduation();

        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(SweepBondingCurve.OnlyFactory.selector);
        curve.completeGraduation();

        (uint256 ethOut, uint256 tokenOut) = curve.completeGraduation();

        assertApproxEqAbs(ethOut, THRESHOLD, 1e3);
        assertEq(tokenOut, RESERVED);
        assertEq(curve.trackedQuote(), curve.protocolFeeBalance() + curve.creatorFeeBalance());
        assertEq(curve.trackedTokens(), 0);
        assertEq(token.balanceOf(address(this)), RESERVED);
        assertEq(token.markGraduatedCalls(), 1);
        curve.sweepFees();
        assertEq(curve.trackedQuote(), 0);
        assertEq(token.lastGraduationCaller(), address(curve));

        vm.expectRevert(SweepBondingCurve.NothingToComplete.selector);
        curve.completeGraduation();
    }

    receive() external payable {}
}
