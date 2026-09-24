// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

interface IAllowanceReader {
    function transferAllowance() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title SwapProbe
 * @author 0xDAVZER
 * @notice Swaps and then reports what the strategy's transfer allowance still holds, from inside
 * the same transaction.
 *
 * @dev Without this the assertion is vacuous. The allowance lives in transient storage, and Foundry
 * clears transient storage between one test-level call and the next — correctly, since they are
 * different transactions. So a test that swaps and then reads the allowance reads zero whether the
 * hook authorised the exact amount or ten times it. Measured that way the check passes against a
 * deliberately broken hook, which is how it was caught.
 *
 * @dev It is also the only way to observe departure 1. A hook that took its fee out of the
 * PoolManager and settled it straight back would end the transaction holding nothing, so no balance
 * read afterwards can tell that apart from a hook that moved no tokens at all. The allowance it
 * would have had to consume is the evidence that survives.
 */
contract SwapProbe {
    PoolSwapTest private immutable router;

    constructor(PoolSwapTest router_) {
        router = router_;
    }

    /// @notice Lets the router pull this probe's tokens, as any trader must before selling.
    function approveRouter(address token) external {
        IAllowanceReader(token).approve(address(router), type(uint256).max);
    }

    /// @notice Buys with the ETH sent, and reports the allowance left standing afterwards.
    function buyAndReadAllowance(PoolKey memory key) external payable returns (uint256) {
        router.swap{value: msg.value}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(msg.value), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return IAllowanceReader(Currency.unwrap(key.currency1)).transferAllowance();
    }

    /// @notice Sells `amount`, and reports the allowance left standing afterwards.
    function sellAndReadAllowance(PoolKey memory key, uint256 amount) external returns (uint256) {
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return IAllowanceReader(Currency.unwrap(key.currency1)).transferAllowance();
    }

    receive() external payable {}
}
