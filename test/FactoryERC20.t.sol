// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {SweepForkTest} from "./shared/SweepForkTest.sol";
import {TargetToken, OwnerlessTargetToken} from "./mocks/TargetToken.sol";

/**
 * @title FactoryERC20Test
 * @author 0xDAVZER
 * @notice Pins the fungible launch on a forked Robinhood Chain: who may launch, what is refused,
 * how the bag is sized, where the creator tenth goes, and that the cycle runs on the real pool.
 *
 * @dev Everything the NFT launch already proves about the pool — price, position, supply, dust —
 * is shared code and is not proved twice. What is new is the gate, the bag, and the recipient.
 */
contract FactoryERC20Test is SweepForkTest {
    TargetToken internal target;
    address internal creator = makeAddr("creator");
    uint256 internal constant SUPPLY = 296_296_296e18;

    function setUp() public override {
        super.setUp();
        factory.setERC20Implementation(address(new SweepERC20Strategy()));
        target = new TargetToken();
        target.mint(trader, SUPPLY);
    }

    /* ─────────────────────────── the gate ───────────────────────────── */

    /// @notice Anyone may launch on any token, for the fee.
    function test_AnyoneLaunchesForTheFee() public {
        vm.prank(trader);
        address strategy =
            factory.launchERC20{value: LAUNCH_FEE}(address(target), "Target Sweep", "sTGT", BID_PER_SECOND, MAX_BID);

        assertEq(factory.strategyToCollection(strategy), address(target));
        assertEq(factory.strategyToCollection(strategy), address(target));
        assertEq(SweepERC20Strategy(payable(strategy)).owner(), address(this), "the launcher must not own it");
        assertEq(address(SweepERC20Strategy(payable(strategy)).token()), address(target));
    }

    /// @notice A token may carry as many bag desks as anyone cares to launch, same as a collection.
    /// Each sizes its own bag from the same supply and buys from the same
    /// market, and they compete there exactly as two NFT desks do on a floor.
    function test_ATokenMayCarryManyBagDesks() public {
        address first = _launchERC20();

        vm.prank(trader);
        address second =
            factory.launchERC20{value: LAUNCH_FEE}(address(target), "Again", "AGAIN", BID_PER_SECOND, MAX_BID);

        assertTrue(second != first && second != address(0), "the second launch produced nothing new");
        assertEq(factory.strategyToCollection(second), address(target));
        assertEq(SweepERC20Strategy(payable(second)).bagSize(), SweepERC20Strategy(payable(first)).bagSize());
    }

    function test_LaunchRefusesTheWrongFee() public {
        vm.prank(trader);
        vm.expectRevert(SweepNFTStrategyFactory.WrongLaunchFee.selector);
        factory.launchERC20{value: LAUNCH_FEE - 1}(address(target), "T", "T", BID_PER_SECOND, MAX_BID);
    }

    /// @notice A strategy pointed at something that is not a token could never buy a bag, and the
    /// fee would already be gone: an EOA, a collection, a contract with no supply, an empty token.
    ///
    /// @dev The collection is minted into first, which is the whole point: an empty
    /// `SweepTestCollection` answers `totalSupply() == 0` and would be refused for having no supply,
    /// not for being a collection. Every `ERC721Enumerable` and every ERC721A answers
    /// `totalSupply()` once it has pieces — the squat below.
    function test_LaunchRefusesWhatIsNotAnERC20() public {
        collection.mintBatch(launcher, 10);
        OwnerlessTargetToken empty = new OwnerlessTargetToken();
        address[3] memory wrong = [trader, address(collection), address(empty)];
        for (uint256 i = 0; i < wrong.length; i++) {
            vm.prank(trader);
            vm.expectRevert(SweepNFTStrategyFactory.NotERC20.selector);
            factory.launchERC20{value: LAUNCH_FEE}(wrong[i], "T", "T", BID_PER_SECOND, MAX_BID);
        }
    }

    /// @notice The fungible door refuses an ERC-721. A desk launched on one is dead on arrival,
    /// because `transferFrom(address,address,uint256)` shares its selector with ERC-721, so a bag
    /// of one piece can be bought and never resold. It is refused at the launch rather than at the
    /// first purchase, when the fee is already spent.
    function test_LaunchERC20RefusesACollection() public {
        collection.mintBatch(launcher, 500);
        collection.mintBatch(launcher, 500);

        vm.prank(trader);
        vm.expectRevert(SweepNFTStrategyFactory.NotERC20.selector);
        factory.launchERC20{value: LAUNCH_FEE}(address(collection), "Squat", "SQUAT", BID_PER_SECOND, MAX_BID);

        vm.expectRevert(SweepNFTStrategyFactory.NotERC20.selector);
        factory.ownerLaunchERC20{value: LAUNCH_FEE}(
            address(collection), 1, "Squat", "SQUAT", BID_PER_SECOND, MAX_BID, creator
        );

        vm.prank(launcher);
        address strategy =
            factory.launch{value: LAUNCH_FEE}(address(collection), "Sweep Test Apes", "sSTA", BID_PER_SECOND, MAX_BID);
        assertEq(factory.strategyToCollection(strategy), address(collection), "the NFT launch stopped working");
    }

    /// @notice A bag desk on a Sweep token is the same shape and just as dead: the token's own
    /// transfer lock refuses every move that is not a swap on its hooked pool, so the desk could
    /// never take delivery of a bag it paid for. It is refused at the launch rather than at the
    /// first purchase, when the fee is already spent.
    function test_LaunchERC20RefusesASweepStrategyToken() public {
        (address strategy,) = _launch();

        vm.prank(trader);
        vm.expectRevert(SweepNFTStrategyFactory.NotERC20.selector);
        factory.launchERC20{value: LAUNCH_FEE}(strategy, "Nested", "sNEST", BID_PER_SECOND, MAX_BID);
    }

    /// @notice A factory with its hook and router but no fungible implementation refuses a fungible
    /// launch by name, rather than cloning nothing. The hook is mined for the fresh factory, since
    /// a hook's initcode carries its factory's address.
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
        vm.expectRevert(SweepNFTStrategyFactory.ERC20ImplementationNotSet.selector);
        fresh.launchERC20{value: LAUNCH_FEE}(address(target), "T", "T", BID_PER_SECOND, MAX_BID);
    }

    /// @notice A fungible launch is bounded exactly as a collection's is: too slow a ramp never
    /// reaches a price worth selling at, too fast a one resolves before a seller can read it, and
    /// a ceiling above the cap would let one purchase empty the treasury.
    function test_LaunchRefusesBidParametersOutOfRange() public {
        uint256 slowest = factory.MIN_BID_INCREASE_PER_SECOND();
        uint256 fastest = factory.MAX_BID_INCREASE_PER_SECOND();
        uint256 cap = factory.MAX_BID_CAP();

        vm.startPrank(trader);
        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launchERC20{value: LAUNCH_FEE}(address(target), "T", "T", slowest - 1, MAX_BID);
        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launchERC20{value: LAUNCH_FEE}(address(target), "T", "T", fastest + 1, MAX_BID);
        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launchERC20{value: LAUNCH_FEE}(address(target), "T", "T", BID_PER_SECOND, 0);
        vm.expectRevert(SweepNFTStrategyFactory.InvalidBidParameters.selector);
        factory.launchERC20{value: LAUNCH_FEE}(address(target), "T", "T", BID_PER_SECOND, cap + 1);
        vm.stopPrank();
    }

    /* ─────────────────────────── the bag ────────────────────────────── */

    /// @notice The bag is one thousandth of the supply, sized by the factory and not by a front end,
    /// so no client can hand a launch a bag of its own choosing.
    function test_TheBagIsOneThousandthOfTheSupply() public {
        address strategy = _launchERC20();
        assertEq(factory.BAG_DIVISOR(), 1000);
        assertEq(SweepERC20Strategy(payable(strategy)).bagSize(), SUPPLY / 1000);
        assertEq(SweepERC20Strategy(payable(strategy)).bagSize(), 296_296.296e18);
    }

    /// @notice The event carries the bag, so an indexer never has to read the strategy for it.
    function test_LaunchEmitsTheBag() public {
        vm.expectEmit(true, false, true, false, address(factory));
        emit SweepNFTStrategyFactory.ERC20StrategyLaunched(
            address(target), address(0), trader, "Target Sweep", "sTGT", 0, SUPPLY / 1000
        );
        _launchERC20();
    }

    /* ────────────────────────── the recipient ───────────────────────── */

    /// @notice The creator tenth goes to the token's owner, never to whoever launched.
    function test_TheTokenOwnerIsTheCreatorFeeRecipient() public {
        address strategy = _launchERC20();
        assertEq(hook.creatorFeeRecipient(strategy), address(this), "the token's owner was not registered");
        assertTrue(hook.creatorFeeRecipient(strategy) != trader);
    }

    /// @notice A renounced token has nobody to pay, and the share falls through to the protocol.
    function test_AnOwnerlessTokenRegistersNoRecipient() public {
        OwnerlessTargetToken nobody = new OwnerlessTargetToken();
        nobody.mint(trader, SUPPLY);
        vm.prank(trader);
        address strategy =
            factory.launchERC20{value: LAUNCH_FEE}(address(nobody), "Nobody", "sNOBODY", BID_PER_SECOND, MAX_BID);
        assertEq(hook.creatorFeeRecipient(strategy), address(0));
    }

    /* ───────────────────────── the owner path ───────────────────────── */

    /// @notice The team-launched path: an explicit bag and an explicit recipient, for the factory
    /// owner only, at the same fee.
    function test_TheFactoryOwnerMaySizeTheBagAndNameTheRecipient() public {
        vm.deal(address(this), 1 ether);
        address strategy = factory.ownerLaunchERC20{value: LAUNCH_FEE}(
            address(target), 1000e18, "Target Sweep", "sTGT", BID_PER_SECOND, MAX_BID, creator
        );
        assertEq(SweepERC20Strategy(payable(strategy)).bagSize(), 1000e18);
        assertEq(hook.creatorFeeRecipient(strategy), creator);
    }

    function test_OwnerLaunchIsOnlyForTheFactoryOwner() public {
        vm.prank(trader);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.ownerLaunchERC20{value: LAUNCH_FEE}(address(target), 1e18, "T", "T", BID_PER_SECOND, MAX_BID, creator);
    }

    /// @notice A bag of nothing, or of more than exists, cannot be bought or sold.
    function test_OwnerLaunchRefusesAnImpossibleBag() public {
        vm.deal(address(this), 2 ether);
        vm.expectRevert(SweepNFTStrategyFactory.InvalidBag.selector);
        factory.ownerLaunchERC20{value: LAUNCH_FEE}(address(target), 0, "T", "T", BID_PER_SECOND, MAX_BID, creator);
        vm.expectRevert(SweepNFTStrategyFactory.InvalidBag.selector);
        factory.ownerLaunchERC20{value: LAUNCH_FEE}(
            address(target), SUPPLY + 1, "T", "T", BID_PER_SECOND, MAX_BID, creator
        );
    }

    function test_ERC20ImplementationCanBeReplacedForFutureLaunches() public {
        address next = address(new SweepERC20Strategy());
        factory.setERC20Implementation(next);
        assertEq(factory.erc20Implementation(), next);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setERC20Implementation(address(0));

        vm.prank(trader);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setERC20Implementation(next);
    }

    /* ───────────────────────── the whole cycle ──────────────────────── */

    /**
     * @notice The cycle on the real pool: a trade funds the treasury, a seller brings a bag and is
     * paid the bid, a buyer takes the bag at the ask, the proceeds are burnt, and every wei is
     * accounted for.
     */
    function test_TheBagCycleRunsOnTheForkedPool() public {
        address strategyAddr = _launchERC20();
        SweepERC20Strategy strategy = SweepERC20Strategy(payable(strategyAddr));
        PoolKey memory key = _keyFor(strategyAddr);

        vm.warp(block.timestamp + 90 minutes);
        _buy(key, 1 ether);
        uint256 treasury = strategy.treasury();
        assertGt(treasury, 0, "the trade funded nothing");

        vm.warp(block.timestamp + 1 hours);
        uint256 bid = strategy.currentBid();
        assertGt(bid, 0);
        assertLe(bid, treasury);

        vm.startPrank(trader);
        target.approve(strategyAddr, type(uint256).max);
        uint256 traderEthBefore = trader.balance;
        uint256 bagId = strategy.buyTokens();
        vm.stopPrank();
        assertEq(trader.balance - traderEthBefore, bid);
        assertEq(target.balanceOf(strategyAddr), strategy.bagSize());

        uint256 ask = strategy.askPrice(bagId);
        address buyer = makeAddr("bagBuyer");
        vm.deal(buyer, ask);
        vm.prank(buyer);
        strategy.sellTokens{value: ask}(bagId);
        assertEq(target.balanceOf(buyer), strategy.bagSize());
        assertEq(strategy.pendingBurn(), ask);

        uint256 deadBefore = strategy.balanceOf(strategy.DEAD_ADDRESS());
        vm.warp(block.timestamp + 1 minutes);
        (uint256 spent, uint256 reward) = strategy.processBurn();
        assertEq(spent + reward, ask);
        assertGt(strategy.balanceOf(strategy.DEAD_ADDRESS()), deadBefore, "nothing was burnt");
        assertEq(address(strategy).balance, strategy.treasury() + strategy.pendingBurn(), "conservation");
    }

    /* ───────────────────────────── helpers ──────────────────────────── */

    function _launchERC20() private returns (address strategy) {
        vm.prank(trader);
        strategy =
            factory.launchERC20{value: LAUNCH_FEE}(address(target), "Target Sweep", "sTGT", BID_PER_SECOND, MAX_BID);
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
