// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {StrategyHarness} from "./mocks/StrategyHarness.sol";
import {MockStrategyHook} from "./mocks/MockStrategyHook.sol";
import {MockSweepFactory} from "./mocks/MockSweepFactory.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";

/// @notice Holds a piece, delivers it inside the desk's venue call, and can run the one-wei round
/// trip of SC-07 atomically.
contract RoundTripper {
    function deliver(IERC721 collection, uint256 id, address desk) external payable {
        collection.transferFrom(address(this), desk, id);
    }

    function cycle(SweepNFTStrategy desk, IERC721 collection, uint256 id) external {
        desk.buyTargetNFT(1, abi.encodeCall(this.deliver, (collection, id, address(desk))), id, address(this));
        desk.sellTargetNFT{value: desk.askPrice(id)}(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/**
 * @title RampConsumptionTest
 * @notice SC-07: a purchase consumes only the part of the bid ramp it spent, so a one-wei purchase
 * can no longer reset the bid, and a capped purchase still restarts it.
 */
contract RampConsumptionTest is Test {
    StrategyHarness internal strategy;

    uint256 internal constant BID_PER_SECOND = 0.001 ether;
    uint256 internal constant MAX_BID = 3 ether;

    function setUp() public {
        vm.warp(1_788_000_000);
        strategy = StrategyHarness(payable(LibClone.clone(address(new StrategyHarness()))));
        strategy.initialize(
            "Ramp",
            "RAMP",
            makeAddr("hook"),
            makeAddr("poolManager"),
            makeAddr("curve"),
            BID_PER_SECOND,
            MAX_BID,
            makeAddr("owner")
        );
        strategy.exposed_fund(50 ether);
    }

    /// @notice A purchase at the whole bid restarts the ramp from nothing, as before.
    function test_APurchaseAtTheWholeBidRestartsTheRamp() public {
        vm.warp(block.timestamp + 1000);
        strategy.exposed_recordPurchase(strategy.currentBid());

        assertEq(strategy.currentBid(), 0);
    }

    /// @notice A purchase below the bid leaves the rest of the bid standing, rounded down to the
    /// ramp's whole seconds: what it did not spend is still offered.
    function test_APartialPurchaseLeavesTheRestOfTheBid() public {
        vm.warp(block.timestamp + 1000);
        uint256 bid = strategy.currentBid();

        strategy.exposed_recordPurchase(0.3 ether);

        assertEq(strategy.currentBid(), bid - 0.3 ether);
    }

    /// @notice A one-wei purchase lowers the bid by exactly one wei.
    function test_ADustPurchaseBarelyMovesTheBid() public {
        vm.warp(block.timestamp + 1000);
        uint256 bid = strategy.currentBid();

        strategy.exposed_recordPurchase(1);

        assertEq(strategy.currentBid(), bid - 1);
    }

    /// @notice The loop the first fix missed: a thousand one-wei purchases in one block lower the
    /// bid by a thousand wei, not by a thousand seconds of ramp.
    function test_ALoopOfDustPurchasesCostsTheBidOnlyWhatTheyPaid() public {
        vm.warp(block.timestamp + 1000);
        uint256 bid = strategy.currentBid();

        for (uint256 i = 0; i < 1000; ++i) {
            strategy.exposed_recordPurchase(1);
        }

        assertEq(strategy.currentBid(), bid - 1000);
    }

    /// @notice A desk left idle long after its ramp passed the cap still restarts from nothing
    /// after a purchase at the cap: the clock is first clamped to where the cap was reached, or a
    /// year of idle ramp would let it buy at the cap again and again in one block.
    function test_APurchaseAtTheCapAfterALongIdleStillRestartsTheRamp() public {
        vm.warp(block.timestamp + 365 days);
        assertEq(strategy.currentBid(), MAX_BID);

        strategy.exposed_recordPurchase(MAX_BID);

        assertEq(strategy.currentBid(), 0);
    }

    /// @notice The same holds when the treasury, not the cap, is what bounds the bid.
    function test_APurchaseOfTheWholeTreasuryRestartsTheRamp() public {
        StrategyHarness small = StrategyHarness(payable(LibClone.clone(address(new StrategyHarness()))));
        small.initialize(
            "Small",
            "SML",
            makeAddr("hook"),
            makeAddr("poolManager"),
            makeAddr("curve"),
            BID_PER_SECOND,
            MAX_BID,
            makeAddr("owner")
        );
        small.exposed_fund(0.4 ether);
        vm.warp(block.timestamp + 30 days);

        small.exposed_recordPurchase(0.4 ether);

        assertEq(small.currentBid(), 0);
    }

    /// @notice Two purchases in one block can never spend more between them than the single bid
    /// that stood before the first.
    function testFuzz_PurchasesNeverOutrunTheRamp(uint256 wait, uint256 first) public {
        wait = bound(wait, 1, 10 days);
        vm.warp(block.timestamp + wait);
        uint256 bid = strategy.currentBid();
        first = bound(first, 1, bid);

        strategy.exposed_recordPurchase(first);
        uint256 second = strategy.currentBid();

        assertLe(first + second, bid);
    }

    /// @notice The finding itself: a holder's one-wei sell-and-buy-back no longer drops the bid,
    /// so an honest seller at the bid that stood before still fills.
    function test_TheOneWeiRoundTripNoLongerStopsTheDesk() public {
        MockSweepFactory factory = new MockSweepFactory(address(this));
        address hook = address(new MockStrategyHook(address(factory), makeAddr("protocol")));
        SweepTestCollection collection = new SweepTestCollection("Ramp Apes", "RAPE", "");
        SweepNFTStrategy desk = SweepNFTStrategy(payable(LibClone.clone(address(new SweepNFTStrategy()))));
        SweepNFTStrategy.Config memory config;
        config.collection = address(collection);
        config.burnRouter = address(new MockBurnRouter());
        config.name = "Ramp Desk";
        config.symbol = "RDSK";
        config.hook = hook;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = 0.0001 ether;
        config.maxBid = 10 ether;
        config.resaleMultiplierBps = 12_000;
        config.owner = makeAddr("owner");
        config.curve = makeAddr("curve");
        desk.initialize(config);
        vm.deal(hook, 10 ether);
        vm.prank(hook);
        desk.addFees{value: 5 ether}();

        vm.warp(block.timestamp + 3000);
        uint256 bidBefore = desk.currentBid();

        RoundTripper griefer = new RoundTripper();
        uint256 piece = collection.mint(address(griefer));
        griefer.cycle(desk, IERC721(address(collection)), piece);

        assertEq(desk.currentBid(), bidBefore - 1, "the round trip cost the bid exactly what it paid");

        RoundTripper honest = new RoundTripper();
        uint256 fresh = collection.mint(address(honest));
        uint256 price = bidBefore - 1;
        desk.buyTargetNFT(
            price,
            abi.encodeCall(RoundTripper.deliver, (IERC721(address(collection)), fresh, address(desk))),
            fresh,
            address(honest)
        );
        assertEq(collection.ownerOf(fresh), address(desk));
    }
}
