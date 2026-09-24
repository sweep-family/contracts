// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";

/**
 * @title BatchGasTest
 * @author 0xDAVZER
 * @notice Pins what a maximum batch actually costs, so the bound can never drift back into a value
 * that cannot execute.
 *
 * @dev This test exists because the first `MAX_BATCH` was 5,000, which at ~25,065 gas per piece
 * would have cost ~125M — impossible on any chain we run against. Every unit test passed, because
 * they only ever minted 100. It was caught by deploying to a local chain and finding a contract
 * with a totalSupply of zero.
 *
 * A bound nobody has priced is a guess. This prices it.
 */
contract BatchGasTest is Test {
    /// @notice Ceiling a maximum batch must stay under, chosen against the tightest environment we
    /// run: a 30M block, leaving room for the rest of a transaction.
    uint256 internal constant BUDGET = 15_000_000;

    /**
     * @notice A full batch fits comfortably inside a block on every chain we deploy to.
     * @dev Measured against the local 30M limit rather than Robinhood Chain's reported 2^50, which
     * is the Arbitrum convention for "metered differently" and would let a broken bound pass here
     * while failing on anvil and in CI.
     */
    function test_MaxBatchFitsInsideABlock() public {
        SweepTestCollection collection = new SweepTestCollection("Phantom", "PHANTOM", "");
        uint256 quantity = collection.MAX_BATCH();

        uint256 before = gasleft();
        collection.mintBatch(address(this), quantity);
        uint256 spent = before - gasleft();

        assertLt(spent, BUDGET, "a full batch must fit inside a block with room to spare");
        assertEq(collection.totalSupply(), quantity);
    }
}
