// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {UniswapV4Addresses} from "./config/UniswapV4Addresses.sol";

/**
 * @title DeploySweep
 * @author 0xDAVZER
 * @notice The whole protocol, in the only order it can be deployed in.
 *
 * @dev The factory and the hook depend on each other and neither can be built first. The hook's
 * address is not free — it has to encode its permissions, so it comes from a salt mined over an
 * initcode that already contains the factory's address. That settles the direction: the factory is
 * built first with no hook, the hook is mined against it, and the factory is told once.
 *
 * @dev `setHook` accepts one call and never another, so this script is not rerunnable against a
 * factory that already has one. That is the intent — every strategy already launched has that hook
 * welded into the identity of the pool it trades on.
 *
 * @dev The two routers are admitted to the factory's swap allow-list here, and they are the only
 * two a deploy ever adds. The hook refuses a swap whose caller is not on that list, which is what
 * keeps ERC-6909 claims on a strategy's token from ever existing —
 * both of these settle in ERC-20 and consume the hook's transient allowance exactly. The burn
 * router is added by `setBurnRouter` itself; the swap router is added by name. Anything else added
 * later is an owner decision to be read as carefully as a `setDistributor`.
 *
 * @dev Run with `--slow`. Each step here depends on the receipt of the one before, and `forge
 * script` does not wait for receipts otherwise, and a step sent before its predecessor lands fails.
 */
contract DeploySweep is Script {
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error MinedAddressMismatch(address expected, address actual);

    /**
     * @notice Deploys the implementation, the factory and the hook, and wires them together.
     *
     * @dev `SWEEP_FEE_RECIPIENT` receives both the launch fee and the protocol's tenth of every
     * trading fee. `SWEEP_OWNER` owns the factory and, through it, every strategy it launches.
     *
     * @dev The burn router is deployed after the hook because it reads the hook off the factory,
     * and set on the factory before any launch because a strategy holds its router from birth. The
     * swap router is the wallet's road onto the pool; it is not wired into anything, the front end
     * simply calls it. `SWEEP_LAUNCH_FEE` overrides the factory's default, which a testnet with a
     * thin faucet has reason to; it is only applied when the deployer is the owner, since the
     * setter is theirs.
     */
    function run()
        external
        returns (
            SweepNFTStrategyFactory factory,
            SweepHook hook,
            SweepBurnRouter burnRouter,
            SweepSwapRouter swapRouter,
            address implementation
        )
    {
        address feeRecipient = vm.envAddress("SWEEP_FEE_RECIPIENT");
        address owner = vm.envAddress("SWEEP_OWNER");
        uint256 launchFee = vm.envOr("SWEEP_LAUNCH_FEE", uint256(0.001 ether));

        (address poolManager, address positionManager, address permit2) = UniswapV4Addresses.forChain(block.chainid);

        vm.startBroadcast();

        implementation = address(new SweepNFTStrategy());
        factory =
            new SweepNFTStrategyFactory(positionManager, permit2, poolManager, implementation, feeRecipient, owner);

        bytes memory args = abi.encode(IPoolManager(poolManager), ISweepFactory(address(factory)), feeRecipient);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SweepHook).creationCode, args);

        hook = new SweepHook{salt: salt}(IPoolManager(poolManager), ISweepFactory(address(factory)), feeRecipient);
        if (address(hook) != expected) revert MinedAddressMismatch(expected, address(hook));

        factory.setHook(address(hook));

        burnRouter = new SweepBurnRouter(IPoolManager(poolManager), ISweepFactory(address(factory)));
        factory.setBurnRouter(address(burnRouter));
        swapRouter = new SweepSwapRouter(IPoolManager(poolManager), ISweepFactory(address(factory)));
        factory.setRouter(address(swapRouter), true);
        factory.setERC20Implementation(address(new SweepERC20Strategy()));
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        if (launchFee != factory.launchFee()) factory.setLaunchFee(launchFee, feeRecipient);

        vm.stopBroadcast();

        console2.log("chain           ", block.chainid);
        console2.log("implementation  ", implementation);
        console2.log("erc20 impl      ", factory.erc20Implementation());
        console2.log("recursive impl  ", factory.recursiveImplementation());
        console2.log("factory         ", address(factory));
        console2.log("hook            ", address(hook));
        console2.log("hook flag bits  ", uint160(address(hook)) & 0x3FFF);
        console2.log("burn router     ", address(burnRouter));
        console2.log("swap router     ", address(swapRouter));
        console2.log("routers allowed ", factory.isRouter(address(swapRouter)) && factory.isRouter(address(burnRouter)));
        console2.log("launch fee wei  ", factory.launchFee());
        console2.logBytes32(salt);
    }
}
