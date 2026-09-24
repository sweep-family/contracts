// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title MockMarketplace
 * @author 0xDAVZER
 * @notice An honest venue, standing in for Seaport in tests.
 *
 * @dev Deliberately not a Seaport clone. We are not testing Seaport; we are testing that the
 * strategy survives whatever a venue does with the ETH it is handed. A minimal honest venue makes
 * the happy path legible, and `HostileMarketplace` covers everything else.
 *
 * It pulls from the seller on fill rather than escrowing on list, which is how Seaport actually
 * behaves: a listing is an off-chain signature, and the piece stays with its owner until the moment
 * of sale. Escrowing instead would quietly make the strategy's purchase path easier than reality.
 */
contract MockMarketplace {
    struct Listing {
        address seller;
        uint256 price;
    }

    /// @notice Listings by collection and token id.
    mapping(address collection => mapping(uint256 tokenId => Listing)) public listings;

    /// @notice Piece is not listed, or was already sold.
    error NotListed();
    /// @notice Sent value does not equal the listed price.
    error WrongPayment();
    /// @notice Listing price of zero, which would be indistinguishable from "not listed".
    error ZeroPrice();
    /// @notice Paying the seller failed.
    error PayoutFailed();

    event Listed(address indexed collection, uint256 indexed tokenId, address seller, uint256 price);
    event Filled(address indexed collection, uint256 indexed tokenId, address buyer, uint256 price);

    /**
     * @notice Lists a piece the caller owns at a fixed price.
     * @dev Records `msg.sender` as the seller rather than reading `ownerOf`, so a listing survives
     * the owner moving the piece and then moving it back — which is what an off-chain signed order
     * does. The approval is checked at fill time, not here, for the same reason.
     * @dev A zero price is refused because the mapping's default is zero, so a zero-priced listing
     * could not be distinguished from an absent one.
     */
    function list(address collection, uint256 tokenId, uint256 price) external {
        if (price == 0) revert ZeroPrice();
        listings[collection][tokenId] = Listing({seller: msg.sender, price: price});
        emit Listed(collection, tokenId, msg.sender, price);
    }

    /**
     * @notice Buys a listed piece for exactly its listed price.
     * @dev Requires the exact value rather than at-least, so a test can never accidentally overpay
     * and mask a pricing bug in the strategy that called it.
     * @dev Clears the listing before transferring and before paying, so a collection or a seller
     * that reenters finds nothing left to buy twice.
     */
    function fulfill(address collection, uint256 tokenId) external payable {
        Listing memory listing = listings[collection][tokenId];
        if (listing.price == 0) revert NotListed();
        if (msg.value != listing.price) revert WrongPayment();

        delete listings[collection][tokenId];

        IERC721(collection).transferFrom(listing.seller, msg.sender, tokenId);

        (bool paid,) = listing.seller.call{value: msg.value}("");
        if (!paid) revert PayoutFailed();

        emit Filled(collection, tokenId, msg.sender, msg.value);
    }
}
