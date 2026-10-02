// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/**
 * @title SweepGraduationMath
 * @author 0xDAVZER
 * @notice The price a graduation seed opens at, and the preflight that proves the seed can mint
 * before a single wei has moved.
 *
 * @dev The price math and the mint preflight live in one library, reduced to a single currency
 * ordering: Sweep's quote is always native ETH, which sorts below every ERC-20, so ETH is always
 * `currency0` and an either-ordering variant for arbitrary pair tokens would have nothing to
 * decide here.
 */
library SweepGraduationMath {
    /// @notice The most of either asset a seed may carry: v4's `BalanceDelta` narrows to
    /// `int128`, so anything larger would be truncated inside the mint rather than refused.
    uint256 internal constant MAX_SEED_AMOUNT = uint256(uint128(type(int128).max));

    error ZeroAmount();
    error SeedNotViable();

    /**
     * @notice Computes `sqrtPriceX96 = sqrt(amount1 / amount0) · 2^96`.
     *
     * @dev The Q192 path is exact and taken whenever `amount1 · 2^192 / amount0` fits a uint256,
     * which holds for every ratio below 2^64 and covers the real seed by seven orders of
     * magnitude. The Q128 fallback keeps larger ratios computable without the intermediate
     * overflowing; its square root cannot exceed `uint128.max` (it is the root of a uint256),
     * so the shift back into Q96 always fits a uint160 and needs no guard of its own — a ratio
     * too extreme even for Q128 reverts inside `FullMath.mulDiv` instead. `ZeroAmount` refuses
     * a priceless seed.
     */
    function sqrtPriceX96FromAmounts(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        if (amount1 / amount0 < (1 << 64)) {
            uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
            return uint160(FixedPointMathLib.sqrt(ratioX192));
        }

        uint256 ratioX128 = FullMath.mulDiv(amount1, 1 << 128, amount0);
        return uint160(FixedPointMathLib.sqrt(ratioX128) << 32);
    }

    /**
     * @notice Reverts unless a full-range position of these amounts can be minted at their
     * implied price.
     *
     * @dev Models the real mint's rejections so they surface before anything irreversible: the
     * `int128` amount bounds v4 narrows to, a liquidity of zero (a position the mint would
     * refuse as empty, stranding the graduation in a revert loop), and the per-tick liquidity
     * cap a full-range mint hits with both boundary ticks. v4's sqrt-price bounds are not
     * re-checked here because the amount bound already confines the price inside them: with
     * both amounts in `[1, 2^127)` the ratio stays in `(2^-127, 2^127)`, so the root price
     * stays in `(2^32.5, 2^159.5)`, strictly inside `(MIN_SQRT_PRICE ≈ 2^32, MAX_SQRT_PRICE
     * ≈ 2^160.5)` — a bounds guard here would be dead code no mutation could kill. The factory
     * runs this in its constructor against the constant economics — a misbuilt deployment fails
     * at deploy — and again before every graduation's sweep, so rounding drift is caught while
     * the reserves are still on the curve and retryable.
     */
    function assertSeedable(int24 tickSpacing, uint256 ethAmount, uint256 tokenAmount) internal pure {
        if (ethAmount > MAX_SEED_AMOUNT || tokenAmount > MAX_SEED_AMOUNT) revert SeedNotViable();

        uint160 sqrtPriceX96 = sqrtPriceX96FromAmounts(ethAmount, tokenAmount);
        (int24 tickLower, int24 tickUpper) = fullRangeTicks(tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            tokenAmount
        );
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)) {
            revert SeedNotViable();
        }
    }

    /**
     * @notice v4's usable full-range boundaries for a tick spacing.
     * @dev Truncation toward zero is what derives the usable boundary from the absolute one, so
     * the division deliberately happens before the multiplication.
     */
    function fullRangeTicks(int24 tickSpacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }
}
