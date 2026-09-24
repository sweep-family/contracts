// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title OwnedCollection
 * @author 0xDAVZER
 * @notice A contract that answers `owner()` and is not a collection.
 *
 * @dev `owner()` is not part of ERC-721, so the factory reads it through a low-level call and a
 * missing accessor means "nobody to vouch for this launch" rather than an error. The collection
 * with no accessor at all is `OwnerlessERC721`, which is also a real ERC-721; this one is the
 * opposite shape, and pins that answering `owner()` is not enough to be launched on.
 */
contract OwnedCollection {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}
