// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";

/**
 * @title DeployTestCollection
 * @author 0xDAVZER
 * @notice Deploys a phantom collection and populates it, so staging has something to launch a
 * strategy against before any real collection has agreed to try us.
 *
 * @dev Refuses to run on Robinhood Chain mainnet. This contract lets anyone mint for free and
 * exists only to be a stand-in; a phantom collection reaching mainnet would be indistinguishable
 * from a real one to anyone reading the chain, and a strategy could be launched against it.
 *
 * Usage:
 *   forge script script/DeployTestCollection.s.sol \
 *     --rpc-url $ROBINHOOD_TESTNET_RPC_URL --broadcast
 */
contract DeployTestCollection is Script {
    uint256 internal constant ROBINHOOD_MAINNET = 4663;

    /// @notice Pieces minted at deployment, echoing the shape of a real collection.
    /// @dev StonkBrokers has 4,444. A handful would let a strategy own a meaningful share of the
    /// collection after two purchases, which is not the situation we need to rehearse.
    uint256 internal constant INITIAL_SUPPLY = 500;

    /// @notice Refused because this collection is free to mint and must never look real.
    error NotForMainnet();

    function run() external returns (SweepTestCollection collection) {
        if (block.chainid == ROBINHOOD_MAINNET) revert NotForMainnet();

        vm.startBroadcast();

        collection = new SweepTestCollection(
            "Phantom Brokers", "PHANTOM", "https://www.scatter.art/api/instareveal/mz0ms6owpjvvcvlarzru0sli/"
        );

        uint256 batchSize = collection.MAX_BATCH();
        uint256 remaining = INITIAL_SUPPLY;
        while (remaining != 0) {
            uint256 take = remaining < batchSize ? remaining : batchSize;
            collection.mintBatch(msg.sender, take);
            remaining -= take;
        }

        vm.stopBroadcast();

        console.log("collection :", address(collection));
        console.log("chain      :", block.chainid);
        console.log("minted     :", collection.totalSupply());
    }
}
