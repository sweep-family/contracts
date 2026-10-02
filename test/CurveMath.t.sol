// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SweepCurveMath} from "../src/libraries/SweepCurveMath.sol";

/**
 * @title CurveMathTest
 * @author 0xDAVZER
 * @notice Pins the constant-product quotes the bonding curve prices every trade with.
 *
 * @dev The library is pure, so everything here is either a fuzzed algebraic property or a named
 * refusal. Bounds keep reserves at or below 1e28 and outputs at or below five sevenths of the
 * reserve — an order of magnitude past anything the curve can reach (its quote side tops out
 * near 5.88e18, its token side at 1e27, and the largest fill it ever prices is the sellable
 * five sevenths of the supply) while staying clear of the uint256 overflow a round trip against
 * astronomically mismatched reserves would hit, which no book shaped like ours can produce.
 */
contract CurveMathTest is Test {
    uint256 internal constant RESERVE_CAP = 1e28;
    uint256 internal constant INPUT_CAP = 1e27;

    /// @notice Buying with the exact input that a `getAmountIn` quote demanded always delivers at
    /// least the output that was asked for — the round trip never undercharges the curve.
    function testFuzz_RoundTripNeverUndercharges(uint256 reserveIn, uint256 reserveOut, uint256 amountOut) public pure {
        reserveIn = bound(reserveIn, 1e6, RESERVE_CAP);
        reserveOut = bound(reserveOut, 7, RESERVE_CAP);
        amountOut = bound(amountOut, 1, (reserveOut * 5) / 7);

        uint256 amountIn = SweepCurveMath.getAmountIn(amountOut, reserveIn, reserveOut);
        uint256 delivered = SweepCurveMath.getAmountOut(amountIn, reserveIn, reserveOut);

        assertGe(delivered, amountOut);
    }

    /// @notice The product of the reserves never decreases across a trade, which is the entire
    /// definition of the curve: rounding always favours the reserves, never the trader.
    function testFuzz_TheInvariantNeverDecreases(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) public pure {
        reserveIn = bound(reserveIn, 1e18, RESERVE_CAP);
        reserveOut = bound(reserveOut, 1e18, RESERVE_CAP);
        amountIn = bound(amountIn, 1e15, INPUT_CAP);

        uint256 amountOut = SweepCurveMath.getAmountOut(amountIn, reserveIn, reserveOut);

        assertGe((reserveIn + amountIn) * (reserveOut - amountOut), reserveIn * reserveOut);
    }

    /// @notice No input, however large, extracts the whole output reserve.
    function testFuzz_TheOutputNeverReachesTheReserve(uint256 reserveIn, uint256 reserveOut, uint256 amountIn)
        public
        pure
    {
        reserveIn = bound(reserveIn, 1e18, RESERVE_CAP);
        reserveOut = bound(reserveOut, 1e18, RESERVE_CAP);
        amountIn = bound(amountIn, 1e15, INPUT_CAP);

        assertLt(SweepCurveMath.getAmountOut(amountIn, reserveIn, reserveOut), reserveOut);
    }

    /// @notice A bigger spend never buys less, so a buyer cannot be punished for size by the
    /// math itself — only by the price impact the invariant already encodes.
    function testFuzz_TheQuoteIsMonotonicInTheInput(uint256 reserveIn, uint256 reserveOut, uint256 a, uint256 b)
        public
        pure
    {
        reserveIn = bound(reserveIn, 1e18, RESERVE_CAP);
        reserveOut = bound(reserveOut, 1e18, RESERVE_CAP);
        a = bound(a, 1e15, INPUT_CAP - 1);
        b = bound(b, a + 1, INPUT_CAP);

        assertGe(
            SweepCurveMath.getAmountOut(b, reserveIn, reserveOut), SweepCurveMath.getAmountOut(a, reserveIn, reserveOut)
        );
    }

    /// @notice A fill that rounds to nothing is a donation dressed as a trade, and is refused.
    function test_ADustInputThatBuysNothingIsRefused() public {
        vm.expectRevert(SweepCurveMath.InsufficientOutputAmount.selector);
        this.exposedGetAmountOut(1, 1e18, 1);
    }

    /// @notice A zero input is a mistake, not a trade, and is refused by name.
    function test_AZeroInputIsRefused() public {
        vm.expectRevert(SweepCurveMath.InsufficientInputAmount.selector);
        this.exposedGetAmountOut(0, 1e18, 1e27);
    }

    /// @notice An empty side means there is no market to price against, in either direction.
    function test_AnEmptyReserveIsRefused() public {
        vm.expectRevert(SweepCurveMath.InsufficientLiquidity.selector);
        this.exposedGetAmountOut(1e18, 0, 1e27);

        vm.expectRevert(SweepCurveMath.InsufficientLiquidity.selector);
        this.exposedGetAmountOut(1e18, 1e18, 0);

        vm.expectRevert(SweepCurveMath.InsufficientLiquidity.selector);
        this.exposedGetAmountIn(1e18, 0, 1e27);
    }

    /// @notice Asking `getAmountIn` for the whole reserve, or more, has no finite price.
    function test_AskingForTheWholeReserveIsRefused() public {
        vm.expectRevert(SweepCurveMath.InsufficientLiquidity.selector);
        this.exposedGetAmountIn(1e27, 1e18, 1e27);
    }

    /// @notice A zero output request is a mistake, not a quote.
    function test_AZeroOutputRequestIsRefused() public {
        vm.expectRevert(SweepCurveMath.InsufficientOutputAmount.selector);
        this.exposedGetAmountIn(0, 1e18, 1e27);
    }

    /// @dev `vm.expectRevert` only observes external calls, and a library's internal functions
    /// inline into their caller, so the refusals above go through these wrappers.
    function exposedGetAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return SweepCurveMath.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function exposedGetAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256)
    {
        return SweepCurveMath.getAmountIn(amountOut, reserveIn, reserveOut);
    }
}
