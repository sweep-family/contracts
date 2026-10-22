// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISeaport
 * @notice The slice of Seaport 1.6 the token listing relay and its tests touch.
 *
 * @dev Transcribed from the Seaport ABI the backend embeds
 * (`apps/backend/internal/contracts/abi/Seaport.json`), field for field and in order, and checked
 * against the deployment on Robinhood Chain: `information()` at
 * `0x0000000000000068F116a894984e2DB1123eB395` answers version "1.6". The enums are `uint8` on the
 * wire, which is how they are kept here.
 */
interface ISeaport {
    struct OfferItem {
        uint8 itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
    }

    struct ConsiderationItem {
        uint8 itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
        address payable recipient;
    }

    struct OrderParameters {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        uint8 orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 totalOriginalConsiderationItems;
    }

    struct OrderComponents {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        uint8 orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 counter;
    }

    struct AdvancedOrder {
        OrderParameters parameters;
        uint120 numerator;
        uint120 denominator;
        bytes signature;
        bytes extraData;
    }

    struct CriteriaResolver {
        uint256 orderIndex;
        uint8 side;
        uint256 index;
        uint256 identifier;
        bytes32[] criteriaProof;
    }

    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);

    function getOrderHash(OrderComponents calldata order) external view returns (bytes32 orderHash);

    function getCounter(address offerer) external view returns (uint256 counter);

    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}
