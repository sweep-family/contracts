// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {SweepHook} from "../src/SweepHook.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {MockSweepFactory} from "./mocks/MockSweepFactory.sol";

/**
 * @title HookMiningTest
 * @author 0xDAVZER
 * @notice That the deployment step the hook cannot ship without actually works.
 *
 * @dev `SweepHook`'s constructor refuses to run anywhere except an address whose low fourteen bits
 * are `0x2444`, which no ordinary deployment produces. The address therefore has to be searched for
 * before it can be deployed to, and this proves the search and the deployment agree — through the
 * same CREATE2 proxy the deploy script uses, rather than through a cheatcode that would place the
 * code anywhere it was told.
 */
contract HookMiningTest is Test {
    /// @dev Deployed at the same address on every chain, including Robinhood Chain, where its
    /// presence was verified on-chain before this design was committed to.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant FLAGS = 0x2444;

    PoolManager internal manager;
    MockSweepFactory internal factory;
    address internal protocol = makeAddr("protocol");

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new MockSweepFactory(address(this));
    }

    /// @notice The search finds an address that satisfies the constructor, and the constructor
    /// accepts it. Either half alone proves nothing: a salt that mines to the right bits but whose
    /// initcode differs deploys somewhere else entirely.
    function test_MinedSaltDeploysAHookThatValidatesItsOwnAddress() public {
        bytes memory args = abi.encode(IPoolManager(address(manager)), ISweepFactory(address(factory)), protocol);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SweepHook).creationCode, args);

        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(SweepHook).creationCode, args));
        assertTrue(ok, "CREATE2 deployment reverted");

        assertGt(expected.code.length, 0, "nothing landed at the mined address");
        assertEq(uint160(expected) & 0x3FFF, FLAGS, "mined address does not encode the permissions");
        assertEq(address(SweepHook(payable(expected)).factory()), address(factory), "wrong hook at the address");
    }

    /// @notice The salt is a deployment artefact that gets committed, so it has to be reproducible
    /// from the repository alone. Anyone can rerun the search and get the same answer.
    function test_TheSearchIsDeterministic() public view {
        bytes memory args = abi.encode(IPoolManager(address(manager)), ISweepFactory(address(factory)), protocol);
        (address first, bytes32 saltA) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SweepHook).creationCode, args);
        (address second, bytes32 saltB) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SweepHook).creationCode, args);

        assertEq(first, second);
        assertEq(saltA, saltB);
    }

    /// @notice The constructor arguments are part of the initcode and therefore part of the address.
    /// A salt mined against one factory deploys nothing usable against another, which is what makes
    /// a committed salt a checkable claim rather than a number to be trusted.
    function test_ChangingAConstructorArgumentChangesTheAddress() public {
        MockSweepFactory other = new MockSweepFactory(address(this));

        (address a,) = HookMiner.find(
            CREATE2_DEPLOYER,
            FLAGS,
            type(SweepHook).creationCode,
            abi.encode(IPoolManager(address(manager)), ISweepFactory(address(factory)), protocol)
        );
        (address b,) = HookMiner.find(
            CREATE2_DEPLOYER,
            FLAGS,
            type(SweepHook).creationCode,
            abi.encode(IPoolManager(address(manager)), ISweepFactory(address(other)), protocol)
        );

        assertNotEq(a, b);
        assertEq(uint160(a) & 0x3FFF, FLAGS);
        assertEq(uint160(b) & 0x3FFF, FLAGS);
    }
}
