// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SweepGraduationMath} from "../src/libraries/SweepGraduationMath.sol";

/**
 * @title GraduationMathTest
 * @author 0xDAVZER
 * @notice Pins the seed price arithmetic and the preflight against hand-checkable powers of two
 * and against the one seed that actually matters: the real graduation's.
 *
 * @dev The expected values are computed by hand in the doc of each test, never with the library
 * under test — a test that recomputes the formula with the formula proves nothing.
 */
contract GraduationMathTest is Test {
    uint256 internal constant MAX_SEED = uint256(uint128(type(int128).max));

    /// @notice The real seed — 4.2 ETH against the pool's token allocation,
    /// `1e27 · P·T/(P+T)² = 1e27 · 10/49` — must pass the preflight, because the factory's
    /// constructor asserts exactly this and a failure there is an undeployable build.
    function test_TheRealGraduationSeedIsViable() public pure {
        SweepGraduationMath.assertSeedable(60, 4.2 ether, (uint256(1e27) * 10) / 49);
    }

    /// @notice `sqrt(1/1) · 2^96` is exactly `2^96`, at any magnitude of equal amounts.
    function test_AUnitRatioPricesAtTwoToTheNinetySix() public pure {
        assertEq(SweepGraduationMath.sqrtPriceX96FromAmounts(1, 1), uint160(1) << 96);
        assertEq(SweepGraduationMath.sqrtPriceX96FromAmounts(1e18, 1e18), uint160(1) << 96);
    }

    /// @notice `sqrt(1/4) · 2^96` is exactly `2^95`, pinning the Q192 path's arithmetic.
    function test_AQuarterRatioPricesAtTwoToTheNinetyFive() public pure {
        assertEq(SweepGraduationMath.sqrtPriceX96FromAmounts(4, 1), uint160(1) << 95);
    }

    /// @notice `sqrt(2^70/1) · 2^96` is exactly `2^131`, which only the Q128 fallback can reach —
    /// the Q192 intermediate would overflow — pinning the fallback's shift arithmetic.
    function test_TheWideRatioFallbackIsExact() public pure {
        assertEq(SweepGraduationMath.sqrtPriceX96FromAmounts(1, uint256(1) << 70), uint160(1) << 131);
    }

    /// @notice A seed missing either side has no price and is refused by name.
    function test_AZeroSidedSeedIsRefused() public {
        vm.expectRevert(SweepGraduationMath.ZeroAmount.selector);
        this.exposedSqrtPrice(0, 1);
        vm.expectRevert(SweepGraduationMath.ZeroAmount.selector);
        this.exposedSqrtPrice(1, 0);
    }

    /// @notice Amounts past `int128.max` would be truncated inside v4's mint rather than
    /// refused, so the preflight refuses them first, on either side.
    function test_AnAmountPastTheDeltaBoundIsRefused() public {
        vm.expectRevert(SweepGraduationMath.SeedNotViable.selector);
        this.exposedAssertSeedable(60, MAX_SEED + 1, 1e18);
        vm.expectRevert(SweepGraduationMath.SeedNotViable.selector);
        this.exposedAssertSeedable(60, 1e18, MAX_SEED + 1);
    }

    /// @notice A full-range position at both amounts' maximum overflows the per-tick liquidity
    /// cap — v4 would revert the mint, so the preflight must refuse the seed first.
    function test_ASeedOverTheTickLiquidityCapIsRefused() public {
        vm.expectRevert(SweepGraduationMath.SeedNotViable.selector);
        this.exposedAssertSeedable(60, MAX_SEED, MAX_SEED);
    }

    /// @notice The usable full-range boundaries snap toward zero onto the spacing.
    function test_FullRangeTicksSnapToTheSpacing() public pure {
        (int24 tickLower, int24 tickUpper) = SweepGraduationMath.fullRangeTicks(60);
        assertEq(tickLower, -887_220);
        assertEq(tickUpper, 887_220);
    }

    /// @dev `vm.expectRevert` only observes external calls; internal library functions inline
    /// into their caller, so the refusals above go through these wrappers.
    function exposedSqrtPrice(uint256 amount0, uint256 amount1) external pure returns (uint160) {
        return SweepGraduationMath.sqrtPriceX96FromAmounts(amount0, amount1);
    }

    function exposedAssertSeedable(int24 tickSpacing, uint256 ethAmount, uint256 tokenAmount) external pure {
        SweepGraduationMath.assertSeedable(tickSpacing, ethAmount, tokenAmount);
    }
}
