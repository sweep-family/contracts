// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";

/**
 * @title FactoryRecursiveTest
 * @author 0xDAVZER
 * @notice Pins the recursive launch on a forked Robinhood Chain: who may launch, what the factory
 * records for a strategy with no target, where the creator tenth goes, that both routers admit
 * the token, and that the airdrop cycle runs on the real pool through the real burn router.
 *
 * @dev Everything the NFT launch already proves about the pool is shared code and is not proved
 * twice. What is new is a strategy the factory knows without a collection behind it.
 */
contract FactoryRecursiveTest is SweepForkTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SweepSwapRouter internal router;
    address internal other = makeAddr("other");

    function setUp() public override {
        super.setUp();
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        router = new SweepSwapRouter(manager, ISweepFactory(address(factory)));
        factory.setRouter(address(router), true);
        vm.deal(other, 100 ether);
    }

    /* ─────────────────────────── the gate ───────────────────────────── */

    /// @notice Anyone may launch, for the fee. There is no target whose owner could consent, and
    /// a token that pays its own holders speaks for nobody but itself.
    function test_AnyoneLaunchesForTheFee() public {
        vm.prank(trader);
        address strategy = factory.launchRecursive{value: LAUNCH_FEE}("Sweep Recursive", "sREC");

        SweepRecursiveStrategy s = SweepRecursiveStrategy(payable(strategy));
        assertTrue(factory.isStrategy(strategy), "the factory does not know its own launch");
        assertEq(s.owner(), address(this), "the launcher must not own it");
        assertEq(s.burnRouter(), address(burnRouter));
        assertEq(s.hook(), address(hook));
        assertEq(s.name(), "Sweep Recursive");
        assertEq(s.symbol(), "sREC");
    }

    /// @notice A strategy with no target has no collection to record: the collection mappings stay
    /// empty, so nothing that reads a strategy's collection mistakes it for an NFT desk, and the
    /// zero address never looks launched. Two recursive launches therefore coexist.
    function test_LaunchRecordsNoCollection() public {
        address first = _launchRecursive();
        vm.prank(other);
        address second = factory.launchRecursive{value: LAUNCH_FEE}("Another", "sANO");

        assertEq(factory.strategyToCollection(first), address(0));
        assertEq(factory.strategyToCollection(second), address(0));
        assertTrue(first != second);
    }

    /// @notice The desks the factory launched before are strategies too, under the same flag.
    function test_EveryKindOfLaunchIsAStrategy() public {
        (address desk,) = _launch();
        address recursive = _launchRecursive();
        assertTrue(factory.isStrategy(desk));
        assertTrue(factory.isStrategy(recursive));
        assertFalse(factory.isStrategy(address(0xBEEF)));
    }

    function test_LaunchRefusesTheWrongFee() public {
        vm.prank(trader);
        vm.expectRevert(SweepNFTStrategyFactory.WrongLaunchFee.selector);
        factory.launchRecursive{value: LAUNCH_FEE - 1}("T", "T");
    }

    /// @notice A factory with its hook and router but no recursive implementation refuses the
    /// launch by name, rather than cloning nothing.
    function test_LaunchRevertsBeforeTheImplementationIsSet() public {
        SweepNFTStrategyFactory fresh = new SweepNFTStrategyFactory(
            address(factory.positionManager()),
            address(factory.permit2()),
            address(manager),
            factory.strategyImplementation(),
            feeTo,
            address(this)
        );
        bytes memory args = abi.encode(manager, ISweepFactory(address(fresh)), feeTo);
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(SweepHook).creationCode, args);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(SweepHook).creationCode, args));
        require(ok, "hook deployment failed");
        fresh.setHook(mined);
        fresh.setBurnRouter(address(new SweepBurnRouter(manager, ISweepFactory(address(fresh)))));

        vm.prank(trader);
        vm.expectRevert(SweepNFTStrategyFactory.RecursiveImplementationNotSet.selector);
        fresh.launchRecursive{value: LAUNCH_FEE}("T", "T");
    }

    function test_RecursiveImplementationCanBeReplacedForFutureLaunches() public {
        address next = address(new SweepRecursiveStrategy());
        factory.setRecursiveImplementation(next);
        assertEq(factory.recursiveImplementation(), next);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setRecursiveImplementation(address(0));

        vm.prank(trader);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setRecursiveImplementation(next);
    }

    /// @notice The event is its own, so an indexer tells the kind apart by signature.
    function test_LaunchEmitsItsOwnEvent() public {
        vm.expectEmit(false, true, false, false, address(factory));
        emit SweepNFTStrategyFactory.RecursiveStrategyLaunched(address(0), trader, "Sweep Recursive", "sREC", 0);
        _launchRecursive();
    }

    /* ─────────────────────────── the pool ───────────────────────────── */

    /// @notice Same pool, same price, same abandoned position as every other launch; and the whole
    /// supply sits with the PoolManager and the dead address, so nobody is eligible yet.
    function test_ThePoolOpensLikeEveryOtherLaunch() public {
        address strategy = _launchRecursive();
        PoolKey memory key = _keyFor(strategy);
        SweepRecursiveStrategy s = SweepRecursiveStrategy(payable(strategy));

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(factory.TICK_UPPER()));
        assertEq(tick, factory.TICK_UPPER());
        IERC721 posm = IERC721(address(factory.positionManager()));
        assertEq(posm.ownerOf(factory.positionIdOf(strategy)), DEAD_ADDRESS);
        assertEq(s.eligibleSupply(), 0, "somebody is eligible before anyone bought");
        assertEq(s.balanceOf(address(factory)), 0, "tokens stayed in the factory");
    }

    /* ────────────────────────── the recipient ───────────────────────── */

    /// @notice The launcher is the creator, and is paid the creator tenth from the first trade.
    function test_TheLauncherIsTheCreatorFeeRecipient() public {
        address strategy = _launchRecursive();
        assertEq(hook.creatorFeeRecipient(strategy), trader);
    }

    /// @notice The launcher fixed at launch is the recipient for good, here as everywhere else.
    /// No kind of strategy has a collection owner who could re-point the share, and the hook
    /// exposes no call that would do it.
    function test_TheCreatorRecipientCannotBeRepointed() public {
        address strategy = _launchRecursive();

        vm.prank(trader);
        (bool ok,) =
            address(hook).call(abi.encodeWithSignature("claimCreatorFeeRecipient(address,address)", strategy, other));

        assertFalse(ok, "the removed claim is still callable");
        assertEq(hook.creatorFeeRecipient(strategy), trader, "the recipient moved");
    }

    /* ─────────────────────────── the routers ────────────────────────── */

    /// @notice The swap router quotes and trades the token: it is a strategy, collection or not.
    function test_TheSwapRouterAdmitsTheToken() public {
        address strategy = _launchRecursive();
        assertGt(router.quote(strategy, true, 1 ether), 0);

        vm.prank(trader);
        uint256 out = router.buy{value: 1 ether}(strategy, 0, block.timestamp);
        assertGt(out, 0);
        assertEq(SweepRecursiveStrategy(payable(strategy)).balanceOf(trader), out);
    }

    /* ───────────────────────── the whole cycle ──────────────────────── */

    /**
     * @notice The cycle on the real pool: two buyers fund the strategy through the hook, the
     * distribution buys the token back through the real burn router into the strategy, and the
     * airdrop lands in both wallets in proportion to what they hold.
     */
    function test_TheAirdropCycleRunsOnTheForkedPool() public {
        address strategyAddr = _launchRecursive();
        SweepRecursiveStrategy strategy = SweepRecursiveStrategy(payable(strategyAddr));
        PoolKey memory key = _keyFor(strategyAddr);

        vm.warp(block.timestamp + 90 minutes);
        _buyAs(key, trader, 2 ether);
        _buyAs(key, other, 1 ether);
        uint256 pending = strategy.pendingRewards();
        assertGt(pending, 0, "the trades funded nothing");
        assertEq(strategy.eligibleSupply(), strategy.balanceOf(trader) + strategy.balanceOf(other));

        strategy.distribute();

        uint256 bought = strategy.balanceOf(strategyAddr);
        assertGt(bought, 0, "the router delivered nothing");
        assertEq(strategy.reserved(), bought);
        assertLt(strategy.pendingRewards(), pending, "the buyback's own fee must be all that is left");

        uint256 owedTrader = strategy.claimable(trader);
        uint256 owedOther = strategy.claimable(other);
        assertApproxEqRel(
            owedTrader * strategy.balanceOf(other), owedOther * strategy.balanceOf(trader), 1e9, "not pro rata"
        );

        address[] memory holders = new address[](2);
        holders[0] = trader;
        holders[1] = other;
        uint256 traderBefore = strategy.balanceOf(trader);
        uint256 otherBefore = strategy.balanceOf(other);
        strategy.claimFor(holders);

        assertEq(strategy.balanceOf(trader), traderBefore + owedTrader);
        assertEq(strategy.balanceOf(other), otherBefore + owedOther);
        assertEq(strategy.claimable(trader), 0);
        assertEq(strategy.claimable(other), 0);
        assertLe(strategy.reserved(), 2, "the desk holds more than the floor's residue");
        assertEq(strategy.balanceOf(strategyAddr), strategy.reserved() + strategy.carry());
        assertEq(address(strategy).balance, strategy.pendingRewards(), "ETH conservation");
    }

    /* ───────────────────────────── helpers ──────────────────────────── */

    function _launchRecursive() private returns (address strategy) {
        vm.prank(trader);
        strategy = factory.launchRecursive{value: LAUNCH_FEE}("Sweep Recursive", "sREC");
    }

    function _buyAs(PoolKey memory key, address who, uint256 ethIn) private {
        vm.prank(who);
        sweepRouter.buy{value: ethIn}(Currency.unwrap(key.currency1), 0, block.timestamp);
    }

    function _keyFor(address strategy) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(strategy),
            fee: factory.LP_FEE(),
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }
}
