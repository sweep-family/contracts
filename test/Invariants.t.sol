// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {SweepForkTest} from "./shared/SweepForkTest.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {MockMarketplace} from "./mocks/MockMarketplace.sol";

/**
 * @title DeskHandler
 * @author 0xDAVZER
 * @notice Every move a stranger can make against one NFT desk, in whatever order the fuzzer picks.
 *
 * @dev Each action bounds its inputs to what could actually be sent and returns quietly when the
 * state makes the move impossible (nothing to sell, no bid, the burn cooling down), so the fuzzer
 * spends its depth on sequences that reach the contracts rather than on reverts it already knows.
 * A revert that does get through is not a failure by itself (`fail_on_revert` is off): the
 * invariants are what must hold after every call, whether it landed or not.
 *
 * @dev Three traders share the pool so a sell can meet tokens someone else bought, and a single
 * seller lists every piece so its proceeds are easy to tell apart from fees. The ghost counters
 * record what the handler itself paid and received; the invariant contract compares them with
 * what the ledgers claim.
 */
contract DeskHandler is Test {
    SweepNFTStrategy internal immutable s;
    SweepHook internal immutable hook;
    SweepSwapRouter internal immutable router;
    SweepTestCollection internal immutable collection;
    MockMarketplace internal immutable market;
    address internal immutable launcher;
    address internal immutable protocol;

    address[3] internal traders = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
    address internal seller = makeAddr("seller");
    address internal keeper = makeAddr("keeper");
    address internal collector = makeAddr("collector");

    uint256[] public inventory;

    uint256 public ghostPaidForPieces;
    uint256 public ghostResaleProceeds;
    uint256 public ghostBurnRewards;
    uint256 public ghostBurns;
    uint256 public ghostSweeps;
    uint256 public ghostResales;
    uint256 public ghostTrades;

    /// @dev The seller approves the marketplace once, so every listing it posts can be filled.
    constructor(
        SweepNFTStrategy s_,
        SweepHook hook_,
        SweepSwapRouter router_,
        SweepTestCollection collection_,
        MockMarketplace market_,
        address launcher_,
        address protocol_
    ) {
        s = s_;
        hook = hook_;
        router = router_;
        collection = collection_;
        market = market_;
        launcher = launcher_;
        protocol = protocol_;
        vm.prank(seller);
        collection.setApprovalForAll(address(market), true);
    }

    /// @notice A trader buys the token with up to 5 ETH, funded on the spot.
    function buy(uint256 who, uint256 ethIn) external {
        address t = traders[who % 3];
        ethIn = bound(ethIn, 1e9, 5 ether);
        vm.deal(t, t.balance + ethIn);
        vm.prank(t);
        router.buy{value: ethIn}(address(s), 0, block.timestamp);
        ghostTrades++;
    }

    /// @notice A trader sells some share of what it holds, from a sliver to all of it.
    function sell(uint256 who, uint256 shareBps) external {
        address t = traders[who % 3];
        uint256 held = s.balanceOf(t);
        if (held == 0) return;
        uint256 amount = (held * bound(shareBps, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        vm.startPrank(t);
        s.approve(address(router), amount);
        router.sell(address(s), amount, 0, block.timestamp);
        vm.stopPrank();
        ghostTrades++;
    }

    /// @notice Time passes: up to three hours, which carries the bid ramp through most of its climb.
    function wait(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 3 hours));
    }

    /**
     * @notice A fresh piece is listed at a price no higher than the bid, and the desk buys it.
     * @dev Minted by the collection's owner (the launcher) to the seller, as a real listing would
     * come from any holder. The price is bounded by the live bid, so this is the honest path; the
     * hostile marketplaces have their own suite.
     */
    function sweep(uint256 priceSeed) external {
        uint256 bid = s.currentBid();
        if (bid == 0) return;
        uint256 price = bound(priceSeed, 1, bid);
        vm.prank(launcher);
        uint256 tokenId = collection.mint(seller);
        vm.prank(seller);
        market.list(address(collection), tokenId, price);
        s.buyTargetNFT(price, abi.encodeCall(market.fulfill, (address(collection), tokenId)), tokenId, address(market));
        inventory.push(tokenId);
        ghostPaidForPieces += price;
        ghostSweeps++;
    }

    /// @notice A collector buys one piece off the shelf at its ask.
    function resell(uint256 index) external {
        if (inventory.length == 0) return;
        uint256 i = index % inventory.length;
        uint256 tokenId = inventory[i];
        uint256 ask = s.askPrice(tokenId);
        vm.deal(collector, collector.balance + ask);
        vm.prank(collector);
        s.sellTargetNFT{value: ask}(tokenId);
        inventory[i] = inventory[inventory.length - 1];
        inventory.pop();
        ghostResaleProceeds += ask;
        ghostResales++;
    }

    /// @notice Anyone triggers the burn once there is something queued and the cooldown has run.
    function burn() external {
        if (s.pendingBurn() == 0) return;
        if (block.timestamp < s.lastBurnAt() + s.burnCooldown()) return;
        vm.prank(keeper);
        (, uint256 reward) = s.processBurn();
        ghostBurnRewards += reward;
        ghostBurns++;
    }

    /// @notice Anyone pays out what the hook owes the protocol or the collection.
    function claim(uint256 which) external {
        hook.claimFeesFor(which % 2 == 0 ? protocol : launcher);
    }

    /// @notice How many pieces the handler believes the desk holds.
    function inventoryLength() external view returns (uint256) {
        return inventory.length;
    }

    /// @notice The three traders, for the invariant contract's sums.
    function trader(uint256 i) external view returns (address) {
        return traders[i];
    }
}

/**
 * @title DeskInvariantTest
 * @author 0xDAVZER
 * @notice What must hold on an NFT desk after any sequence of trades, sweeps, resales, burns and
 * claims, against the real Uniswap v4 on Robinhood Chain.
 *
 * @dev The strategy is launched and the fuzzer starts trading at once: the fee is flat, so there
 * is no ramp to be inside of, and what the clock moves is the bid. Only the
 * handler is a target: the invariants below are statements about the contracts, and a fuzzer
 * calling the contracts directly would mostly revert on guards other suites already pin.
 *
 * @dev The budget is set here rather than in foundry.toml because every call runs against a fork:
 * the default 256 runs of 64 calls took about 45 minutes, which no CI job should carry. Eight runs
 * of 40 calls reach every action (about 90 s) and are enough to catch a burn that under-decrements
 * `pendingBurn` or a fee ledger one wei too generous. Before a
 * release, run it deep with `FOUNDRY_PROFILE=intense`: 64 runs of 64 calls, about 11 minutes,
 * rather than the profile's 2,000 runs of 256, which on a fork would take the better part of a day.
 */
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 40
/// forge-config: intense.invariant.runs = 64
/// forge-config: intense.invariant.depth = 64
contract DeskInvariantTest is SweepForkTest {
    SweepNFTStrategy internal s;
    SweepSwapRouter internal router;
    DeskHandler internal handler;

    /// @dev Launches one desk, deploys the production swap router, and hands both to the handler.
    function setUp() public override {
        super.setUp();
        router = new SweepSwapRouter(manager, ISweepFactory(address(factory)));
        factory.setRouter(address(router), true);
        (address strategy,) = _launch();
        s = SweepNFTStrategy(payable(strategy));
        handler = new DeskHandler(s, hook, router, collection, market, launcher, feeTo);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = DeskHandler.buy.selector;
        selectors[1] = DeskHandler.sell.selector;
        selectors[2] = DeskHandler.wait.selector;
        selectors[3] = DeskHandler.sweep.selector;
        selectors[4] = DeskHandler.resell.selector;
        selectors[5] = DeskHandler.burn.selector;
        selectors[6] = DeskHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Every wei the strategy holds is either treasury or queued for burning.
    function invariant_StrategyEthIsTreasuryPlusPendingBurn() public view {
        assertEq(address(s).balance, s.treasury() + s.pendingBurn());
    }

    /// @notice Every wei the hook holds is owed to someone by name, and nothing more is owed.
    function invariant_HookEthIsExactlyWhatItOwes() public view {
        assertEq(address(hook).balance, hook.accruedFees(feeTo) + hook.accruedFees(launcher));
    }

    /// @notice A burn moves tokens to the dead address; nothing ever mints or destroys supply.
    function invariant_SupplyNeverChanges() public view {
        assertEq(s.totalSupply(), s.MAX_SUPPLY());
        assertEq(s.circulatingSupply(), s.totalSupply() - s.balanceOf(DEAD_ADDRESS));
    }

    /// @notice The hook and both routers are pipes: no token and no ETH ever rests in them.
    function invariant_PipesHoldNothing() public view {
        assertEq(s.balanceOf(address(hook)), 0, "hook kept tokens");
        assertEq(s.balanceOf(address(router)), 0, "swap router kept tokens");
        assertEq(s.balanceOf(address(burnRouter)), 0, "burn router kept tokens");
        assertEq(address(router).balance, 0, "swap router kept ETH");
        assertEq(address(burnRouter).balance, 0, "burn router kept ETH");
        assertEq(s.balanceOf(address(factory)), 0, "factory kept tokens");
    }

    /// @notice The bid can never promise more than the treasury could pay.
    function invariant_BidNeverExceedsTreasury() public view {
        assertLe(s.currentBid(), s.treasury());
    }

    /// @notice The desk owns exactly the pieces it bought and has not resold, and counts them right.
    function invariant_InventoryMatchesOwnership() public view {
        uint256 n = handler.inventoryLength();
        assertEq(s.inventoryCount(), n, "inventoryCount drifted");
        for (uint256 i = 0; i < n; i++) {
            assertEq(IERC721(address(collection)).ownerOf(handler.inventory(i)), address(s));
        }
    }

    /**
     * @notice Resale proceeds only ever leave the desk as a burn or as the burn caller's reward.
     * @dev What is still queued plus what the burns have spent must equal what collectors paid. The
     * burns' spend is not observable directly, so the check is the inequality that must hold
     * whatever it was: the queue can never exceed the proceeds, and the caller rewards can never
     * exceed 0.5% of what was queued.
     */
    function invariant_ResaleProceedsOnlyFeedTheBurn() public view {
        assertLe(s.pendingBurn(), handler.ghostResaleProceeds());
        assertLe(handler.ghostBurnRewards() * 10_000, handler.ghostResaleProceeds() * s.BURN_CALLER_REWARD_BPS());
    }

    /// @notice The traders together can never hold more than the pool has ever let out.
    function invariant_TradersHoldNoMoreThanCirculates() public view {
        uint256 held = s.balanceOf(handler.trader(0)) + s.balanceOf(handler.trader(1)) + s.balanceOf(handler.trader(2));
        assertLe(held, s.circulatingSupply());
    }

    /// @notice How deep the fuzzer actually reached, printed once per run in `-vv`.
    function afterInvariant() external view {
        console2.log("trades", handler.ghostTrades(), "sweeps", handler.ghostSweeps());
        console2.log("resales", handler.ghostResales(), "burns", handler.ghostBurns());
    }
}
