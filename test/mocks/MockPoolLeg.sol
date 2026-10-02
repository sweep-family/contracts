// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockPoolLeg
 * @author 0xDAVZER
 * @notice Stands in for the PoolManager in tests with no v4 in sight: the address the token's
 * lock treats as the pool, moving tokens only when told to by the hook that granted the leg.
 *
 * @dev The lock admits a PoolManager movement only against the hook's transient allowance, and
 * Foundry clears transient storage between one test-level call and the next, so the grant and
 * the move have to happen inside one call — `MockStrategyHook.poolLeg` makes both.
 */
contract MockPoolLeg {
    /// @notice Moves `amount` from `from` to `to`: a plain transfer when the pool pays out, a
    /// `transferFrom` on the holder's approval when the pool takes in.
    function move(address token, address from, address to, uint256 amount) external {
        if (from == address(this)) {
            IERC20(token).transfer(to, amount);
        } else {
            IERC20(token).transferFrom(from, to, amount);
        }
    }
}
