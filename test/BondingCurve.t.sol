// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {CurveTestToken} from "./mocks/CurveTestToken.sol";
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
 * @notice Pins the launch market: pricing over a phantom reserve, the fee and
 * snipe-tax legs, the clamped crossing buy, and a graduation that leaves nothing behind for
 * anyone to rescue.
 *
 * @dev The test contract plays the factory — it is `msg.sender` at initialize, so
 * `completeGraduation` pays out to it, which is why it carries a `receive`. The token is a plain
 * mintable ERC-20: the transfer lock's interaction with the curve is the token's property, pinned
 * in `StrategyBase.t.sol` against the real `SweepToken`.
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
        implementation = new SweepBondingCurve();
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

    /// @notice Fees come off the gross spend and land in their buckets; the whole spend, fees
    /// included, joins the tracked quote until a sweep pays the buckets out.
    function test_FeesComeOffTheGrossAndAccrueToTheBuckets() public {
        _buy(alice, 1 ether);

        assertEq(curve.protocolFeeBalance(), 0.01 ether);
        assertEq(curve.creatorFeeBalance(), 0.02 ether);
        assertEq(curve.trackedQuote(), 1 ether);
        assertEq(curve.realQuoteReserve(), 0.97 ether);
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

    /// @notice A sale cannot name the factory as its recipient. The factory accepts ETH from any
    /// curve it deployed, because that is how graduation reserves arrive, and has no function
    /// that moves ETH out again: a sale paid there would strand the seller's ETH for good and
    /// break "the factory holds no ETH between transactions".
    function test_SellRefusesTheFactoryAsRecipient() public {
        uint256 held = _buy(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(curve), held);
        vm.expectRevert(SweepBondingCurve.InvalidRecipient.selector);
        curve.sell(held, 0, address(this));
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
        assertEq(curve.protocolFeeBalance(), 0.01 ether + 0.96 ether);
        assertEq(curve.creatorFeeBalance(), 0.02 ether);
    }

    /// @notice The launcher set the terms, so taxing their own opening buy protects nobody.
    function test_TheLauncherIsExemptFromTheSnipeTax() public {
        assertEq(curve.currentSnipeTaxBps(launcher), 0);

        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        curve.buy{value: 1 ether}(0, launcher);

        assertEq(curve.protocolFeeBalance(), 0.01 ether);
        assertEq(curve.creatorFeeBalance(), 0.02 ether);
    }

    /// @notice The creator recipient is exempt too, and separately from the launcher: on a bag
    /// desk the recipient is the target token's owner, a different wallet from whoever sent the
    /// launch, and both are the launch's own side.
    function test_TheCreatorRecipientIsExemptFromTheSnipeTax() public {
        assertEq(curve.currentSnipeTaxBps(creator), 0);

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        curve.buy{value: 1 ether}(0, creator);

        assertEq(curve.protocolFeeBalance(), 0.01 ether);
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

        assertEq(curve.protocolFeeBalance(), 0.97 ether);
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
    /// rounding, which is the ETH the pool will be seeded with.
    function test_TheCrossingBuyGraduatesAndSweepsInOneTransaction() public {
        _buy(alice, 1 ether);
        vm.prank(whale);
        curve.buy{value: 10 ether}(0, whale);

        assertTrue(curve.graduated());
        assertEq(curve.protocolFeeBalance(), 0);
        assertEq(curve.creatorFeeBalance(), 0);
        assertApproxEqAbs(curve.trackedQuote(), THRESHOLD, 1e3);
        assertGt(protocolRecipient.balance, 0);
        assertGt(creator.balance, 0);
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

    /// @notice A crossing buy starved of gas by its caller cannot be allowed to fail: the buy
    /// lands, the flag stays down, both trade directions refuse the ready-but-unflagged window,
    /// and anyone can then settle the launch permissionlessly.
    ///
    /// @dev With plain recipients graduation is so cheap the 63/64 rule protects it — by the
    /// time a sixty-fourth of the gas can carry the catch, sixty-three can carry the sweep. The
    /// starvation the try/catch exists for needs an adversarial recipient, so the creator here
    /// burns its entire force-send stipend, and the loop walks the gas limit until it finds the
    /// window that completes the buy but not the graduation.
    function test_AutoGraduationFailureNeverRevertsTheCrossingBuy() public {
        (SweepBondingCurve starved, CurveTestToken starvedToken) = _deployCurve(address(new GasEater()));
        vm.warp(START + 5);

        bool found;
        for (uint256 gas = 200_000; gas <= 3_000_000; gas += 10_000) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(whale);
            try starved.buy{value: 20 ether, gas: gas}(0, whale) {
                if (!starved.graduated()) {
                    found = true;
                    break;
                }
                vm.revertToState(snapshot);
                break;
            } catch {
                vm.revertToState(snapshot);
            }
        }

        assertTrue(found, "no gas limit starved graduation while completing the buy");
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

        starved.sweepFees();
        starved.graduate();
        assertTrue(starved.graduated());
    }

    /* ────────────────────────── donations ────────────────────────── */

    /// @notice Reserves are counters, not balances: forced ETH and donated tokens sit outside the
    /// books, move no price, bring graduation no closer, and are stranded rather than pooled.
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
        uint256 trackedQuote = curve.trackedQuote();
        uint256 trackedTokens = curve.trackedTokens();
        uint256 ethBefore = address(this).balance;

        (uint256 ethOut, uint256 tokenOut) = curve.completeGraduation();

        assertEq(ethOut, trackedQuote);
        assertEq(tokenOut, trackedTokens);
        assertEq(address(this).balance, ethBefore + ethOut);
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

        assertEq(protocolRecipient.balance, 0.01 ether);
        assertEq(creator.balance, 0.02 ether);
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

        assertEq(protocolRecipient.balance, 0.03 ether);
    }

    /// @notice A recipient that reverts on receive is paid by force and cannot hold the crossing
    /// buy's automatic sweep hostage.
    function test_ARevertingCreatorRecipientCannotBlockGraduation() public {
        RejectingSink sink = new RejectingSink();
        (SweepBondingCurve guarded,) = _deployCurve(address(sink));
        vm.warp(START + 5);

        vm.prank(whale);
        guarded.buy{value: 10 ether}(0, whale);

        assertTrue(guarded.graduated());
        assertGt(address(sink).balance, 0);
        assertEq(guarded.creatorFeeBalance(), 0);
    }

    /* ────────────────────────── graduation ────────────────────────── */

    /// @notice The flag is set before a single wei of fees leaves, so a recipient re-entering
    /// from inside the sweep's payment meets a closed market — refused by the flag itself, not
    /// by the reentrancy guard, which a directly-called `graduate` never holds.
    ///
    /// @dev The auto-graduated path is already double-covered: there `buy`'s own lock refuses
    /// the re-entry before the flag is even read. The path where the flag is the only defence is
    /// a keeper's or stranger's direct `graduate` after a starved crossing buy, so that exact
    /// state is built here: the protocol recipient burns its stipend to open the starvation
    /// window, and the creator is the re-entering recipient.
    function test_GraduatedIsSetBeforeFeesLeave() public {
        feeHook.setProtocolFeeRecipient(address(new GasEater()));
        ReenteringRecipient reenter = new ReenteringRecipient();
        (SweepBondingCurve hot,) = _deployCurve(address(reenter));
        vm.deal(address(reenter), 1 ether);
        vm.warp(START + 5);

        bool found;
        for (uint256 gas = 200_000; gas <= 3_000_000; gas += 10_000) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(whale);
            try hot.buy{value: 20 ether, gas: gas}(0, whale) {
                if (!hot.graduated()) {
                    found = true;
                    break;
                }
                vm.revertToState(snapshot);
                break;
            } catch {
                vm.revertToState(snapshot);
            }
        }
        assertTrue(found, "no gas limit starved graduation while completing the buy");

        reenter.arm(ICurveLike(address(hot)));
        hot.graduate();

        assertTrue(hot.graduated());
        assertTrue(reenter.attempted());
        assertTrue(reenter.observedGraduated());
        assertEq(bytes4(reenter.buyRevertReason()), SweepBondingCurve.CurveGraduated.selector);
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
        assertEq(curve.trackedQuote(), 0);
        assertEq(curve.trackedTokens(), 0);
        assertEq(token.balanceOf(address(this)), RESERVED);
        assertEq(token.markGraduatedCalls(), 1);
        assertEq(token.lastGraduationCaller(), address(curve));

        vm.expectRevert(SweepBondingCurve.NothingToComplete.selector);
        curve.completeGraduation();
    }

    receive() external payable {}
}
