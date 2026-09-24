// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title OwnerlessERC721
 * @author 0xDAVZER
 * @notice A collection that answers to ERC-721 and has no `owner()` at all — CryptoPunks, and most
 * of the early collections. Exists so the launch gate can be watched refusing a stranger on it and
 * admitting the factory owner through `ownerLaunch`.
 */
contract OwnerlessERC721 {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd;
    }
}
