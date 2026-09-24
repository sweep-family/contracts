// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISweepBurnRouter
 * @author 0xDAVZER
 * @notice The narrow surface a strategy needs to convert ETH into its own token and destroy it.
 *
 * @dev Deliberately ours rather than Uniswap's. The strategy needs exactly one operation, and
 * naming it here keeps the desk testable against a mock while the factory supplies an adapter that
 * speaks to the real v4 router. Coupling the desk directly to a `PoolKey` would mean no purchase or
 * resale could be tested without a pool in existence.
 */
interface ISweepBurnRouter {
    /// @notice Spends `msg.value` of ETH buying `token` and sends what it receives to `recipient`.
    /// @return received Tokens actually delivered, which the caller should measure rather than trust.
    function buyTokenWithEth(address token, address recipient) external payable returns (uint256 received);
}
