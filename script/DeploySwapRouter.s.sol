// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {UniswapV4Addresses} from "./config/UniswapV4Addresses.sol";

/**
 * @title DeploySwapRouter
 * @author 0xDAVZER
 * @notice Redeploys the swap router against an existing factory.
 *
 * @dev The router is wired into nothing — the factory does not know it, the hook does not know it,
 * the front end simply calls it — so it can be replaced without touching the stack. That is the
 * point of keeping it out of the factory: a router bug is a redeploy and a codegen, not a fresh
 * launch of every strategy.
 */
contract DeploySwapRouter is Script {
    error FactoryHasNoCode(address factory);

    function run() external returns (SweepSwapRouter router) {
        address factory = vm.envAddress("SWEEP_FACTORY");
        if (factory.code.length == 0) revert FactoryHasNoCode(factory);
        (address poolManager,,) = UniswapV4Addresses.forChain(block.chainid);

        vm.startBroadcast();
        router = new SweepSwapRouter(IPoolManager(poolManager), ISweepFactory(factory));
        vm.stopBroadcast();

        console2.log("swap router     ", address(router));
    }
}
