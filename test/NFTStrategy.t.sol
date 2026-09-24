// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SweepStrategy} from "../src/SweepStrategy.sol";
import {SweepToken} from "../src/SweepToken.sol";
import {SweepDesk} from "../src/SweepDesk.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {HostileMarketplace, Betrayal} from "./mocks/HostileMarketplace.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {LyingCollection} from "./mocks/LyingCollection.sol";

/**
 * @title NFTStrategyTest
 * @author 0xDAVZER
 * @notice Pins the desk: what it will pay, what it proves after paying, what it asks, and where the
 * proceeds go.
 *
 * @dev The purchase tests lean on the fixtures' hostile venue, which exists precisely so each guard is
 * watched firing rather than believed. The ask tests cover the one real departure from the
 * reference — a descending price — and the failure it is there to prevent.
 */
contract NFTStrategyTest is Test {
    SweepNFTStrategy internal strategy;
    SweepTestCollection internal collection;
    HostileMarketplace internal venue;
    MockBurnRouter internal router;

    address internal hook = makeAddr("hook");
    address internal poolManager = makeAddr("poolManager");
    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant BID_PER_SECOND = 0.01 ether;
    uint256 internal constant MAX_BID = 10 ether;
    uint256 internal constant MULTIPLIER = 14_000;
    uint256 internal constant DECAY_WINDOW = 30 days;

    function setUp() public {
        vm.warp(1_788_000_000);

        collection = new SweepTestCollection("Phantom Brokers", "PHANTOM", "");
        venue = new HostileMarketplace();
        router = new MockBurnRouter();

        strategy = new SweepNFTStrategy();
        strategy.initialize(
            _config(
                address(collection),
                address(router),
                "Phantom Strategy",
                "PHSTR",
                hook,
                poolManager,
                BID_PER_SECOND,
                MAX_BID,
                MULTIPLIER,
                DECAY_WINDOW,
                owner
            )
        );

        vm.prank(owner);
        strategy.setDistributor(address(this), true);
        strategy.transfer(address(router), 100_000_000e18);

        vm.deal(hook, 100 ether);
    }

    /* ─────────────────────────── purchasing ────────────────────────── */

    /// @notice A purchase records what was paid and when, which is what the ask is derived from.
    function test_PurchaseRecordsTheHolding() public {
        uint256 tokenId = _fundAndBuy(1 ether);

        (uint256 cost, uint256 acquiredAt) = strategy.holdings(tokenId);
        assertEq(cost, 1 ether);
        assertEq(acquiredAt, block.timestamp);
        assertEq(strategy.inventoryCount(), 1);
        assertEq(collection.ownerOf(tokenId), address(strategy));
    }

    /// @notice The treasury pays, and the bid restarts from nothing for the next seller.
    function test_PurchaseSpendsTheTreasuryAndResetsTheBid() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);
        uint256 tokenId = _listAndFill(1 ether);

        assertEq(strategy.treasury(), 4 ether);
        assertEq(strategy.currentBid(), 0);
        tokenId;
    }

    /**
     * @notice The cost is what actually left, not what was offered.
     * @dev A venue filling at a better price and refunding the difference is ordinary. Assuming the
     * offered amount was spent would overstate the cost, which would then overstate the ask and
     * leave the piece harder to sell than it should be.
     */
    function test_CostIsMeasuredNotAssumed() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);

        uint256 tokenId = collection.mint(address(venue));
        venue.setBetrayal(Betrayal.ReturnChange);
        venue.setChange(0.4 ether);

        strategy.buyTargetNFT(1 ether, _fillCalldata(tokenId), tokenId, address(venue));

        (uint256 cost,) = strategy.holdings(tokenId);
        assertEq(cost, 0.6 ether, "only what actually left is booked");
        assertEq(strategy.treasury(), 4.4 ether);
    }

    /**
     * @notice A fee credited while the purchase is still open must not be read as change.
     *
     * @dev Were cost read as `ethBefore - address(this).balance`, then since `addFees` raises the
     * balance and the treasury together, every wei that arrived during the venue call would count
     * twice — once as a credit, once as a smaller cost. A venue that trades the strategy's own token
     * before returning is enough: a 0.171 ETH bid paid out could book a cost of 0.089 and a ledger
     * of 0.165 against 0.083 actually held. Two such purchases with proceeds queued leave
     * `pendingBurn` above the balance and `processBurn` reverting for good, which destroys the burn
     * rather than steals.
     *
     * @dev The strategy here names the venue as its hook, because a unit test has no real hook to
     * make the credit arrive. What is pinned is the arithmetic: the treasury's own gain is added
     * back before the delta is read, so `cost` is what the venue kept and nothing else, and the
     * money invariant — balance equals treasury plus the burn queue — survives the purchase.
     */
    function test_FeesCreditedDuringTheFillAreNotBookedAsChange() public {
        SweepNFTStrategy s = new SweepNFTStrategy();
        s.initialize(
            _config(
                address(collection),
                address(router),
                "Mid-fill",
                "MID",
                address(venue),
                poolManager,
                BID_PER_SECOND,
                MAX_BID,
                MULTIPLIER,
                DECAY_WINDOW,
                owner
            )
        );

        vm.deal(address(venue), 10 ether);
        vm.prank(address(venue));
        s.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 200);

        uint256 tokenId = collection.mint(address(venue));
        venue.setBetrayal(Betrayal.CreditFees);
        venue.setFees(0.5 ether);

        s.buyTargetNFT(1 ether, _fillCalldata(tokenId), tokenId, address(venue));

        (uint256 cost,) = s.holdings(tokenId);
        assertEq(cost, 1 ether, "the fee was booked as change on the purchase");
        assertEq(s.treasury(), 4.5 ether, "the treasury ledger drifted from what was spent");
        assertEq(address(s).balance, s.treasury() + s.pendingBurn(), "the ledger outgrew the money");
    }

    /**
     * @notice A purchase that costs nothing is refused.
     *
     * @dev Without the guard, a venue that delivers the piece and refunds the whole price books
     * `cost = 0`, which resets the bid ramp to zero and puts a piece on the shelf that
     * `sellTargetNFT` refuses for ever after, since a zero cost is how "not held" is spelled. Anyone
     * holding a piece of the collection could do it at will, one piece per reset, and front-run a
     * genuine seller into `BidExceeded`. The bag desk refuses the same case with `NothingToSpend`.
     */
    function test_APurchaseThatCostsNothingIsRefused() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);

        uint256 tokenId = collection.mint(address(venue));
        venue.setBetrayal(Betrayal.ReturnChange);
        venue.setChange(1 ether);

        vm.expectRevert(SweepNFTStrategy.NothingToSpend.selector);
        strategy.buyTargetNFT(1 ether, _fillCalldata(tokenId), tokenId, address(venue));

        assertEq(strategy.inventoryCount(), 0, "a piece bought for nothing reached the shelf");
    }

    /// @notice Nobody may spend above the price the protocol has published.
    function test_PurchaseRefusesAboveTheBid() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 10);

        uint256 tokenId = collection.mint(address(venue));
        vm.expectRevert(SweepNFTStrategy.BidExceeded.selector);
        strategy.buyTargetNFT(5 ether, _fillCalldata(tokenId), tokenId, address(venue));
    }

    /**
     * @notice The collection itself can never be the venue.
     * @dev Without this a collection owner could point the call at their own payable `mint` and sell
     * the protocol freshly-created supply at the bid, forever, for as long as the treasury refills.
     */
    function test_PurchaseRefusesTheCollectionAsVenue() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);

        vm.expectRevert(SweepNFTStrategy.TargetIsCollection.selector);
        strategy.buyTargetNFT(1 ether, "", 1, address(collection));
    }

    /**
     * @notice Buying something already held would pay twice for one piece.
     * @dev The warp is not decoration. A purchase resets the ramp, so without letting the bid climb
     * again the cheaper `BidExceeded` guard fires first and this test would pass for the wrong
     * reason — proving the bid check works rather than the ownership check.
     */
    function test_PurchaseRefusesAPieceAlreadyHeld() public {
        uint256 tokenId = _fundAndBuy(1 ether);
        vm.warp(block.timestamp + 200);

        vm.expectRevert(SweepNFTStrategy.AlreadyOwned.selector);
        strategy.buyTargetNFT(1 ether, _fillCalldata(tokenId), tokenId, address(venue));
    }

    /// @notice A venue that takes the ETH and sends nothing is caught by the balance check.
    function test_PurchaseRefusesAVenueThatDeliversNothing() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);

        uint256 tokenId = collection.mint(address(venue));
        venue.setBetrayal(Betrayal.DeliverNothing);

        vm.expectRevert(SweepNFTStrategy.NothingDelivered.selector);
        strategy.buyTargetNFT(1 ether, _fillCalldata(tokenId), tokenId, address(venue));
    }

    /**
     * @notice A venue that delivers a different piece is caught by the ownership check.
     * @dev The balance check passes here — a piece genuinely arrived — so this is the betrayal that
     * makes two guards necessary rather than one.
     */
    function test_PurchaseRefusesAVenueThatDeliversTheWrongPiece() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);

        uint256 wanted = collection.mint(address(venue));
        uint256 substitute = collection.mint(address(venue));
        venue.setBetrayal(Betrayal.DeliverWrongId);
        venue.setSubstitute(substitute);

        vm.expectRevert(SweepNFTStrategy.WrongPieceDelivered.selector);
        strategy.buyTargetNFT(1 ether, _fillCalldata(wanted), wanted, address(venue));
    }

    /// @notice A venue that reverts takes nothing with it.
    function test_PurchaseRefusesAVenueThatReverts() public {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);

        uint256 tokenId = collection.mint(address(venue));
        venue.setBetrayal(Betrayal.TakeAndRevert);

        vm.expectRevert();
        strategy.buyTargetNFT(1 ether, _fillCalldata(tokenId), tokenId, address(venue));
        assertEq(strategy.treasury(), 5 ether, "the treasury is untouched");
    }

    /* ──────────────────────────── the ask ──────────────────────────── */

    /// @notice The ask opens at the full markup.
    function test_AskOpensAtTheMarkup() public {
        uint256 tokenId = _fundAndBuy(1 ether);
        assertEq(strategy.askPrice(tokenId), 1.4 ether);
    }

    /// @notice And falls toward what was paid as the window elapses.
    function test_AskDecaysTowardCost() public {
        uint256 tokenId = _fundAndBuy(1 ether);

        vm.warp(block.timestamp + DECAY_WINDOW / 2);
        assertEq(strategy.askPrice(tokenId), 1.2 ether, "halfway is halfway");
    }

    /**
     * @notice The ask never falls below what the protocol paid.
     * @dev A sale is therefore never a realised loss, only a smaller gain — which is what makes a
     * descending ask safe rather than merely impatient.
     */
    function test_AskNeverFallsBelowCost() public {
        uint256 tokenId = _fundAndBuy(1 ether);

        vm.warp(block.timestamp + 365 days);
        assertEq(strategy.askPrice(tokenId), 1 ether, "floored at cost, forever");
    }

    /// @notice A zero window turns the decaying ask into a fixed price at cost times the multiplier.
    function test_AskIsFixedWhenTheWindowIsZero() public {
        vm.prank(owner);
        strategy.setResaleTerms(MULTIPLIER, 0);

        uint256 tokenId = _fundAndBuy(1 ether);
        vm.warp(block.timestamp + 365 days);
        assertEq(strategy.askPrice(tokenId), 1.4 ether, "a zero window must never move the ask");
    }

    /// @notice Retuning the terms reprices inventory already held.
    /// @dev Deliberate: the alternative strands old pieces under terms the operator has already
    /// judged wrong, which is the situation being fixed in the first place.
    function test_ResaleTermsRepriceHeldInventory() public {
        uint256 tokenId = _fundAndBuy(1 ether);
        assertEq(strategy.askPrice(tokenId), 1.4 ether);

        vm.prank(owner);
        strategy.setResaleTerms(11_000, DECAY_WINDOW);
        assertEq(strategy.askPrice(tokenId), 1.1 ether, "recomputed on read");
    }

    /// @notice A markup below par would sell at a loss on every cycle.
    function test_ResaleTermsRefuseAMarkupBelowPar() public {
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setResaleTerms(9000, DECAY_WINDOW);
    }

    /* ──────────────────────────── selling ──────────────────────────── */

    /// @notice A sale delivers the piece and queues every wei for burning.
    function test_SaleDeliversAndQueuesTheProceeds() public {
        uint256 tokenId = _fundAndBuy(1 ether);
        uint256 ask = strategy.askPrice(tokenId);

        hoax(buyer, 10 ether);
        strategy.sellTargetNFT{value: ask}(tokenId);

        assertEq(collection.ownerOf(tokenId), buyer);
        assertEq(strategy.pendingBurn(), ask, "all of it, not the margin");
        assertEq(strategy.treasury(), 4 ether, "and none of it reaches the treasury");
        assertEq(strategy.inventoryCount(), 0);
    }

    /// @notice The exact ask is required, so a stale quote is refused rather than filled.
    function test_SaleRefusesTheWrongPayment() public {
        uint256 tokenId = _fundAndBuy(1 ether);

        hoax(buyer, 10 ether);
        vm.expectRevert(SweepDesk.WrongPayment.selector);
        strategy.sellTargetNFT{value: 1.39 ether}(tokenId);
    }

    /// @notice A piece the desk does not hold is not for sale.
    function test_SaleRefusesAPieceNotHeld() public {
        hoax(buyer, 10 ether);
        vm.expectRevert(SweepDesk.NotForSale.selector);
        strategy.sellTargetNFT{value: 1 ether}(999);
    }

    /// @notice The same piece cannot be bought twice.
    function test_SaleClearsTheHolding() public {
        uint256 tokenId = _fundAndBuy(1 ether);
        uint256 ask = strategy.askPrice(tokenId);

        hoax(buyer, 10 ether);
        strategy.sellTargetNFT{value: ask}(tokenId);

        (uint256 cost,) = strategy.holdings(tokenId);
        assertEq(cost, 0);

        hoax(buyer, 10 ether);
        vm.expectRevert(SweepDesk.NotForSale.selector);
        strategy.sellTargetNFT{value: ask}(tokenId);
    }

    /* ───────────────────────────── burning ─────────────────────────── */

    /// @notice The burn buys this token and sends it where nobody can retrieve it.
    function test_BurnBuysAndSendsToTheDeadAddress() public {
        uint256 tokenId = _fundAndBuy(1 ether);
        hoax(buyer, 10 ether);
        strategy.sellTargetNFT{value: strategy.askPrice(tokenId)}(tokenId);

        uint256 deadBefore = strategy.balanceOf(strategy.DEAD_ADDRESS());

        vm.warp(block.timestamp + 60);
        (uint256 spent,) = strategy.processBurn();

        assertGt(spent, 0);
        assertEq(router.ethReceived(), spent, "the router was paid what was spent");
        assertGt(strategy.balanceOf(strategy.DEAD_ADDRESS()), deadBefore, "and supply was destroyed");
    }

    /* ──────────────────────────── helpers ──────────────────────────── */

    function _fund(uint256 amount) private {
        vm.prank(hook);
        strategy.addFees{value: amount}();
    }

    function _fillCalldata(uint256 tokenId) private view returns (bytes memory) {
        return abi.encodeWithSignature("fulfill(address,uint256)", address(collection), tokenId);
    }

    function _listAndFill(uint256 price) private returns (uint256 tokenId) {
        tokenId = collection.mint(address(venue));
        strategy.buyTargetNFT(price, _fillCalldata(tokenId), tokenId, address(venue));
    }

    function _fundAndBuy(uint256 price) private returns (uint256 tokenId) {
        _fund(5 ether);
        vm.warp(block.timestamp + 200);
        tokenId = _listAndFill(price);
    }

    /* ────────────────────── delivery and config ────────────────────── */

    /**
     * @notice A collection that pretends to transfer is caught before the listing is cleared.
     * @dev A desk that deletes the entry first and ignores `transferFrom`'s outcome would, against
     * a collection like this, take the buyer's payment, leave the piece where it is, and destroy the
     * listing — nothing reverts, and the loss is silent. Transferring first and asserting ownership
     * afterwards makes that failure revert.
     */
    function test_SaleDetectsACollectionThatDoesNotDeliver() public {
        LyingCollection liar = new LyingCollection();
        SweepNFTStrategy s = new SweepNFTStrategy();
        s.initialize(
            _config(
                address(liar),
                address(router),
                "L",
                "L",
                hook,
                poolManager,
                BID_PER_SECOND,
                MAX_BID,
                MULTIPLIER,
                DECAY_WINDOW,
                owner
            )
        );

        vm.deal(hook, 10 ether);
        vm.prank(hook);
        s.addFees{value: 5 ether}();
        vm.warp(block.timestamp + 200);

        liar.mint(address(venue), 1);
        s.buyTargetNFT(
            1 ether, abi.encodeWithSignature("fulfill(address,uint256)", address(liar), uint256(1)), 1, address(venue)
        );

        liar.setLying(true);

        uint256 ask = s.askPrice(1);
        hoax(buyer, 10 ether);
        vm.expectRevert(SweepNFTStrategy.DeliveryFailed.selector);
        s.sellTargetNFT{value: ask}(1);
    }

    /// @notice A piece the desk never bought has no ask at all.
    function test_AskIsZeroForAPieceNotHeld() public view {
        assertEq(strategy.askPrice(4242), 0);
    }

    /// @notice A strategy with no collection could never buy anything.
    function test_InitRefusesAZeroCollection() public {
        SweepNFTStrategy fresh = new SweepNFTStrategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(
            _config(
                address(0),
                address(router),
                "n",
                "s",
                hook,
                poolManager,
                BID_PER_SECOND,
                MAX_BID,
                MULTIPLIER,
                DECAY_WINDOW,
                owner
            )
        );
    }

    /// @notice A strategy with no router could never burn what it earns.
    function test_InitRefusesAZeroBurnRouter() public {
        SweepNFTStrategy fresh = new SweepNFTStrategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(
            _config(
                address(collection),
                address(0),
                "n",
                "s",
                hook,
                poolManager,
                BID_PER_SECOND,
                MAX_BID,
                MULTIPLIER,
                DECAY_WINDOW,
                owner
            )
        );
    }

    /// @notice A markup below par would realise a loss on every completed cycle.
    function test_InitRefusesAMarkupBelowPar() public {
        SweepNFTStrategy fresh = new SweepNFTStrategy();
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        fresh.initialize(
            _config(
                address(collection),
                address(router),
                "n",
                "s",
                hook,
                poolManager,
                BID_PER_SECOND,
                MAX_BID,
                9000,
                DECAY_WINDOW,
                owner
            )
        );
    }

    /// @notice The router can be repointed, because the factory supplies the real one and routers get
    /// redeployed.
    function test_OwnerCanRepointTheBurnRouter() public {
        MockBurnRouter replacement = new MockBurnRouter();
        vm.prank(owner);
        strategy.setBurnRouter(address(replacement));
        assertEq(strategy.burnRouter(), address(replacement));
    }

    /// @notice Repointing at nothing would leave every burn reverting.
    function test_BurnRouterRefusesZero() public {
        vm.prank(owner);
        vm.expectRevert(SweepToken.InvalidConfiguration.selector);
        strategy.setBurnRouter(address(0));
    }

    /// @notice Only the owner may repoint it.
    function test_OnlyOwnerCanRepointTheBurnRouter() public {
        vm.prank(buyer);
        vm.expectRevert();
        strategy.setBurnRouter(address(router));
    }

    /// @notice The desk accepts pieces sent with a receiver callback.
    function test_DeskAcceptsSafeTransfers() public view {
        assertEq(
            strategy.onERC721Received(address(0), address(0), 0, ""),
            bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))
        );
    }

    /// @dev Builds the launch config field by field. `SweepNFTStrategy.initialize` takes a struct
    /// rather than eleven positional arguments precisely so that a caller cannot silently transpose
    /// two of the four addresses; this keeps the tests honest about that by naming each one.
    function _config(
        address collection_,
        address burnRouter_,
        string memory name_,
        string memory symbol_,
        address hook_,
        address poolManager_,
        uint256 bidIncreasePerSecond_,
        uint256 maxBid_,
        uint256 resaleMultiplierBps_,
        uint256 askDecayWindow_,
        address owner_
    ) internal pure returns (SweepNFTStrategy.Config memory config) {
        config.collection = collection_;
        config.burnRouter = burnRouter_;
        config.name = name_;
        config.symbol = symbol_;
        config.hook = hook_;
        config.poolManager = poolManager_;
        config.bidIncreasePerSecond = bidIncreasePerSecond_;
        config.maxBid = maxBid_;
        config.resaleMultiplierBps = resaleMultiplierBps_;
        config.askDecayWindow = askDecayWindow_;
        config.owner = owner_;
    }
}
