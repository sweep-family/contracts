// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISweepBurnRouter} from "../../src/interfaces/ISweepBurnRouter.sol";

interface IMinimalERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title MockBurnRouter
 * @author 0xDAVZER
 * @notice Stands in for the Uniswap adapter, at a fixed rate.
 *
 * @dev Holds an inventory of the strategy's token and hands some over for every ETH it is paid. A
 * real router would price against a pool; here the rate is fixed so a test asserts on the burn's
 * accounting rather than on AMM maths, which belongs to the real router.
 */
contract MockBurnRouter is ISweepBurnRouter {
    /// @notice Tokens handed over per wei of ETH received.
    uint256 public rate = 1000;

    /// @notice Total ETH this router has been paid.
    uint256 public ethReceived;

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    /// @dev Sends to `recipient` rather than to the caller, because the strategy wants the tokens
    /// to land at the dead address without ever passing through its own balance.
    function buyTokenWithEth(address token, address recipient) external payable returns (uint256 received) {
        ethReceived += msg.value;
        received = msg.value * rate;
        IMinimalERC20(token).transfer(recipient, received);
    }

    receive() external payable {}
}
