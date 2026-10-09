// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {MockStrategyHook} from "./mocks/MockStrategyHook.sol";
import {MockSweepFactory} from "./mocks/MockSweepFactory.sol";
import {HostileMarketplace} from "./mocks/HostileMarketplace.sol";
import {TargetToken} from "./mocks/TargetToken.sol";
import {LaunchOnlyHook} from "./CuratedLaunch.t.sol";

/**
 * @title FactoryAskDecayTest
 * @notice The factory launches every desk with a decaying ask (decision 0020, the live fork
 * finding of 6 October 2026): a fixed 1.2x ask left the Hoodborn desk holding 54 floor pieces
 * that never resold, so the burn they were bought to feed never ran.
 *
 * @dev A local factory with a hook that only answers a launch, as `CuratedLaunchTest` builds it,
 * so these run without an archive RPC.
 */
contract FactoryAskDecayTest is Test {
    SweepNFTStrategyFactory internal factory;
    SweepTestCollection internal collection;
    TargetToken internal token;
    HostileMarketplace internal venue;
    address internal hook;
    address internal launcher = makeAddr("launcher");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant FEE = 0.001 ether;
    uint256 internal constant BID_PER_SECOND = 0.0001 ether;
    uint256 internal constant MAX_BID = 1 ether;

    function setUp() public {
        vm.warp(1_788_000_000);
        factory = new SweepNFTStrategyFactory(
            makeAddr("positionManager"),
            makeAddr("permit2"),
            makeAddr("poolManager"),
            address(new SweepNFTStrategy()),
            makeAddr("launchFeeRecipient"),
            address(this),
            1.68 ether,
            4.2 ether
        );
        hook = address(new LaunchOnlyHook(address(factory), makeAddr("protocol")));
        factory.setHook(hook);
        factory.setBurnRouter(address(new MockBurnRouter()));
        factory.setERC20Implementation(address(new SweepERC20Strategy()));
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        factory.setCurveImplementation(address(new SweepBondingCurve(1.68 ether, 4.2 ether)));
        factory.setOpenLaunches(true);

        collection = new SweepTestCollection("Hoodborn", "HOOD", "");
        token = new TargetToken();
        token.mint(address(this), 1_000_000e18);
        venue = new HostileMarketplace();
        vm.deal(launcher, 1 ether);
        vm.deal(hook, 100 ether);
    }

    /* ─────────────────────────── the default ───────────────────────── */

    /// @notice A fresh factory opens every desk's ask decaying over three days.
    function test_TheFactoryDefaultsToAThreeDayDecayWindow() public view {
        assertEq(factory.askDecayWindow(), 3 days);
    }

    /// @notice An NFT desk launched by the factory carries the factory's decay window, not zero.
    function test_ALaunchedNFTDeskCarriesTheDefaultDecayWindow() public {
        SweepNFTStrategy desk = _launchNFTDesk(collection);
        assertEq(desk.askDecayWindow(), 3 days, "the desk launched with a fixed ask");
    }

    /// @notice A bag desk launched by the factory carries the same window: the ask formula is the
    /// desk base's, shared by both, and so is the failure a fixed ask causes.
    function test_ALaunchedBagDeskCarriesTheDefaultDecayWindow() public {
        vm.prank(launcher);
        address strategy = factory.launchERC20{value: FEE}(address(token), "Bag", "BAG", BID_PER_SECOND, MAX_BID);
        assertEq(SweepERC20Strategy(payable(strategy)).askDecayWindow(), 3 days, "the bag desk launched fixed");
    }

    /**
     * @notice On a desk the factory launched, the ask opens at the 1.2x markup, falls linearly to
     * what was paid by the end of the window, and never below it.
     *
     * @dev The floor at cost is what makes the decay safe for the treasury: a resale is at worst
     * a sale at cost, never a realised loss, so every wei paid still reaches the burn.
     */
    function test_AFactoryDeskAskFallsFromTheMarkupToCostAndNoFurther() public {
        SweepNFTStrategy desk = _launchNFTDesk(collection);
        uint256 tokenId = _buyOne(desk, 1 ether);
        uint256 bought = block.timestamp;

        assertEq(desk.askPrice(tokenId), 1.2 ether, "opens at the markup");

        vm.warp(bought + 1.5 days);
        assertEq(desk.askPrice(tokenId), 1.1 ether, "halfway through the window is halfway down");

        vm.warp(bought + 3 days);
        assertEq(desk.askPrice(tokenId), 1 ether, "reaches cost at the end of the window");

        vm.warp(bought + 365 days);
        assertEq(desk.askPrice(tokenId), 1 ether, "and never falls below it");
    }

    /// @notice Fuzzed over the whole window and past it: the ask never leaves `[cost, markup]`
    /// and never rises as time passes.
    function testFuzz_AFactoryDeskAskStaysBetweenCostAndMarkupAndOnlyFalls(uint256 a, uint256 b) public {
        SweepNFTStrategy desk = _launchNFTDesk(collection);
        uint256 tokenId = _buyOne(desk, 1 ether);
        uint256 bought = block.timestamp;
        a = bound(a, 0, 10 days);
        b = bound(b, a, 10 days);

        vm.warp(bought + a);
        uint256 earlier = desk.askPrice(tokenId);
        vm.warp(bought + b);
        uint256 later = desk.askPrice(tokenId);

        assertGe(later, 1 ether, "below cost");
        assertLe(earlier, 1.2 ether, "above the markup");
        assertLe(later, earlier, "the ask rose with time");
    }

    /* ─────────────────────────── the setter ────────────────────────── */

    /// @notice The owner retunes the default anywhere in `[1 day, 30 days]`, or switches the decay
    /// off with zero, and the next launch carries what was set.
    function test_TheOwnerRetunesTheDefaultDecayWindowWithinBounds() public {
        factory.setAskDecayWindow(1 days);
        assertEq(factory.askDecayWindow(), 1 days);
        factory.setAskDecayWindow(30 days);
        assertEq(factory.askDecayWindow(), 30 days);
        factory.setAskDecayWindow(0);
        assertEq(factory.askDecayWindow(), 0);

        factory.setAskDecayWindow(7 days);
        SweepNFTStrategy desk = _launchNFTDesk(collection);
        assertEq(desk.askDecayWindow(), 7 days, "the next launch did not carry the new default");
    }

    /// @notice A non-zero window under a day is refused: it drops every ask to cost within hours,
    /// so a bot buys the whole shelf back at cost and the markup that funds the burn is gone. The
    /// floor is `MIN_ASK_DECAY_WINDOW`, the name and value the desk's own bound uses (DK-1).
    function test_TheDefaultDecayWindowRefusesLessThanADay() public {
        assertEq(factory.MIN_ASK_DECAY_WINDOW(), 1 days);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setAskDecayWindow(1 days - 1);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setAskDecayWindow(1);
    }

    /// @notice A window over thirty days is refused: past a month the ask falls under 0.7% of cost
    /// a day, which against a falling floor is a fixed ask in all but name.
    function test_TheDefaultDecayWindowRefusesMoreThanThirtyDays() public {
        assertEq(factory.MAX_ASK_DECAY_WINDOW(), 30 days);

        vm.expectRevert(SweepNFTStrategyFactory.InvalidConfiguration.selector);
        factory.setAskDecayWindow(30 days + 1);
    }

    /// @notice Only the owner retunes the default; a stranger could otherwise launch a fixed-ask
    /// desk again, or one that sells at cost within the hour.
    function test_OnlyTheOwnerRetunesTheDefaultDecayWindow() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setAskDecayWindow(5 days);
        assertEq(factory.askDecayWindow(), 3 days);
    }

    /// @notice A change of the factory default moves no desk already launched: its window is its
    /// own storage, retuned only through that desk's `setResaleTerms`.
    function test_RetuningTheDefaultLeavesExistingDesksAlone() public {
        SweepNFTStrategy desk = _launchNFTDesk(collection);

        factory.setAskDecayWindow(10 days);

        assertEq(desk.askDecayWindow(), 3 days, "an existing desk moved");
    }

    /* ──────────────────────────── helpers ──────────────────────────── */

    function _launchNFTDesk(SweepTestCollection target) private returns (SweepNFTStrategy) {
        vm.prank(launcher);
        address strategy =
            factory.launch{value: FEE}(address(target), "Hood Strategy", "sHOOD", BID_PER_SECOND, MAX_BID);
        return SweepNFTStrategy(payable(strategy));
    }

    function _buyOne(SweepNFTStrategy desk, uint256 price) private returns (uint256 tokenId) {
        vm.prank(hook);
        desk.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 100_000);
        tokenId = collection.mint(address(venue));
        desk.buyTargetNFT(
            price,
            abi.encodeWithSignature("fulfill(address,uint256)", address(collection), tokenId),
            tokenId,
            address(venue)
        );
    }
}

/**
 * @title NFTDeskShelfCapTest
 * @notice The NFT desk holds at most `MAX_INVENTORY` pieces (decision 0020). Every purchase walks
 * the whole shelf to prove the venue lifted nothing (decision 0015), so its gas grows with the
 * shelf: 214k at zero pieces and 529k at 57 on the 6 October mainnet fork, about 5.5k a piece,
 * which would have passed the keeper's 20M gas cap near 3,600 pieces and frozen the desk for good.
 *
 * @dev Fills the shelf through real purchases rather than `vm.store`, so the cap is watched firing
 * on exactly the state a live desk reaches.
 */
contract NFTDeskShelfCapTest is Test {
    SweepNFTStrategy internal strategy;
    SweepTestCollection internal collection;
    HostileMarketplace internal venue;

    MockSweepFactory internal mockFactory = new MockSweepFactory(address(this));
    address internal hook = address(new MockStrategyHook(address(mockFactory), makeAddr("protocol")));
    address internal owner = makeAddr("owner");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant PRICE = 1 gwei;

    /// @notice The per-transaction budget a purchase at a full shelf must stay under: a quarter
    /// of the keeper's 20M gas cap, leaving the rest for a real Seaport fill.
    uint256 internal constant PURCHASE_GAS_BUDGET = 5_000_000;

    function setUp() public {
        vm.warp(1_788_000_000);
        collection = new SweepTestCollection("Hoodborn", "HOOD", "");
        venue = new HostileMarketplace();

        SweepNFTStrategy.Config memory config;
        config.collection = address(collection);
        config.burnRouter = address(new MockBurnRouter());
        config.name = "Hood Strategy";
        config.symbol = "sHOOD";
        config.hook = hook;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = 0.01 ether;
        config.maxBid = 10 ether;
        config.resaleMultiplierBps = 12_000;
        config.askDecayWindow = 3 days;
        config.owner = owner;
        config.curve = makeAddr("curve");

        strategy = SweepNFTStrategy(payable(LibClone.clone(address(new SweepNFTStrategy()))));
        strategy.initialize(config);

        vm.deal(hook, 100 ether);
        vm.prank(hook);
        strategy.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 1000);
    }

    /// @notice The cap is five hundred pieces.
    function test_TheShelfHoldsAtMostFiveHundredPieces() public view {
        assertEq(strategy.MAX_INVENTORY(), 500);
    }

    /// @notice With the shelf full, a purchase is refused by name before any ETH leaves, so the
    /// desk stops buying instead of growing a walk that will one day exceed every gas cap.
    function test_APurchaseIsRefusedOnceTheShelfIsFull() public {
        _fill(strategy.MAX_INVENTORY());
        assertEq(strategy.inventoryCount(), 500);
        uint256 treasuryBefore = strategy.treasury();

        uint256 tokenId = collection.mint(address(venue));
        vm.expectRevert(SweepNFTStrategy.InventoryFull.selector);
        strategy.buyTargetNFT(PRICE, _fillCalldata(tokenId), tokenId, address(venue));

        assertEq(strategy.treasury(), treasuryBefore, "a refused purchase spent the treasury");
        assertEq(collection.ownerOf(tokenId), address(venue));
    }

    /// @notice The cap is a pause, not a death: one resale frees one place and the desk buys again.
    function test_OneResaleFreesRoomForTheNextPurchase() public {
        _fill(strategy.MAX_INVENTORY());
        uint256 sold = strategy.heldTokenIds()[0];

        hoax(buyer, 1 ether);
        strategy.sellTargetNFT{value: strategy.askPrice(sold)}(sold);
        assertEq(strategy.inventoryCount(), 499);

        uint256 tokenId = collection.mint(address(venue));
        strategy.buyTargetNFT(PRICE, _fillCalldata(tokenId), tokenId, address(venue));

        assertEq(strategy.inventoryCount(), 500);
        assertEq(collection.ownerOf(tokenId), address(strategy));
    }

    /// @notice A write-off frees a place too, so a shelf full of pieces the collection took back
    /// cannot hold the desk at the cap.
    function test_AWriteOffFreesRoomForTheNextPurchase() public {
        _fill(strategy.MAX_INVENTORY());
        uint256 lost = strategy.heldTokenIds()[0];
        vm.prank(address(strategy));
        collection.transferFrom(address(strategy), makeAddr("seizer"), lost);
        strategy.writeOff(lost);

        uint256 tokenId = collection.mint(address(venue));
        strategy.buyTargetNFT(PRICE, _fillCalldata(tokenId), tokenId, address(venue));

        assertEq(strategy.inventoryCount(), 500);
    }

    /**
     * @notice The last purchase the cap allows — 499 pieces held, so the walk reads 499 owners —
     * fits the budget with every slot cold, as it is in a fresh mainnet transaction.
     *
     * @dev The mock venue is cheap, so the slope is measured too: the gas of the same purchase at
     * an empty shelf is subtracted and divided by 499. A real Seaport fill adds its own fixed cost
     * (214k in total at an empty shelf on the fork) and nothing per piece, so
     * `214k + 499 · slope` is the honest estimate of the live worst case, and it is asserted too.
     */
    function test_APurchaseAtTheLastFreePlaceFitsTheGasBudget() public {
        uint256 atEmpty = _measuredPurchase();
        _fill(strategy.MAX_INVENTORY() - 2);
        assertEq(strategy.inventoryCount(), 499);

        uint256 atFull = _measuredPurchase();
        uint256 perPiece = (atFull - atEmpty) / 499;
        uint256 liveEstimate = 214_000 + 499 * perPiece;

        console2.log("purchase gas, empty shelf:", atEmpty);
        console2.log("purchase gas, 499 held:   ", atFull);
        console2.log("walk gas per piece:       ", perPiece);
        console2.log("live estimate at 499 held:", liveEstimate);

        assertEq(strategy.inventoryCount(), 500);
        assertLt(atFull, PURCHASE_GAS_BUDGET, "a purchase at the cap no longer fits the budget");
        assertLt(liveEstimate, PURCHASE_GAS_BUDGET, "the live estimate no longer fits the budget");
    }

    /* ──────────────────────────── helpers ──────────────────────────── */

    function _fill(uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            uint256 tokenId = collection.mint(address(venue));
            strategy.buyTargetNFT(PRICE, _fillCalldata(tokenId), tokenId, address(venue));
        }
    }

    /// @dev One purchase with the desk's and the collection's state cooled first, so every owner
    /// the walk reads costs what it costs in a fresh transaction.
    function _measuredPurchase() private returns (uint256 spent) {
        uint256 tokenId = collection.mint(address(venue));
        bytes memory data = _fillCalldata(tokenId);
        vm.cool(address(strategy));
        vm.cool(address(collection));
        vm.cool(address(venue));
        uint256 before = gasleft();
        strategy.buyTargetNFT(PRICE, data, tokenId, address(venue));
        spent = before - gasleft();
    }

    function _fillCalldata(uint256 tokenId) private view returns (bytes memory) {
        return abi.encodeWithSignature("fulfill(address,uint256)", address(collection), tokenId);
    }
}
