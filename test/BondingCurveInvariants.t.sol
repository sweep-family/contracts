// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {CurveTestToken} from "./mocks/CurveTestToken.sol";
import {Donor, MockFeeHook} from "./mocks/CurveTestActors.sol";

/**
 * @title CurveHandler
 * @author 0xDAVZER
 * @notice The one actor the invariant runner drives: it buys, sells, sweeps, donates and lets
 * time pass, keeping ghost totals of every wei that legitimately entered or left the curve.
 *
 * @dev The handler is itself the trader and the donor, so the ghost sums can be measured as its
 * own balance deltas rather than re-deriving fee arithmetic — an invariant that recomputes the
 * contract's math with the contract's math would prove nothing. Failed calls add nothing to the
 * ghosts, which is exactly the claim: only successful trades move the books.
 */
contract CurveHandler is Test {
    SweepBondingCurve public curve;
    CurveTestToken public token;

    uint256 public ghostQuoteIn;
    uint256 public ghostQuoteOut;
    uint256 public ghostEthDonated;
    uint256 public ghostTokensDonated;

    constructor(SweepBondingCurve curve_, CurveTestToken token_) {
        curve = curve_;
        token = token_;
        token_.approve(address(curve_), type(uint256).max);
    }

    function buy(uint256 amount) external {
        if (curve.graduated()) return;
        amount = bound(amount, 1, 0.5 ether);
        vm.deal(address(this), amount);
        uint256 balanceBefore = address(this).balance;
        try curve.buy{value: amount}(0, address(this)) {
            ghostQuoteIn += balanceBefore - address(this).balance;
        } catch {}
    }

    function sell(uint256 amount) external {
        if (curve.graduated() || curve.readyToGraduate()) return;
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return;
        amount = bound(amount, 1, held);
        uint256 balanceBefore = address(this).balance;
        try curve.sell(amount, 0, address(this)) {
            ghostQuoteOut += address(this).balance - balanceBefore;
        } catch {}
    }

    function sweep() external {
        try curve.sweepFees() {} catch {}
    }

    function donateEth(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        new Donor{value: amount}(payable(address(curve)));
        ghostEthDonated += amount;
    }

    function donateTokens(uint256 amount) external {
        uint256 held = token.balanceOf(address(this));
        if (held < 2) return;
        amount = bound(amount, 1, held / 2);
        token.transfer(address(curve), amount);
        ghostTokensDonated += amount;
    }

    function tick(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 4));
    }

    receive() external payable {}
}

/**
 * @title BondingCurveInvariantsTest
 * @author 0xDAVZER
 * @notice Holds the curve's books to its balances across arbitrary trade sequences, snipe window
 * included, right up to and across graduation.
 *
 * @dev The fee recipients are fresh addresses that receive from the curve and from nothing else,
 * so "everything swept" is their plain balance and no event parsing is needed.
 */
contract BondingCurveInvariantsTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant PHANTOM = 1.68 ether;

    SweepBondingCurve internal curve;
    CurveTestToken internal token;
    CurveHandler internal handler;

    address internal protocolRecipient = makeAddr("invariantProtocol");
    address internal creator = makeAddr("invariantCreator");
    address internal launcher = makeAddr("invariantLauncher");

    function setUp() public {
        vm.warp(1_788_000_000);
        MockFeeHook feeHook = new MockFeeHook(protocolRecipient);
        token = new CurveTestToken(address(feeHook));
        address implementation = address(new SweepBondingCurve());
        curve = SweepBondingCurve(payable(LibClone.deployERC1967(implementation)));
        token.mint(address(curve), SUPPLY);
        curve.initialize(address(token), creator, launcher);

        handler = new CurveHandler(curve, token);
        targetContract(address(handler));
    }

    /// @notice Every wei of tracked quote is a wei that came in through a buy and has not left
    /// through a sell or a sweep. Nothing else may ever move the books.
    function invariant_TrackedQuoteEqualsBuysMinusSellsMinusPayouts() public view {
        uint256 paidOut = protocolRecipient.balance + creator.balance;
        assertEq(curve.trackedQuote(), handler.ghostQuoteIn() - handler.ghostQuoteOut() - paidOut);
    }

    /// @notice The pool's allocation is never sold: the token books never drop below the reserved
    /// line, and land exactly on it at graduation.
    function invariant_ReservedTokensAreNeverSold() public view {
        assertGe(curve.trackedTokens(), curve.reservedTokens());
        if (curve.graduated()) {
            assertEq(curve.trackedTokens(), curve.reservedTokens());
        }
    }

    /// @notice The contract's real holdings cover its books exactly, donations aside — the books
    /// can never promise money or tokens the contract does not hold.
    function invariant_TheBalancesCoverTheBooksExactly() public view {
        assertEq(address(curve).balance, curve.trackedQuote() + handler.ghostEthDonated());
        assertEq(token.balanceOf(address(curve)), curve.trackedTokens() + handler.ghostTokensDonated());
    }

    /// @notice The quote reserve the pricing sees never falls below the phantom floor, so the
    /// price can never fall below the opening price.
    function invariant_TheQuoteReserveNeverFallsBelowThePhantom() public view {
        (uint256 quoteReserve,) = curve.getReserves();
        assertGe(quoteReserve, PHANTOM);
    }

    /// @notice Fee buckets are always payable: they never exceed the tracked quote behind them.
    function invariant_TheBucketsNeverOutgrowTheTrackedQuote() public view {
        assertLe(curve.protocolFeeBalance() + curve.creatorFeeBalance(), curve.trackedQuote());
    }
}
