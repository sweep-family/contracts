// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISweepHookRegistry
 * @author 0xDAVZER
 * @notice The one call the factory makes into the hook at launch.
 *
 * @dev Narrow on purpose, like `ISweepFeeReceiver` and `ISweepFactory`: the factory compiles
 * against a surface rather than an implementation, and this interface is also the complete list
 * of what the factory is trusted to do to the hook. The hook gates it on `msg.sender == factory`.
 */
interface ISweepHookRegistry {
    /// @notice Names where a strategy's creator share accrues from its first trade.
    function registerCreatorFeeRecipient(address strategy, address recipient) external;
}
