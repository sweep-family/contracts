// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {OwnedCollection} from "./mocks/OwnedCollection.sol";
import {OwnerlessERC721} from "./mocks/OwnerlessERC721.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";

/**
 * @title FactoryTest
 * @author 0xDAVZER
 * @notice The factory, against the real Uniswap v4 on Robinhood Chain. The fixture is `SweepForkTest`.
 */
contract FactoryTest is SweepForkTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal creator = makeAddr("creator");

    /// @dev `StrategyLaunched`'s signature, which the `verified` flag is part of. Spelled out
    /// rather than derived from the ABI so that changing the event has to be a deliberate act here
    /// too, where an indexer would break.
    bytes32 internal constant LAUNCHED_TOPIC =
        keccak256("StrategyLaunched(address,address,address,string,string,uint256,bool)");

    /* ------------------------------------------------------------------ */
    /*                         the pool that gets born                     */
    /* ------------------------------------------------------------------ */

    /// @notice The pool opens where the factory said it would, on the real PoolManager. If the
    /// encoding of the multicall were wrong this is the first thing that would be silently off.
    function test_LaunchCreatesAPoolAtTheIntendedPrice() public {
        (address strategy, PoolKey memory key) = _launch();

        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(factory.TICK_UPPER()), "pool opened at the wrong price");
        assertEq(tick, factory.TICK_UPPER(), "pool did not open at the top of the range");
        assertEq(Currency.unwrap(key.currency1), strategy);
        assertEq(Currency.unwrap(key.currency0), address(0));
    }

    /// @notice The liquidity is abandoned into the pool, not provided to it. Nobody holds the
    /// position — not the launcher, not the collection, not us — so the curve cannot be pulled.
    function test_LaunchMintsThePositionToTheDeadAddress() public {
        (address strategy,) = _launch();

        IERC721 posm = IERC721(address(factory.positionManager()));
        uint256 tokenId = factory.positionIdOf(strategy);
        assertEq(posm.ownerOf(tokenId), DEAD_ADDRESS, "somebody owns the bonding curve");
    }

    /// @notice The point of opening at the top of the range: the position holds only tokens, so a
    /// market opens with no capital at all. A launch costs the fee and nothing else.
    function test_LaunchCostsNothingBeyondTheFee() public {
        uint256 before = launcher.balance;
        _launch();
        assertEq(launcher.balance, before - LAUNCH_FEE, "the launch consumed ETH beyond the fee");
    }

    /// @notice Liquidity rounds down, so a few wei never enter the position. Left in the factory
    /// they would be stranded forever, and the transfer lock means they could not even be moved.
    function test_LaunchLeavesNoTokensInTheFactory() public {
        (address strategy,) = _launch();
        assertEq(SweepNFTStrategy(payable(strategy)).balanceOf(address(factory)), 0, "dust stranded in the factory");
    }

    /// @notice No team allocation, no treasury allocation, no vesting. Everything that exists is in
    /// the pool or already burnt, and this is the assertion that says so.
    function test_LaunchMintsTheWholeSupplyIntoThePool() public {
        (address strategy,) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));

        uint256 inPool = s.balanceOf(address(manager));
        uint256 burnt = s.balanceOf(DEAD_ADDRESS);

        assertEq(s.totalSupply(), s.MAX_SUPPLY());
        assertEq(inPool + burnt, s.MAX_SUPPLY(), "supply exists somewhere other than the pool");
        assertEq(s.balanceOf(launcher), 0, "the launcher kept some");
    }

    /* ------------------------------------------------------------------ */
    /*                    what launching does and does not grant           */
    /* ------------------------------------------------------------------ */

    /// @notice The launcher owns the collection, not the strategy. The owner's setters are power over
    /// a contract that will hold the token holders' money — the bid ceiling, the distributor list —
    /// and none of it belongs to the collection.
    function test_StrategyIsOwnedByTheFactoryOwnerNotTheLauncher() public {
        (address strategy,) = _launch();
        assertEq(SweepNFTStrategy(payable(strategy)).owner(), factory.owner());
        assertTrue(SweepNFTStrategy(payable(strategy)).owner() != launcher);
    }

    /// @notice A launch records what the strategy buys, and the routers record that it exists.
    /// @dev There is no reverse mapping: a collection may carry any number of
    /// strategies, so `collection => strategy` could only ever answer for one of them. What needs
    /// the strategies of a collection reads the launch events.
    function test_LaunchRecordsWhatTheStrategyBuys() public {
        (address strategy,) = _launch();
        assertEq(factory.strategyToCollection(strategy), address(collection));
        assertTrue(factory.isStrategy(strategy));
    }

    /* ------------------------------------------------------------------ */
    /*                              the guards                             */
    /* ------------------------------------------------------------------ */

    /// @notice The strategy calls `ownerOf` and `transferFrom` on this address for the rest of its
    /// life. A launch against something that is not an ERC-721 produces a strategy that can never
    /// buy anything, and the fee has already been taken by then.
    function test_LaunchRefusesAContractThatIsNotERC721() public {
        OwnedCollection ownedButNotACollection = new OwnedCollection(launcher);
        vm.prank(launcher);
        vm.expectRevert(SweepNFTStrategyFactory.NotERC721.selector);
        factory.launch{value: LAUNCH_FEE}(address(ownedButNotACollection), "Nope", "NOPE", BID_PER_SECOND, MAX_BID);
    }

    /**
     * @notice A collection may carry as many strategies as anyone cares to launch. Each is its own
     * token, its own treasury and its own shelf; they share only the collection they buy from.
     *
     * @dev They do compete, and that cost is taken on knowingly: two desks publish a climbing bid
     * on the same floor and each purchase makes the next one dearer for the other. What it buys is
     * that there is no slot: nobody is locked out of a collection, so there is nothing to race for
     * and a stranger's launch takes nothing away from the collection itself.
     */
    function test_ACollectionMayCarryManyStrategies() public {
        (address first,) = _launch();

        vm.prank(trader);
        address second =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Again", "AGAIN", BID_PER_SECOND, MAX_BID);

        assertTrue(second != first && second != address(0), "the second launch produced nothing new");
        assertEq(factory.strategyToCollection(first), address(collection));
        assertEq(factory.strategyToCollection(second), address(collection));
        assertTrue(factory.isStrategy(first) && factory.isStrategy(second));
        assertEq(SweepNFTStrategy(payable(second)).owner(), address(this), "a second launch grants power");
    }

    /// @notice And both of them trade, independently. A second strategy is a second market, not a
    /// second claim on the first one's pool: each opens its own, at its own opening price.
    function test_TwoStrategiesOnOneCollectionEachFundTheirOwnTreasury() public {
        (address first, PoolKey memory firstKey) = _launch();
        vm.prank(trader);
        address second =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Again", "AGAIN", BID_PER_SECOND, MAX_BID);

        _buy(firstKey, 1 ether);
        _buy(_poolKeyFor(second), 1 ether);

        assertGt(SweepNFTStrategy(payable(first)).treasury(), 0, "the first took nothing");
        assertGt(SweepNFTStrategy(payable(second)).treasury(), 0, "the second took nothing");
    }

    /// @notice Exact, in both directions. Under-paying is obvious; over-paying matters because the
    /// surplus would otherwise sit in a contract with no way to return it.
    function test_LaunchRefusesTheWrongFee() public {
        vm.startPrank(launcher);

        vm.expectRevert(SweepNFTStrategyFactory.WrongLaunchFee.selector);
        factory.launch{value: LAUNCH_FEE - 1}(address(collection), "A", "A", BID_PER_SECOND, MAX_BID);

        vm.expectRevert(SweepNFTStrategyFactory.WrongLaunchFee.selector);
        factory.launch{value: LAUNCH_FEE + 1}(address(collection), "A", "A", BID_PER_SECOND, MAX_BID);

        vm.stopPrank();
    }

    /// @notice A launcher who is a stranger can still ship a strategy that never works: a bid ramp
    /// so slow it never reaches a floor price, or so fast the auction resolves inside one block and
    /// stops discovering anything. Both ends are refused at launch rather than discovered later.
    /// @dev The bounds are read into locals first. `vm.expectRevert` arms the very next external
    /// call, and reading a public constant is one — which consumes the expectation and fails the
    /// test on the wrong line. This is the third time that trap has been hit in this repository.
    function test_LaunchRefusesBidParametersOutOfRange() public {
        uint256 tooSlow = factory.MIN_BID_INCREASE_PER_SECOND() - 1;
        uint256 tooFast = factory.MAX_BID_INCREASE_PER_SECOND() + 1;
        uint256 tooHigh = factory.MAX_BID_CAP() + 1;

        vm.startPrank(launcher);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launch{value: LAUNCH_FEE}(address(collection), "A", "A", tooSlow, MAX_BID);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launch{value: LAUNCH_FEE}(address(collection), "A", "A", tooFast, MAX_BID);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launch{value: LAUNCH_FEE}(address(collection), "A", "A", BID_PER_SECOND, tooHigh);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launch{value: LAUNCH_FEE}(address(collection), "A", "A", BID_PER_SECOND, 0);

        vm.stopPrank();
    }

    /// @notice Without a hook the pool has no toll booth, so the treasury would never be funded and
    /// the token would trade freely with no fee — permanently, since the hook is part of the pool's
    /// identity and cannot be added afterwards.
    function test_LaunchRevertsBeforeTheHookIsSet() public {
        SweepNFTStrategyFactory fresh = new SweepNFTStrategyFactory(
            address(factory.positionManager()),
            address(factory.permit2()),
            address(manager),
            address(new SweepNFTStrategy()),
            feeTo,
            address(this)
        );
        fresh.setBurnRouter(address(burnRouter));

        vm.prank(launcher);
        vm.expectRevert(SweepNFTStrategyFactory.HookNotSet.selector);
        fresh.launch{value: LAUNCH_FEE}(address(collection), "A", "A", BID_PER_SECOND, MAX_BID);
    }

    /// @notice Every strategy already launched has this hook baked into its pool's identity and into
    /// its own `hook` field. Repointing the factory would leave them referring to a hook that no
    /// longer receives their fees, with no way to move them.
    function test_SetHookOnlyWorksOnce() public {
        vm.expectRevert(SweepNFTStrategyFactory.HookAlreadySet.selector);
        factory.setHook(address(0xBEEF));
    }

    /// @notice The flag is the hook's only gate on pool creation and on deposits. If it survived a
    /// launch, anyone could open a Sweep pool or add a second position to an existing one.
    function test_LoadingLiquidityIsFalseOutsideALaunch() public {
        assertFalse(factory.loadingLiquidity(), "raised before any launch");
        _launch();
        assertFalse(factory.loadingLiquidity(), "left raised after a launch");
    }

    /// @notice The position stays singular. A second one would be liquidity somebody can still
    /// remove, and the curve would stop being a one-way street.
    function test_NobodyCanAddLiquidityAfterALaunch() public {
        (address strategy, PoolKey memory key) = _launch();

        strategy;
        _expectHookRevert(IHooks.afterAddLiquidity.selector, SweepHook.NotLaunching.selector);
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e15, salt: bytes32(0)}),
            ""
        );
    }

    /* ------------------------------------------------------------------ */
    /*                        the fee, and the whole machine               */
    /* ------------------------------------------------------------------ */

    /// @notice The launch fee is forwarded rather than accumulated, so the factory never holds ETH
    /// it might be asked to account for.
    function test_LaunchFeeReachesTheRecipient() public {
        uint256 before = feeTo.balance;
        _launch();
        assertEq(feeTo.balance, before + LAUNCH_FEE);
        assertEq(address(factory).balance, 0, "the factory kept the fee");
    }

    /// @notice Everything at once, on the real chain: a pool that did not exist a moment ago takes
    /// a stranger's ETH, the hook skims it, and the strategy's treasury can now bid for an NFT.
    /// This is the assertion everything below the factory was built for.
    function test_TheLaunchedPoolCanBeTradedAndFundsTheTreasury() public {
        (address strategy, PoolKey memory key) = _launch();
        SweepNFTStrategy s = SweepNFTStrategy(payable(strategy));

        assertEq(s.treasury(), 0, "funded before anyone traded");

        vm.prank(trader);
        sweepRouter.buy{value: 1 ether}(strategy, 0, block.timestamp);

        assertGt(s.treasury(), 0, "the trade funded nothing");
        assertGt(s.balanceOf(trader), 0, "the trader received no tokens");

        assertEq(s.currentBid(), 0, "the bid ramp did not start from nothing");
        vm.warp(block.timestamp + 10 minutes);
        assertGt(s.currentBid(), 0, "the desk still cannot bid after waiting");
    }

    /* ------------------------------------------------------------------ */
    /*                  who may launch, and who is vouched for             */
    /* ------------------------------------------------------------------ */

    /// @notice Anyone launches, on any collection. An owner gate would exclude every collection
    /// whose `owner()` is renounced, cold or lost — which is most of the ones worth sweeping — and
    /// would not be the protection it looks like, since ownership of a collection says nothing
    /// about who should run a desk on it. What a launcher gets is the creator share
    /// and the name. What a launcher does not get, unless the collection says so, is the badge.
    function test_AnyoneCanLaunchOnACollectionTheyDoNotOwn() public {
        vm.prank(trader);
        address strategy =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Squat", "SQUAT", BID_PER_SECOND, MAX_BID);

        assertEq(factory.strategyToCollection(strategy), address(collection), "the launch was not recorded");
        assertEq(hook.creatorFeeRecipient(strategy), trader, "the launcher is not the creator recipient");
    }

    /// @notice `owner()` is not part of ERC-721. A collection without one is not a collection nobody
    /// may launch, which is what the gate made it; it is a collection nobody can be vouched for on.
    /// It launches from a plain wallet, unverified, without passing through us.
    function test_ACollectionWithNoOwnerAccessorCanBeLaunchedFromAWallet() public {
        OwnerlessERC721 punks = new OwnerlessERC721();

        vm.recordLogs();
        vm.prank(trader);
        address strategy = factory.launch{value: LAUNCH_FEE}(address(punks), "Punks", "sPUNK", BID_PER_SECOND, MAX_BID);

        assertEq(factory.strategyToCollection(strategy), address(punks), "the launch was not recorded");
        assertFalse(_launchWasVerified(), "a collection with no owner vouched for somebody");
    }

    /// @notice The badge, and the whole of it: at this block, this collection's own contract named
    /// this launcher as its owner. The factory writes it into the launch event and keeps no copy,
    /// because the fact is dated — a stored copy would be a fact that looks current and is not.
    function test_TheOwnersLaunchIsMarkedVerified() public {
        vm.recordLogs();
        _launch();

        assertTrue(_launchWasVerified(), "the owner's own launch was not marked verified");
    }

    /// @notice And a stranger's launch is not. This is the entire difference the removed gate
    /// leaves behind: not who may launch, only who the launch is attributed to.
    function test_AStrangersLaunchIsNotVerified() public {
        vm.recordLogs();
        vm.prank(trader);
        factory.launch{value: LAUNCH_FEE}(address(collection), "Squat", "SQUAT", BID_PER_SECOND, MAX_BID);

        assertFalse(_launchWasVerified(), "a stranger was vouched for");
    }

    /// @notice The badge is dated, not current. A collection that changes hands after a launch takes
    /// nothing with it and gains nothing: the new owner does not inherit the badge, and cannot take
    /// the creator share from the launcher either. There is no on-chain path from owning a
    /// collection to its strategy, which is why no owner claim exists.
    function test_ACollectionSoldAfterLaunchKeepsItsBadgeAndItsRecipient() public {
        (address strategy,) = _launch();

        vm.prank(launcher);
        collection.transferOwnership(trader);

        assertEq(collection.owner(), trader, "the collection did not change hands");
        assertEq(hook.creatorFeeRecipient(strategy), launcher, "the new owner took the creator share");
    }

    /// @notice Launching is not owning. The strategy's owner — the address holding the setters over
    /// money that belongs to the token's holders — is this factory's owner whoever launched, and a
    /// stranger launching changes nothing about that.
    function test_TheStrategysOwnerIsStillTheFactoryOwnerWhenAStrangerLaunches() public {
        vm.prank(trader);
        address strategy =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Squat", "SQUAT", BID_PER_SECOND, MAX_BID);

        assertEq(SweepNFTStrategy(payable(strategy)).owner(), address(this), "a stranger got the setters");
    }

    /// @notice `ownerLaunch` survives the gate's removal for the one thing `launch` cannot do: name
    /// a recipient other than the caller, for a collection whose owner was established off-chain.
    /// It is never verified, and needs no special case to not be — we are not the collection's
    /// owner, so the one rule already answers.
    function test_OwnerLaunchNamesAnExplicitRecipientAndIsNeverVerified() public {
        OwnerlessERC721 punks = new OwnerlessERC721();
        vm.deal(address(this), 1 ether);

        vm.recordLogs();
        address strategy =
            factory.ownerLaunch{value: LAUNCH_FEE}(address(punks), "Punks", "sPUNK", BID_PER_SECOND, MAX_BID, creator);

        assertEq(factory.strategyToCollection(strategy), address(punks));
        assertEq(SweepNFTStrategy(payable(strategy)).owner(), address(this));
        assertEq(hook.creatorFeeRecipient(strategy), creator, "the explicit recipient was not registered");
        assertFalse(_launchWasVerified(), "ownerLaunch vouched for itself");
    }

    /// @notice `ownerLaunch` is `onlyOwner`, and that is the only thing it is: it skips no gate,
    /// because there is no gate. Also: the same fee applies to us.
    function test_OwnerLaunchIsOnlyForTheFactoryOwnerAndStillChargesTheFee() public {
        vm.prank(trader);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.ownerLaunch{value: LAUNCH_FEE}(address(collection), "A", "A", BID_PER_SECOND, MAX_BID, creator);

        vm.expectRevert(SweepNFTStrategyFactory.WrongLaunchFee.selector);
        factory.ownerLaunch(address(collection), "A", "A", BID_PER_SECOND, MAX_BID, creator);
    }

    /// @notice The collection is paid from its first trade with nothing further to sign. The
    /// launcher is registered with the hook inside the launch, rather than in a second transaction
    /// the collection would have to know to send.
    function test_LaunchRegistersTheLauncherAsTheCreatorFeeRecipient() public {
        (address strategy, PoolKey memory key) = _launch();
        assertEq(hook.creatorFeeRecipient(strategy), launcher, "the launcher was not registered");

        vm.warp(block.timestamp + 90 minutes);
        _buy(key, 1 ether);
        assertGt(hook.accruedFees(launcher), 0, "the collection earned nothing from the first trade");
    }

    /// @notice A zero recipient on `ownerLaunch` leaves the share unclaimed rather than registering
    /// the zero address, so it falls through to the protocol as it always has.
    function test_OwnerLaunchWithNoRecipientLeavesTheShareUnclaimed() public {
        OwnerlessERC721 punks = new OwnerlessERC721();
        vm.deal(address(this), 1 ether);
        address strategy = factory.ownerLaunch{value: LAUNCH_FEE}(
            address(punks), "Punks", "sPUNK", BID_PER_SECOND, MAX_BID, address(0)
        );
        assertEq(hook.creatorFeeRecipient(strategy), address(0));
    }

    /// @notice The recipient is written once, by the factory, and has no second writer. There is no
    /// `claimCreatorFeeRecipient`: a claim that redirects a live revenue
    /// stream on the strength of `owner()` is the same attack surface whichever way it points, and
    /// the stream it would have taken belongs to whoever paid the fee and opened the market.
    function test_TheCreatorRecipientHasNoSecondWriter() public {
        (address strategy,) = _launch();

        vm.prank(trader);
        vm.expectRevert(SweepHook.NotFactory.selector);
        hook.registerCreatorFeeRecipient(strategy, trader);

        vm.prank(launcher);
        (bool ok,) =
            address(hook).call(abi.encodeWithSignature("claimCreatorFeeRecipient(address,address)", strategy, trader));

        assertFalse(ok, "the removed claim is still callable");
        assertEq(hook.creatorFeeRecipient(strategy), launcher, "the recipient moved");
    }

    /// @dev The badge as the chain records it. The factory emits it and stores nothing, so the log
    /// is the only place it exists — a test reading it back from a getter would be testing a getter
    /// we deliberately do not have.
    function _launchWasVerified() private returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == LAUNCHED_TOPIC) {
                (,,, bool verified) = abi.decode(logs[i].data, (string, string, uint256, bool));
                return verified;
            }
        }
        revert("no StrategyLaunched event");
    }

    /* ------------------------------------------------------------------ */
    /*                            the retuning levers                      */
    /* ------------------------------------------------------------------ */

    /// @notice The launch fee is a fixed amount of ETH, so it drifts against the dollar exactly as
    /// pump.fun's fixed 0.02 SOL does. It is settable so the drift can be corrected. Zero is a
    /// legitimate setting — a free launch is a decision, not a misconfiguration — but a zero
    /// recipient is not, because every fee routed there would be unrecoverable.
    function test_LaunchFeeAndRecipientCanBeRetuned() public {
        address newFeeTo = makeAddr("newFeeTo");
        factory.setLaunchFee(0, newFeeTo);
        assertEq(factory.launchFee(), 0);
        assertEq(factory.launchFeeRecipient(), newFeeTo);

        vm.prank(launcher);
        factory.launch(address(collection), "Free", "FREE", BID_PER_SECOND, MAX_BID);
        assertEq(newFeeTo.balance, 0, "a fee was paid on a free launch");

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setLaunchFee(1 ether, address(0));
    }

    /// @notice The markup is a factory default rather than a launch parameter, so retuning it is
    /// how the judgement changes for future collections. Existing strategies keep what they were
    /// initialised with, which is why this is not a way to reprice inventory already on a shelf.
    function test_ResaleMultiplierAppliesToFutureLaunchesOnly() public {
        (address before,) = _launch();
        uint256 wasSetTo = SweepNFTStrategy(payable(before)).resaleMultiplierBps();

        factory.setResaleMultiplier(20_000);

        vm.startPrank(launcher);
        SweepTestCollection second = new SweepTestCollection("Second", "SND", "");
        address after_ = factory.launch{value: LAUNCH_FEE}(address(second), "Second", "sSND", BID_PER_SECOND, MAX_BID);
        vm.stopPrank();

        assertEq(SweepNFTStrategy(payable(before)).resaleMultiplierBps(), wasSetTo, "an existing strategy moved");
        assertEq(SweepNFTStrategy(payable(after_)).resaleMultiplierBps(), 20_000);
    }

    /// @notice A proxy stores the implementation it was cloned against, so changing this decides
    /// what the next launch gets and never what an existing strategy runs.
    function test_StrategyImplementationCanBeReplacedForFutureLaunches() public {
        address next = address(new SweepNFTStrategy());
        factory.setStrategyImplementation(next);
        assertEq(factory.strategyImplementation(), next);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setStrategyImplementation(address(0));
    }

    /// @notice The burn router is what a strategy swaps through to destroy supply. A zero one would
    /// produce a strategy whose burn reverts forever, and it is written into the proxy at launch.
    function test_BurnRouterCanBeReplacedAndRefusesZero() public {
        address next = address(new SweepBurnRouter(manager, ISweepFactory(address(factory))));
        factory.setBurnRouter(next);
        assertEq(factory.burnRouter(), next);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setBurnRouter(address(0));
    }

    /// @notice Every one of these is immutable or effectively so, and a zero would produce a factory
    /// that deploys broken strategies rather than one that fails loudly.
    function test_ConstructorRefusesAnyZeroDependency() public {
        address posm = address(factory.positionManager());
        address p2 = address(factory.permit2());
        address impl = factory.strategyImplementation();

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        new SweepNFTStrategyFactory(address(0), p2, address(manager), impl, feeTo, address(this));

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        new SweepNFTStrategyFactory(posm, address(0), address(manager), impl, feeTo, address(this));

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        new SweepNFTStrategyFactory(posm, p2, address(0), impl, feeTo, address(this));

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        new SweepNFTStrategyFactory(posm, p2, address(manager), address(0), feeTo, address(this));

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        new SweepNFTStrategyFactory(posm, p2, address(manager), impl, address(0), address(this));

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        new SweepNFTStrategyFactory(posm, p2, address(manager), impl, feeTo, address(0));
    }

    /// @notice Only the owner may retune anything. Launching is permissionless; steering is not.
    function test_OnlyTheOwnerCanRetuneTheFactory() public {
        vm.startPrank(launcher);

        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setLaunchFee(1 ether, launcher);

        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setResaleMultiplier(20_000);

        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setBurnRouter(launcher);

        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setStrategyImplementation(launcher);

        vm.stopPrank();
    }

    /// @notice The factory holds ETH for the span of one launch and nothing else. There is no
    /// `receive`, deliberately: nothing ever sends it ETH outside `launch`, so a payable fallback
    /// would exist only to reject — which is what having no fallback already does. Its absence is
    /// what makes "the factory never holds a balance" a property rather than a claim.
    function test_TheFactoryCannotBePaidDirectly() public {
        vm.prank(trader);
        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok, "the factory accepted a donation");
        assertEq(address(factory).balance, 0);
    }
}
