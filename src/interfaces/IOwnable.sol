// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IOwnable
 * @author 0xDAVZER
 * @notice The single accessor the hook needs to identify a collection's owner.
 *
 * @dev Not part of ERC-721, and deliberately not assumed to exist: a collection that does not
 * implement it simply leaves its creator fee share unclaimable, which falls through to the protocol
 * rather than breaking anything. Read through a low-level call for that reason.
 */
interface IOwnable {
    function owner() external view returns (address);
}
