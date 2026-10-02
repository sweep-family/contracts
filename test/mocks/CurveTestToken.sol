// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

/**
 * @title CurveTestToken
 * @author 0xDAVZER
 * @notice A plain mintable ERC-20 standing in for a strategy token in the curve's unit tests.
 *
 * @dev No transfer lock: the lock's interaction with the curve (distributor status at init) is
 * the token's property and is pinned in `StrategyBase.t.sol` against the real `SweepToken`. Here the token only has
 * to move, answer `hook()`, and record `markGraduated` so the tests can assert who called it and
 * how often.
 */
contract CurveTestToken is ERC20 {
    address public hook;
    uint256 public markGraduatedCalls;
    address public lastGraduationCaller;

    constructor(address hook_) {
        hook = hook_;
    }

    function name() public pure override returns (string memory) {
        return "Curve Test Token";
    }

    function symbol() public pure override returns (string memory) {
        return "CTT";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function markGraduated() external {
        markGraduatedCalls += 1;
        lastGraduationCaller = msg.sender;
    }
}
