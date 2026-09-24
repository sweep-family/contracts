// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISweepLockedToken} from "./ISweepLockedToken.sol";

/**
 * @title ISweepFeeReceiver
 * @author 0xDAVZER
 * @notice The calls the hook makes into a strategy: funding it, and opening its lock for a swap.
 *
 * @dev Split out from the strategy itself so the hook compiles against a surface rather than an
 * implementation. Every strategy gates both of these on `onlyHook`, so this interface is also the
 * complete list of what the hook is trusted to do to a strategy.
 */
interface ISweepFeeReceiver is ISweepLockedToken {
    /// @notice Credits the strategy with the ETH sent alongside.
    function addFees() external payable;
}
