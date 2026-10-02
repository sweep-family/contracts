// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockFeeHook
 * @author 0xDAVZER
 * @notice Answers `protocolFeeRecipient()` the way `SweepHook` does, which is the only thing the
 * curve ever asks a hook.
 */
contract MockFeeHook {
    address public protocolFeeRecipient;

    constructor(address recipient) {
        protocolFeeRecipient = recipient;
    }

    function setProtocolFeeRecipient(address recipient) external {
        protocolFeeRecipient = recipient;
    }
}

/**
 * @title RejectingSink
 * @author 0xDAVZER
 * @notice Reverts on any plain ETH receive. Stands in for a fee recipient that cannot be paid,
 * which must never be able to block a sweep or a graduation.
 */
contract RejectingSink {
    error NoThankYou();

    receive() external payable {
        revert NoThankYou();
    }
}

/**
 * @title ReenteringRecipient
 * @author 0xDAVZER
 * @notice A creator fee recipient that tries to buy from inside the graduation sweep's payment.
 * The attempt must bounce off the already-set `graduated` flag — the recorded revert data is how
 * the test tells "refused by the flag" from "refused by gas". The receive swallows the failure so
 * the sweep completes, and disarms itself so a refund cannot recurse.
 */
contract ReenteringRecipient {
    ICurveLike public curve;
    bool public attempted;
    bool public observedGraduated;
    bytes public buyRevertReason;

    function arm(ICurveLike curve_) external {
        curve = curve_;
    }

    receive() external payable {
        if (address(curve) == address(0)) return;
        ICurveLike target = curve;
        curve = ICurveLike(address(0));
        attempted = true;
        observedGraduated = target.graduated();
        try target.buy{value: 1}(0, address(this)) {}
        catch (bytes memory reason) {
            buyRevertReason = reason;
        }
    }
}

/**
 * @title GasEater
 * @author 0xDAVZER
 * @notice Burns every drop of gas any payment forwards it. As a fee recipient it is what makes
 * graduation expensive enough to starve under the 63/64 rule — the force-send burns its whole
 * stipend and falls back to the selfdestruct delivery — which is the adversarial shape the
 * auto-graduation try/catch exists for.
 */
contract GasEater {
    receive() external payable {
        while (true) {
            assembly {
                pop(keccak256(0, 32))
            }
        }
    }
}

/**
 * @title Donor
 * @author 0xDAVZER
 * @notice Force-feeds ETH to a target through `selfdestruct`, which no `receive` can refuse.
 * Exists to prove a donation cannot move the curve's price.
 */
contract Donor {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

interface ICurveLike {
    function buy(uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minEthOut, address recipient) external returns (uint256);
    function graduated() external view returns (bool);
}
