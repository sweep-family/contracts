// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISweepFactory} from "../../src/interfaces/ISweepFactory.sol";

/**
 * @title MockSweepFactory
 * @author 0xDAVZER
 * @notice Stands where `SweepNFTStrategyFactory` will, so the hook can be proven before it exists.
 *
 * @dev The hook asks the factory a handful of questions and trusts every answer, which is the
 * whole reason this mock is useful: a test can answer them the way a hostile or misconfigured
 * factory would and watch the hook refuse. `loadingLiquidity` in particular is the single gate on
 * pool creation, so a test that can lie about it is a test that can prove the gate exists.
 */
contract MockSweepFactory is ISweepFactory {
    bool public loadingLiquidity;
    address public owner;
    address public hook;

    mapping(address strategy => address collection) public strategyToCollection;
    mapping(address token => bool launched) public isStrategy;
    mapping(address router => bool allowed) public isRouter;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Pretends a launch is or is not in progress.
    function setLoadingLiquidity(bool loading) external {
        loadingLiquidity = loading;
    }

    /// @notice Registers which collection a strategy sweeps, as a real launch would, and that
    /// the strategy exists at all.
    function setStrategyCollection(address strategy, address collection) external {
        strategyToCollection[strategy] = collection;
        isStrategy[strategy] = true;
    }

    /// @notice Registers a strategy that sweeps nothing, as a recursive launch would.
    function setStrategy(address strategy, bool launched) external {
        isStrategy[strategy] = launched;
    }

    /// @notice Admits a router to the set allowed to swap, as `setRouter` would. A hook test that
    /// forgets this watches every swap revert `RouterNotAllowed`, which is the gate working.
    function setRouter(address router, bool allowed) external {
        isRouter[router] = allowed;
    }

    /// @notice Names the hook, as `setHook` would.
    function setHook(address hook_) external {
        hook = hook_;
    }

    /// @notice Hands the factory to somebody else, so the hook's owner gate can be watched failing.
    function setOwner(address owner_) external {
        owner = owner_;
    }
}
