// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISweepLockedToken} from "../../src/interfaces/ISweepLockedToken.sol";
import {MockPoolLeg} from "./MockPoolLeg.sol";

/**
 * @title MockStrategyHook
 * @author 0xDAVZER
 * @notice Answers the two questions a strategy or a curve ever asks a hook — which factory it
 * answers to, and where the protocol's fees go — so the strategies' owner-facing setters and the
 * curve's sweeps can be tested with no v4 in sight.
 */
contract MockStrategyHook {
    address public factory;
    address public protocolFeeRecipient;

    constructor(address factory_, address protocolFeeRecipient_) {
        factory = factory_;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// @notice Plays one swap's token leg the way the real hook allows it: grants the token's
    /// transient allowance, then has the pool move the tokens, in one transaction.
    function poolLeg(address token, MockPoolLeg pool, address from, address to, uint256 amount) external {
        ISweepLockedToken(token).increaseTransferAllowance(amount);
        pool.move(token, from, to, amount);
    }

    receive() external payable {}
}
