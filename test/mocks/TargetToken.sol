// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

/**
 * @title TargetToken
 * @author 0xDAVZER
 * @notice A plain ERC-20 with an owner, standing in for the memecoin a strategy buys by the bag.
 */
contract TargetToken is ERC20, Ownable {
    constructor() {
        _initializeOwner(msg.sender);
    }

    function name() public pure override returns (string memory) {
        return "Target";
    }

    function symbol() public pure override returns (string memory) {
        return "TGT";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title OwnerlessTargetToken
 * @notice The same token with no `owner()` at all: what a renounced memecoin looks like to the
 * factory.
 */
contract OwnerlessTargetToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Nobody";
    }

    function symbol() public pure override returns (string memory) {
        return "NOBODY";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title SkimmingToken
 * @notice A fee-on-transfer token: every transfer delivers one percent less than was sent. A bag
 * of it is short, and the desk must notice.
 */
contract SkimmingToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Skim";
    }

    function symbol() public pure override returns (string memory) {
        return "SKIM";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) _burn(to, amount / 100);
    }
}

/**
 * @title LyingToken
 * @notice Returns false from `transfer` instead of reverting, the way a few well-known tokens do.
 * An unchecked `transfer` on a sale would take the buyer's ETH and keep the bag.
 */
contract LyingToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Liar";
    }

    function symbol() public pure override returns (string memory) {
        return "LIE";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}
