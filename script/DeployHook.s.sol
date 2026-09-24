// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {SweepHook} from "../src/SweepHook.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {UniswapV4Addresses} from "./config/UniswapV4Addresses.sol";

/**
 * @title DeployHook
 * @author 0xDAVZER
 * @notice Mines a CREATE2 salt that lands `SweepHook` on an address encoding its permissions, and
 * deploys it there.
 *
 * @dev Uniswap v4 reads a hook's callbacks from the low fourteen bits of its own address, so this
 * contract cannot be deployed by an ordinary `new`: its constructor checks the address it is running
 * at and reverts on anything else. The search is a few thousand `keccak256`s and runs off-chain.
 *
 * @dev Foundry routes a salted `new` inside a broadcast through the canonical CREATE2 proxy at
 * `0x4e59b44847b379578588920cA78FbF26c0B4956C`, which is why the search uses that as the deployer
 * rather than the sender. Its presence on Robinhood Chain was verified on-chain before this design
 * was committed to.
 *
 * @dev The printed salt is a deployment artefact and belongs in the environment's record. Anyone
 * can rerun this and confirm it, because the same initcode and the same arguments produce the same
 * address — which is also why the factory address cannot be corrected later without moving the hook.
 */
contract DeployHook is Script {
    /// @notice The hook wants `beforeInitialize`, `afterAddLiquidity`, `afterSwap` and a delta on
    /// `afterSwap`. Derived rather than written as `0x2444` so a change to `getHookPermissions`
    /// cannot leave the script mining for the old shape.
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The factory address given is not a contract.
    error FactoryHasNoCode(address factory);
    /// @notice The deployment did not land where the search said it would.
    error MinedAddressMismatch(address expected, address actual);

    /**
     * @notice Deploys the hook for the factory named by `SWEEP_FACTORY`.
     *
     * @dev `FactoryHasNoCode` is the guard worth having. The factory is immutable on the hook and is
     * baked into the address the salt was mined for, so pointing at a typo produces a hook that is
     * permanently unable to open a pool and cannot be corrected without deploying a different one at
     * a different address. Every other mistake here is recoverable; this one is not.
     *
     * @dev `MinedAddressMismatch` catches the broadcast having gone through something other than the
     * CREATE2 proxy the salt was mined against, which would otherwise surface much later as a pool
     * that silently never calls its hook.
     */
    function run() external returns (SweepHook hook, bytes32 salt) {
        address factory = vm.envAddress("SWEEP_FACTORY");
        address protocolFeeRecipient = vm.envAddress("SWEEP_PROTOCOL_FEE_RECIPIENT");
        (address poolManager,,) = UniswapV4Addresses.forChain(block.chainid);

        if (factory.code.length == 0) revert FactoryHasNoCode(factory);

        bytes memory args = abi.encode(IPoolManager(poolManager), ISweepFactory(factory), protocolFeeRecipient);
        (address expected, bytes32 found) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SweepHook).creationCode, args);
        salt = found;

        vm.startBroadcast();
        hook = new SweepHook{salt: salt}(IPoolManager(poolManager), ISweepFactory(factory), protocolFeeRecipient);
        vm.stopBroadcast();

        if (address(hook) != expected) revert MinedAddressMismatch(expected, address(hook));

        console2.log("chain            ", block.chainid);
        console2.log("poolManager      ", poolManager);
        console2.log("factory          ", factory);
        console2.log("protocolFeeTo    ", protocolFeeRecipient);
        console2.log("hook             ", address(hook));
        console2.log("permissions bits ", uint160(address(hook)) & 0x3FFF);
        console2.logBytes32(salt);
    }
}
