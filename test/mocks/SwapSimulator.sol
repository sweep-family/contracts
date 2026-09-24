// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SweepStrategy} from "../../src/SweepStrategy.sol";

/**
 * @title SwapSimulator
 * @author 0xDAVZER
 * @notice Stands in for the hook and the PoolManager together, so a pool transfer can be exercised
 * the way it actually happens: inside one transaction.
 *
 * @dev The transfer allowance lives in transient storage, so it cannot outlive the transaction that
 * granted it. That is the security property — no standing hole in the transfer lock — and it is
 * also why two separate calls from a test can never authorise one another. A real swap has the hook
 * granting the allowance and the PoolManager moving the tokens within a single transaction, which
 * is what this reproduces.
 *
 * Acting as both roles at once is fine for exercising the allowance itself; that the two roles are
 * distinct is pinned separately by the tests on `onlyHook`.
 */
contract SwapSimulator {
    /// @notice Authorises and then performs a pool movement, atomically.
    function authoriseAndMove(SweepStrategy strategy, address to, uint256 allowance, uint256 amount) external {
        strategy.increaseTransferAllowance(allowance);
        strategy.transfer(to, amount);
    }

    /// @notice Authorises once, then moves twice, to prove the allowance is consumed.
    function authoriseAndMoveTwice(SweepStrategy strategy, address to, uint256 allowance, uint256 first, uint256 second)
        external
    {
        strategy.increaseTransferAllowance(allowance);
        strategy.transfer(to, first);
        strategy.transfer(to, second);
    }

    /// @notice Reads the allowance from inside the same transaction that granted it.
    function allowanceAfterGranting(SweepStrategy strategy, uint256 grant) external returns (uint256) {
        strategy.increaseTransferAllowance(grant);
        return strategy.transferAllowance();
    }
}
