// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SweepCurveMath
 * @author 0xDAVZER
 * @notice Constant-product quotes for the bonding curve, both directions.
 *
 * @dev No embedded-fee parameter: Sweep's curve always takes its fees outside the invariant, so
 * the quotes price the bare constant product. Rounding always
 * favours the reserves — `getAmountOut` floors what leaves, `getAmountIn` adds one to what must
 * arrive — so no sequence of trades can pull the invariant down.
 */
library SweepCurveMath {
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();

    /**
     * @notice The output an exact input buys.
     *
     * @dev `InsufficientInputAmount` refuses a zero input, which is a mistake and not a trade.
     * `InsufficientLiquidity` refuses an empty side, where there is no market to price against.
     * `InsufficientOutputAmount` refuses a fill that rounds to nothing: without it a dust trade
     * would hand its whole input to the curve and deliver zero, which is a donation dressed as
     * a trade.
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        if (amountOut == 0) revert InsufficientOutputAmount();
    }

    /**
     * @notice The input an exact output costs.
     *
     * @dev `InsufficientOutputAmount` refuses a zero request. `InsufficientLiquidity` refuses a
     * request for the whole output reserve or more, which has no finite price on this curve.
     * The `+ 1` is the rounding that keeps `getAmountOut(getAmountIn(x)) >= x`: charging the
     * floor instead would let the round trip under-pay by a wei per call.
     */
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (reserveIn == 0 || reserveOut <= amountOut) revert InsufficientLiquidity();

        amountIn = (amountOut * reserveIn) / (reserveOut - amountOut) + 1;
    }
}
