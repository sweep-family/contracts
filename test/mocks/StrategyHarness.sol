// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SweepStrategy} from "../../src/SweepStrategy.sol";

/**
 * @title StrategyHarness
 * @author 0xDAVZER
 * @notice Makes `SweepStrategy`'s internal seams reachable from a test, and stands in for the swap
 * the concrete strategy will perform.
 *
 * @dev `_executeBurn` records rather than swaps. That is the point of leaving the swap abstract in
 * the base: every rule about the bid, the treasury, the lock and the burn schedule can be pinned
 * here with no pool, no router and no fork, and the swap itself gets tested separately against a
 * real pool once one exists.
 */
contract StrategyHarness is SweepStrategy {
    /// @notice Total ETH `_executeBurn` was asked to spend, across all passes.
    uint256 public burnedThrough;

    /// @notice Number of times `_executeBurn` was reached.
    uint256 public burnCalls;

    function initialize(
        string memory name_,
        string memory symbol_,
        address hook_,
        address poolManager_,
        uint256 bidIncreasePerSecond_,
        uint256 maxBid_,
        address owner_
    ) external initializer {
        __SweepStrategy_init(name_, symbol_, hook_, poolManager_, bidIncreasePerSecond_, maxBid_, owner_);
        isDistributor[msg.sender] = true;
    }

    /// @notice Funds the treasury without going through the hook.
    function exposed_fund(uint256 amount) external {
        treasury += amount;
    }

    /// @notice Books a purchase, as the concrete strategy will after acquiring an asset.
    function exposed_recordPurchase(uint256 cost) external {
        _recordPurchase(cost);
    }

    /// @notice Books a sale, as the concrete strategy will after selling one.
    /// @dev Deals the contract the ETH a real sale would have delivered, so the burn pass has
    /// something to actually pay its caller with.
    function exposed_recordSale(uint256 proceeds) external {
        _recordSale(proceeds);
        vm_deal(address(this), address(this).balance + proceeds);
    }

    /// @notice Moves supply to the dead address, standing in for a completed burn.
    function exposed_moveToDead(uint256 amount) external {
        _transfer(msg.sender, DEAD_ADDRESS, amount);
    }

    /// @notice Hands tokens to a test account, bypassing the lock the way the router does.
    function exposed_credit(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    /// @dev Records what a real strategy would have swapped.
    function _executeBurn(uint256 amountIn) internal override {
        burnedThrough += amountIn;
        ++burnCalls;
    }

    /// @dev Forge's cheatcode address, reached directly so the harness can fund itself without
    /// inheriting the whole test framework into a contract that ships nowhere near production.
    function vm_deal(address who, uint256 amount) private {
        (bool ok,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("deal(address,uint256)", who, amount));
        ok;
    }

    receive() external payable {}
}
