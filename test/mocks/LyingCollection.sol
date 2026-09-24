// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title LyingCollection
 * @author 0xDAVZER
 * @notice An ERC-721 whose `transferFrom` quietly does nothing and returns as if it worked.
 *
 * @dev Non-conforming, and they exist. A desk that clears its listing *before* transferring and
 * ignores the result is broken by exactly this shape: a buyer's ETH is taken, the piece stays put,
 * and the listing is destroyed — all in one transaction, with nothing reverting.
 *
 * Our desk transfers first and asserts ownership afterwards, so this contract makes that assertion
 * fire instead of being taken on trust.
 */
contract LyingCollection {
    mapping(uint256 tokenId => address) internal _owners;
    mapping(address account => uint256) internal _balances;

    /// @notice Whether `transferFrom` currently lies.
    /// @dev A switch rather than always-on, because a collection that never delivers cannot deliver
    /// on the way in either — the purchase would fail its own balance check and the sale path would
    /// never be reached. Toggling isolates the failure being tested.
    bool public lying;

    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
        ++_balances[to];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function setLying(bool value) external {
        lying = value;
    }

    /// @notice Transfers, or pretends to, depending on the switch.
    function transferFrom(address from, address to, uint256 tokenId) external {
        if (lying) return;
        _owners[tokenId] = to;
        --_balances[from];
        ++_balances[to];
    }

    function setApprovalForAll(address, bool) external {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd;
    }
}
