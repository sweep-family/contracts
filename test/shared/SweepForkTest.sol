// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {SweepNFTStrategyFactory} from "../../src/SweepNFTStrategyFactory.sol";
import {SweepNFTStrategy} from "../../src/SweepNFTStrategy.sol";
import {SweepHook} from "../../src/SweepHook.sol";
import {ISweepFactory} from "../../src/interfaces/ISweepFactory.sol";
import {SweepTestCollection} from "../../src/testing/SweepTestCollection.sol";
import {UniswapV4Addresses} from "../../script/config/UniswapV4Addresses.sol";
import {SweepBurnRouter} from "../../src/SweepBurnRouter.sol";
import {SweepSwapRouter} from "../../src/SweepSwapRouter.sol";
import {MockMarketplace} from "../mocks/MockMarketplace.sol";
import {ISweepFactory} from "../../src/interfaces/ISweepFactory.sol";
import {OwnedCollection} from "../mocks/OwnedCollection.sol";
import {OwnerlessERC721} from "../mocks/OwnerlessERC721.sol";

/**
 * @title SweepForkTest
 * @author 0xDAVZER
 * @notice The whole protocol, deployed against the real Uniswap v4 on Robinhood Chain, for every
 * test that needs a pool to exist.
 *
 * @dev A fork rather than a locally deployed stack, deliberately. Everything past the hook that can
 * go wrong goes wrong inside somebody else's contract — the PositionManager's `multicall`, how it
 * pays, where Permit2 is — and a locally deployed copy would prove our encoding matches `lib/`,
 * which is not the question. The question is whether it matches the bytecode on the chain we ship
 * to. Pinned to a block so the fork caches. `ROBINHOOD_RPC_URL` (root `.env` locally, a
 * repository secret in CI) must be an archive endpoint: the public one answers "metadata is not
 * found" for state at the pinned block, so an unset variable is refused by name here rather than
 * failing inside the EVM with an error nobody can read.
 */
abstract contract SweepForkTest is Test {
    error ArchiveRpcRequired();

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 57_000_000;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint160 internal constant HOOK_FLAGS = 0x2444;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    SweepNFTStrategyFactory internal factory;
    SweepHook internal hook;
    SweepTestCollection internal collection;
    SweepBurnRouter internal burnRouter;
    SweepSwapRouter internal sweepRouter;
    MockMarketplace internal market;

    address internal feeTo = makeAddr("feeTo");
    address internal launcher = makeAddr("launcher");
    address internal trader = makeAddr("trader");

    uint256 internal constant LAUNCH_FEE = 0.001 ether;
    uint256 internal constant BID_PER_SECOND = 0.001 ether;
    uint256 internal constant MAX_BID = 5 ether;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) revert ArchiveRpcRequired();
        vm.createSelectFork(rpc, FORK_BLOCK);

        (address poolManager, address positionManager, address permit2) =
            UniswapV4Addresses.forChain(UniswapV4Addresses.ROBINHOOD);
        manager = IPoolManager(poolManager);

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        market = new MockMarketplace();
        vm.prank(launcher);
        collection = new SweepTestCollection("Sweep Test Apes", "STA", "");

        factory = new SweepNFTStrategyFactory(
            positionManager, permit2, poolManager, address(new SweepNFTStrategy()), feeTo, address(this)
        );

        bytes memory args = abi.encode(manager, ISweepFactory(address(factory)), feeTo);
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(SweepHook).creationCode, args);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(SweepHook).creationCode, args));
        require(ok, "hook deployment failed");
        hook = SweepHook(payable(mined));

        factory.setHook(address(hook));

        burnRouter = new SweepBurnRouter(manager, ISweepFactory(address(factory)));
        factory.setBurnRouter(address(burnRouter));

        sweepRouter = new SweepSwapRouter(manager, ISweepFactory(address(factory)));
        factory.setRouter(address(sweepRouter), true);

        vm.deal(launcher, 10 ether);
        vm.deal(trader, 100 ether);
    }

    /* ------------------------------------------------------------------ */
    /*                               helpers                               */
    /* ------------------------------------------------------------------ */

    /**
     * @dev A stranger buying `ethIn` of the token, which is what funds a treasury.
     *
     * This goes through the protocol's own `SweepSwapRouter` rather than v4's `PoolSwapTest`,
     * and that is the whole point rather than a detail. The
     * hook refuses a swap whose caller the factory does not list, and the list is what keeps
     * ERC-6909 claims from existing — so a fixture that listed `PoolSwapTest`, which takes claims
     * on request, would be a fixture whose world is not the one we ship. `swapRouter` is still
     * deployed below and deliberately left off the list: it is the stranger's router that
     * `PoolBypass.t.sol` watches being refused.
     */
    function _buy(PoolKey memory key, uint256 ethIn) internal {
        vm.deal(trader, trader.balance + ethIn);
        vm.prank(trader);
        sweepRouter.buy{value: ethIn}(Currency.unwrap(key.currency1), 0, block.timestamp);
    }

    /// @dev The pool a launched strategy trades on: ETH against the token, at the factory's fee and
    /// spacing, with our hook welded in. Rebuilt rather than stored, because the key is a function
    /// of the strategy and a stored copy is one more thing that can disagree with the chain.
    function _poolKeyFor(address strategy) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(strategy),
            fee: factory.LP_FEE(),
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }

    /// @dev One launch by the collection's owner, and the pool key it produced.
    function _launch() internal returns (address strategy, PoolKey memory key) {
        vm.prank(launcher);
        strategy =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Sweep Test Apes", "sSTA", BID_PER_SECOND, MAX_BID);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(strategy),
            fee: factory.LP_FEE(),
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }

    /// @dev v4 wraps whatever a hook reverts with, so expecting the bare selector would pass on any
    /// revert at all. Rebuilding the wrapper keeps the assertion exact.
    function _expectHookRevert(bytes4 callback, bytes4 inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                abi.encodeWithSelector(inner),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    receive() external payable {}
}
