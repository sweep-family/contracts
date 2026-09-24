// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/**
 * @notice Proves the toolchain resolves every dependency the protocol needs, before any
 * protocol code exists. If this file stops compiling, a dependency moved, and every later
 * contract would then fail for a reason that has nothing to do with its own logic.
 *
 * @dev It exists specifically because `BaseHook` is NOT in v4-periphery 1.0.4 — it lives in
 * the separate `v4-hooks-public` repository, which is an easy thing to get wrong and a
 * confusing one to debug. The imports above are deliberately unused: resolving them is the
 * assertion.
 */
contract ToolchainTest is Test {
    /**
     * @notice Pins the tick bounds the factory's position math is derived from.
     * @dev The launch position is placed against these bounds and the pool's tick spacing. If
     * v4-core ever moved them, every launch position would be seeded across the wrong range
     * while still appearing to succeed.
     */
    function test_TickMathBoundsAreTheOnesTheProtocolAssumes() public pure {
        assertEq(TickMath.MIN_TICK, -887_272, "MIN_TICK moved");
        assertEq(TickMath.MAX_TICK, 887_272, "MAX_TICK moved");
    }

    /**
     * @notice Pins the real ceiling on either side of a launch position.
     * @dev `Pool.modifyLiquidity` narrows each half of a `BalanceDelta` with
     * `SafeCast.toInt128`, so the *signed* maximum binds even though the PositionManager's
     * `MINT_POSITION` ABI accepts a `uint128`. An amount between the two passes every
     * field-width check and still reverts inside v4 core, at the last step of a launch. Every
     * amount bound in the protocol traces back to this number.
     */
    function test_BalanceDeltaNarrowsToInt128() public pure {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 signedMax = uint256(uint128(type(int128).max));
        assertEq(signedMax, 170_141_183_460_469_231_731_687_303_715_884_105_727);
    }

    /**
     * @notice Confirms the per-tick liquidity ceiling is reachable from our remappings.
     * @dev A launch position initializes both boundary ticks, so the position's own liquidity
     * is the entire `liquidityGross` at each. v4 reverts with `TickLiquidityOverflow` past the
     * cap a spacing implies — an independent rejection from the amount bounds above, and one a
     * launch has to respect or it reverts at its last step.
     */
    function test_MaxLiquidityPerTickIsQueryable() public pure {
        assertGt(Pool.tickSpacingToMaxLiquidityPerTick(60), 0);
    }
}
