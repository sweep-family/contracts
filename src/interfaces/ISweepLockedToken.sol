// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISweepLockedToken
 * @author 0xDAVZER
 * @notice The one thing the hook may do to any Sweep token: open its transfer lock for one swap.
 *
 * @dev Split out of `ISweepFeeReceiver` so a token and its fee receiver can be different
 * inheritance branches of the same contract without the compiler seeing two definitions of one
 * function. Every Sweep token implements this; only the strategies also receive fees.
 */
interface ISweepLockedToken {
    /**
     * @notice Authorises `amount` of the token to move through the PoolManager, for the remainder
     * of this transaction only.
     * @dev The token reverts on any transfer it has not been told about, so without this call the
     * router cannot deliver the tokens a swap just bought.
     */
    function increaseTransferAllowance(uint256 amount) external;
}
