// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {MockStrategyHook} from "./mocks/MockStrategyHook.sol";
import {MockSweepFactory} from "./mocks/MockSweepFactory.sol";
import {MockBurnRouter} from "./mocks/MockBurnRouter.sol";
import {SweepStrategy} from "../src/SweepStrategy.sol";
import {SweepDesk} from "../src/SweepDesk.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";

/// @notice A collection whose admin can seize, burn, pause, or make `ownerOf` burn every unit of
/// gas it is given — the four ways a held piece stops answering for the desk (decision 0017).
contract AdminCollection is ERC721 {
    address public immutable admin;
    uint256 public next;
    bool public paused;
    mapping(uint256 => bool) public gasTrap;

    constructor() ERC721("Admin", "ADM") {
        admin = msg.sender;
    }

    function mint(address to) external returns (uint256 id) {
        id = ++next;
        _mint(to, id);
    }

    function seize(uint256 id, address to) external {
        _update(to, id, address(0));
    }

    function adminBurn(uint256 id) external {
        _burn(id);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setGasTrap(uint256 id, bool value) external {
        gasTrap[id] = value;
    }

    function ownerOf(uint256 id) public view override returns (address) {
        if (gasTrap[id]) {
            assembly {
                invalid()
            }
        }
        return super.ownerOf(id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (paused && msg.sender != admin) revert("paused");
        return super._update(to, id, auth);
    }
}

/// @notice Holds a piece and delivers it inside the desk's venue call.
contract PieceSeller {
    function deliver(IERC721 collection, uint256 id, address desk) external payable {
        collection.transferFrom(address(this), desk, id);
    }

    receive() external payable {}
}

/// @notice A target whose balances the test can shrink or freeze, as a rebase, a slashing or an
/// issuer's blocklist does.
contract FragileToken is ERC20 {
    mapping(address => bool) public blocked;

    function name() public pure override returns (string memory) {
        return "Fragile";
    }

    function symbol() public pure override returns (string memory) {
        return "FRG";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function shrink(address holder, uint256 amount) external {
        _burn(holder, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (blocked[from] || blocked[to]) revert("blocked");
    }
}

/// @notice A venue that lifts a valuable held piece through the collection, writes it off, and
/// delivers two cheap pieces so the desk's piece count still rises by exactly one: the shape the
/// inventory assertion exists to catch, with the write-off trying to hide the lift from it.
contract LiftAndWriteOffVenue {
    function fill(AdminCollection c, SweepNFTStrategy desk, uint256 held, uint256 fresh, uint256 extra)
        external
        payable
    {
        c.seize(held, address(this));
        desk.writeOff(held);
        c.transferFrom(address(this), address(desk), fresh);
        c.transferFrom(address(this), address(desk), extra);
    }

    receive() external payable {}
}

/// @notice A seller whose payment hook shrinks the desk's balance and tries to write a bag off
/// inside the purchase that pays it.
contract ShrinkAndWriteOffSeller {
    FragileToken internal immutable token;
    SweepERC20Strategy internal immutable desk;

    constructor(FragileToken token_, SweepERC20Strategy desk_) {
        token = token_;
        desk = desk_;
    }

    function sell() external {
        token.approve(address(desk), type(uint256).max);
        desk.buyTokens();
    }

    receive() external payable {
        token.shrink(address(desk), 1);
        desk.writeOffBag(1);
    }
}

/**
 * @title DeskExitsTest
 * @notice Decision 0017: a desk whose target breaks can write off what it lost, and a desk that
 * can no longer buy anything retires into the burn instead of holding its treasury forever.
 */
contract DeskExitsTest is Test {
    MockSweepFactory internal mockFactory = new MockSweepFactory(address(this));
    address internal hook = address(new MockStrategyHook(address(mockFactory), makeAddr("protocol")));
    MockBurnRouter internal router = new MockBurnRouter();
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant BID_PER_SECOND = 0.0001 ether;
    uint256 internal constant MAX_BID = 10 ether;
    uint256 internal constant BAG = 1000e18;

    function setUp() public {
        vm.warp(1_788_000_000);
        vm.deal(hook, 1000 ether);
        vm.deal(buyer, 1000 ether);
    }

    /* ───────────────────────── NFT desk: write-off ───────────────────────── */

    /// @notice A held piece seized by the collection blocks every purchase; writing it off puts the
    /// desk back in business with the rest of its shelf intact.
    function test_AWrittenOffPieceUnblocksPurchases() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 lost = _buyPiece(desk, c, 0.05 ether);
        uint256 kept = _buyPiece(desk, c, 0.05 ether);

        c.seize(lost, makeAddr("admin"));
        vm.warp(block.timestamp + 1000);
        uint256 fresh = c.mint(address(this));
        PieceSeller s = _sellerHolding(c, fresh);
        vm.expectRevert(SweepDesk.InventoryBreached.selector);
        desk.buyTargetNFT(0.05 ether, _deliver(c, fresh, desk), fresh, address(s));

        vm.prank(stranger);
        desk.writeOff(lost);

        desk.buyTargetNFT(0.05 ether, _deliver(c, fresh, desk), fresh, address(s));
        assertEq(desk.inventoryCount(), 2);
        (uint256 keptCost,) = desk.holdings(kept);
        (uint256 lostCost,) = desk.holdings(lost);
        assertGt(keptCost, 0, "the piece still held stays on the shelf");
        assertEq(lostCost, 0, "the lost piece is off the books");
    }

    /// @notice A held piece that left the desk outside a purchase cannot be bought back while its
    /// shelf entry is still there (A-1 of the 4 October audit). Before the guard the purchase went
    /// through and pushed a second entry for the same id; once the piece sold, the stale entry named
    /// a piece the desk no longer owned, every purchase reverted `InventoryBreached`, and
    /// `writeOff` refused it as `NotForSale`, leaving `retire` as the only exit.
    function test_ALostPieceCannotBeBoughtBackBeforeItIsWrittenOff() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 lost = _buyPiece(desk, c, 0.05 ether);
        _buyPiece(desk, c, 0.05 ether);

        PieceSeller relister = new PieceSeller();
        c.seize(lost, address(relister));
        vm.warp(block.timestamp + 1000);

        vm.expectRevert(SweepNFTStrategy.LostPieceNotWrittenOff.selector);
        desk.buyTargetNFT(0.05 ether, _deliver(c, lost, desk), lost, address(relister));
        assertEq(desk.heldTokenIds().length, 2, "no second entry for the lost piece");
    }

    /// @notice Once written off, the lost piece can be bought back like any other, with one shelf
    /// entry, and after it sells the desk keeps buying.
    function test_AWrittenOffPieceCanBeBoughtBackAndTheDeskKeepsBuying() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 lost = _buyPiece(desk, c, 0.05 ether);
        _buyPiece(desk, c, 0.05 ether);

        PieceSeller relister = new PieceSeller();
        c.seize(lost, address(relister));
        desk.writeOff(lost);
        vm.warp(block.timestamp + 1000);
        desk.buyTargetNFT(0.05 ether, _deliver(c, lost, desk), lost, address(relister));

        uint256[] memory shelf = desk.heldTokenIds();
        assertEq(shelf.length, 2, "one entry per piece");
        assertEq(c.balanceOf(address(desk)), 2);

        uint256 ask = desk.askPrice(lost);
        vm.prank(buyer);
        desk.sellTargetNFT{value: ask}(lost);
        assertEq(desk.heldTokenIds().length, 1, "the sale leaves no stale entry");

        vm.warp(block.timestamp + 1 days);
        uint256 fresh = c.mint(address(this));
        PieceSeller s = _sellerHolding(c, fresh);
        desk.buyTargetNFT(0.05 ether, _deliver(c, fresh, desk), fresh, address(s));
        assertEq(desk.inventoryCount(), 2);
    }

    /// @notice A piece burned by the collection's admin makes `ownerOf` revert, which a write-off
    /// reads as gone.
    function test_AnAdminBurnedPieceCanBeWrittenOff() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 lost = _buyPiece(desk, c, 0.05 ether);

        c.adminBurn(lost);
        desk.writeOff(lost);

        assertEq(desk.inventoryCount(), 0);
    }

    /// @notice An `ownerOf` that burns all the gas it is given is read as gone, inside the probe's
    /// fixed budget, rather than taking the whole write-off down with it.
    function test_AGasBurningOwnerOfCountsAsGone() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 lost = _buyPiece(desk, c, 0.05 ether);

        c.setGasTrap(lost, true);
        desk.writeOff{gas: 1_000_000}(lost);

        assertEq(desk.inventoryCount(), 0);
    }

    /// @notice A piece the desk still owns cannot be written off, by anyone.
    function test_WriteOffRefusesAPieceTheDeskStillHolds() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 held = _buyPiece(desk, c, 0.05 ether);

        vm.expectRevert(SweepNFTStrategy.StillHeld.selector);
        desk.writeOff(held);
    }

    /// @notice A piece that was never on the shelf, or already left it, has nothing to write off.
    function test_WriteOffRefusesAPieceNotOnTheShelf() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        vm.expectRevert(SweepDesk.NotForSale.selector);
        desk.writeOff(42);
    }

    /// @notice A caller cannot starve the probe into reading an honest `ownerOf` as a revert and
    /// strike a piece the desk still owns: with too little gas for the budget, it refuses to run.
    function test_WriteOffRefusesToRunOnAStarvedProbe() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 held = _buyPiece(desk, c, 0.05 ether);
        c.seize(held, makeAddr("admin"));
        c.seize(held, address(desk));

        vm.expectRevert(SweepNFTStrategy.ProbeStarved.selector);
        desk.writeOff{gas: 80_000}(held);

        assertEq(desk.inventoryCount(), 1, "the piece is still on the shelf");
    }

    /* ──────────────────────── bag desk: write-off ──────────────────────── */

    /// @notice A one-wei shrink of the desk's balance blocks every purchase and every sale; writing
    /// off one bag covers it, and the desk buys and sells again.
    function test_AShortfallCanBeWrittenOffAndTheDeskResumes() public {
        (SweepERC20Strategy desk, FragileToken t) = _bagDesk();
        _fund(address(desk), 20 ether);
        _buyBag(desk);
        uint256 kept = _buyBag(desk);

        t.shrink(address(desk), 1);
        vm.warp(block.timestamp + 100);
        vm.prank(seller);
        vm.expectRevert(SweepDesk.InventoryBreached.selector);
        desk.buyTokens();

        vm.prank(stranger);
        desk.writeOffBag(1);
        assertEq(desk.bagsHeld(), 1);
        assertEq(desk.heldBagTokens(), BAG);

        vm.prank(seller);
        desk.buyTokens();
        uint256 ask = desk.askPrice(kept);
        vm.prank(buyer);
        desk.sellTokens{value: ask}(kept);
        assertEq(desk.bagsHeld(), 1);
    }

    /// @notice With the books covered by the balance, no bag can be written off.
    function test_WriteOffBagRefusesWithoutAShortfall() public {
        (SweepERC20Strategy desk,) = _bagDesk();
        _fund(address(desk), 20 ether);
        uint256 bagId = _buyBag(desk);

        vm.expectRevert(SweepERC20Strategy.NoShortfall.selector);
        desk.writeOffBag(bagId);
    }

    /// @notice A bag that is not on the shelf cannot be written off.
    function test_WriteOffBagRefusesABagNotOnTheShelf() public {
        (SweepERC20Strategy desk, FragileToken t) = _bagDesk();
        _fund(address(desk), 20 ether);
        _buyBag(desk);
        t.shrink(address(desk), 1);

        vm.expectRevert(SweepDesk.NotForSale.selector);
        desk.writeOffBag(7);
    }

    /* ───────────────────────────── retirement ───────────────────────────── */

    /// @notice A desk that has published its whole bid for the grace period, on top of the time
    /// its ramp needed to get there, with nobody selling, is dead: its owner may retire it.
    function test_ADeskThatOfferedItsWholeBidThroughTheGraceRetires() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 5 ether);
        vm.warp(block.timestamp + _rampTo(5 ether) + desk.RETIRE_GRACE());

        vm.prank(owner);
        desk.retire();

        assertTrue(desk.retired());
        assertEq(desk.currentBid(), 0, "a retired desk offers nothing");
    }

    /// @notice Retirement is final, so only the owner may judge a desk dead: a stranger cannot
    /// retire even a desk that passes the test of death (4 October re-audit).
    function test_AStrangerCannotRetireADeskThatPassedTheTestOfDeath() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 5 ether);
        vm.warp(block.timestamp + _rampTo(5 ether) + desk.RETIRE_GRACE());

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        desk.retire();

        assertFalse(desk.retired(), "the desk is still alive");
        assertEq(desk.currentBid(), 5 ether, "and still offers its whole treasury");
    }

    /// @notice The case the gate exists for: a healthy desk saving toward a floor it cannot yet
    /// afford has a treasury the ramp passes within minutes, so a month without a purchase looks
    /// like death against `min(maxBid, treasury)`. Fees still arriving, a stranger must not be able
    /// to shut it for good.
    function test_AStrangerCannotRetireASavingDeskThatFeesStillReach() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 0.01 ether);
        vm.warp(block.timestamp + desk.RETIRE_GRACE() + 1 days);
        _fund(address(desk), 0.01 ether);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        desk.retire();

        assertFalse(desk.retired(), "a saving desk keeps saving");
        assertEq(desk.treasury(), 0.02 ether);
    }

    /// @notice The owner retires a desk that passes the test of death, and the event names the
    /// owner as the one who judged it dead.
    function test_TheOwnerRetiresADeskThatPassedTheTestOfDeath() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 5 ether);
        vm.warp(block.timestamp + _rampTo(5 ether) + desk.RETIRE_GRACE());

        vm.expectEmit(true, false, false, true, address(desk));
        emit SweepStrategy.Retired(owner, 5 ether);
        vm.prank(owner);
        desk.retire();

        assertTrue(desk.retired());
    }

    /// @notice A desk whose bid is still climbing toward what it holds is not dead, however long
    /// it has gone without buying.
    function test_ADeskWhoseBidIsStillClimbingCannotRetire() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 5 ether);
        vm.warp(block.timestamp + _rampTo(5 ether) + desk.RETIRE_GRACE() - 1);

        vm.prank(owner);
        vm.expectRevert(SweepStrategy.DeskStillBidding.selector);
        desk.retire();
    }

    /// @notice The grace is a floor: even a ramp that reaches its ceiling in seconds leaves the
    /// desk a month to find a seller.
    function test_ADeskCannotRetireInsideTheGrace() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 0.01 ether);
        vm.warp(block.timestamp + desk.RETIRE_GRACE() - 1);

        vm.prank(owner);
        vm.expectRevert(SweepStrategy.DeskStillBidding.selector);
        desk.retire();
    }

    /// @notice An empty treasury has nothing to retire — which also covers every desk still on
    /// its curve, since fees only arrive once the pool exists.
    function test_ADeskWithAnEmptyTreasuryCannotRetire() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        vm.warp(block.timestamp + 365 days);

        vm.prank(owner);
        vm.expectRevert(SweepStrategy.NothingToRetire.selector);
        desk.retire();
    }

    /// @notice Retirement happens once.
    function test_RetirementIsFinal() public {
        SweepNFTStrategy desk = _retiredNftDesk(5 ether);

        vm.prank(owner);
        vm.expectRevert(SweepStrategy.AlreadyRetired.selector);
        desk.retire();
    }

    /// @notice A retired NFT desk refuses every purchase, whatever the seller asks.
    function test_ARetiredNftDeskBuysNothing() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        vm.warp(block.timestamp + _rampTo(5 ether) + desk.RETIRE_GRACE());
        vm.prank(owner);
        desk.retire();

        uint256 fresh = c.mint(address(this));
        PieceSeller s = _sellerHolding(c, fresh);
        vm.expectRevert(SweepNFTStrategy.BidExceeded.selector);
        desk.buyTargetNFT(1, _deliver(c, fresh, desk), fresh, address(s));
    }

    /// @notice A bag desk frozen by its issuer's blocklist cannot write anything off — nothing is
    /// short — but it can retire, and a retired bag desk buys nothing.
    function test_ABlocklistedBagDeskRetiresAndBuysNothing() public {
        (SweepERC20Strategy desk, FragileToken t) = _bagDesk();
        _fund(address(desk), 5 ether);
        _buyBag(desk);
        t.setBlocked(address(desk), true);

        vm.warp(block.timestamp + _rampTo(desk.treasury()) + desk.RETIRE_GRACE());
        vm.prank(owner);
        desk.retire();

        vm.prank(seller);
        vm.expectRevert(SweepERC20Strategy.NothingToSpend.selector);
        desk.buyTokens();
    }

    /// @notice A retired treasury reaches the burn one pass at a time: each `processBurn` tops the
    /// queue up to at most one increment, so the backlog a front-runner can see never exceeds a
    /// single pass, and the pacing that bounds every burn bounds this one.
    function test_ARetiredTreasuryReachesTheBurnOnePassAtATime() public {
        SweepNFTStrategy desk = _retiredNftDesk(1 ether);
        uint256 increment = desk.burnIncrement();

        assertEq(desk.pendingBurn(), 0, "retiring moves nothing by itself");

        desk.processBurn();
        assertEq(desk.treasury(), 1 ether - increment);
        assertEq(desk.pendingBurn(), 0, "one increment released, one increment burned");
        assertEq(address(desk).balance, desk.treasury() + desk.pendingBurn());

        vm.expectRevert(SweepStrategy.BurnCooldownNotElapsed.selector);
        desk.processBurn();

        for (uint256 i = 1; i < 1 ether / increment; ++i) {
            vm.warp(block.timestamp + desk.burnCooldown());
            desk.processBurn();
        }
        assertEq(desk.treasury(), 0, "the whole treasury reached the burn");
        assertEq(router.ethReceived() * 10_000 / 9950, 1 ether, "less only the caller's bounty");
    }

    /// @notice A pass bounded by the pool's depth leaves the rest of the released increment queued
    /// rather than releasing more on top of it.
    function test_ARetiredReleaseNeverStacksAboveOnePass() public {
        SweepNFTStrategy desk = _retiredNftDesk(1 ether);
        uint256 increment = desk.burnIncrement();
        router.setDepthBound(increment / 4);

        desk.processBurn();
        assertEq(desk.pendingBurn(), increment - increment / 4);

        vm.warp(block.timestamp + desk.burnCooldown());
        desk.processBurn();
        assertEq(desk.pendingBurn() + increment / 4, increment, "topped up to one pass, no more");
        assertEq(desk.treasury(), 1 ether - increment - increment / 4);
    }

    /// @notice Fees that keep arriving after retirement drain into the burn the same way.
    function test_FeesAfterRetirementAlsoReachTheBurn() public {
        SweepNFTStrategy desk = _retiredNftDesk(0.05 ether);
        _fund(address(desk), 0.05 ether);

        desk.processBurn();
        vm.warp(block.timestamp + desk.burnCooldown());
        vm.expectRevert(SweepStrategy.NothingToBurn.selector);
        desk.processBurn();
        assertEq(desk.treasury(), 0);
    }

    /// @notice A retired desk still sells what it holds, and the proceeds still burn.
    function test_ARetiredDeskStillSellsItsShelfIntoTheBurn() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 held = _buyPiece(desk, c, 0.05 ether);
        vm.warp(block.timestamp + _rampTo(desk.treasury()) + desk.RETIRE_GRACE());
        vm.prank(owner);
        desk.retire();

        uint256 ask = desk.askPrice(held);
        vm.prank(buyer);
        desk.sellTargetNFT{value: ask}(held);

        assertEq(c.ownerOf(held), buyer);
        assertEq(desk.pendingBurn(), ask);
    }

    /// @notice Writing off is locked against reentry: a venue that lifts a held piece and writes
    /// it off inside the purchase is refused, and the piece stays on the shelf for the assertion.
    function test_AVenueCannotWriteOffThePieceItLifts() public {
        (SweepNFTStrategy desk, AdminCollection c) = _nftDesk();
        _fund(address(desk), 5 ether);
        uint256 held = _buyPiece(desk, c, 0.05 ether);
        LiftAndWriteOffVenue venue = new LiftAndWriteOffVenue();
        uint256 fresh = c.mint(address(venue));
        uint256 extra = c.mint(address(venue));
        vm.warp(block.timestamp + 1000);

        vm.expectRevert();
        desk.buyTargetNFT(
            0.05 ether, abi.encodeCall(LiftAndWriteOffVenue.fill, (c, desk, held, fresh, extra)), fresh, address(venue)
        );

        assertEq(c.ownerOf(held), address(desk), "the lift was undone with the purchase");
        assertEq(desk.inventoryCount(), 1);
    }

    /// @notice The bag desk's write-off is locked the same way: a seller's payment hook cannot
    /// shrink the balance and strike a bag inside the purchase that pays it.
    function test_ASellerCannotWriteOffABagInsideItsSale() public {
        (SweepERC20Strategy desk, FragileToken t) = _bagDesk();
        _fund(address(desk), 20 ether);
        _buyBag(desk);
        ShrinkAndWriteOffSeller rogue = new ShrinkAndWriteOffSeller(t, desk);
        t.mint(address(rogue), BAG);
        vm.warp(block.timestamp + 100);

        vm.expectRevert();
        rogue.sell();

        assertEq(desk.bagsHeld(), 1);
    }

    /// @notice Lowering the bid is the owner's brake, and it must not make a desk retirable:
    /// against a lowered ceiling a braked desk looks as though it has offered everything.
    /// `retire` waits the whole grace after any change to the bid terms.
    function test_BrakingADeskDoesNotMakeItRetirable() public {
        (SweepNFTStrategy desk,) = _nftDesk();
        _fund(address(desk), 5 ether);
        vm.warp(block.timestamp + desk.RETIRE_GRACE());
        uint256 minimum = desk.MIN_BID_INCREASE_PER_SECOND();
        vm.prank(owner);
        desk.setBidParameters(minimum, 1);
        vm.warp(block.timestamp + 1 days);

        vm.prank(owner);
        vm.expectRevert(SweepStrategy.DeskStillBidding.selector);
        desk.retire();
    }

    /* ─────────────────────────────── helpers ─────────────────────────────── */

    function _nftDesk() private returns (SweepNFTStrategy desk, AdminCollection c) {
        c = new AdminCollection();
        desk = SweepNFTStrategy(payable(LibClone.clone(address(new SweepNFTStrategy()))));
        SweepNFTStrategy.Config memory config;
        config.collection = address(c);
        config.burnRouter = address(router);
        config.name = "Exit";
        config.symbol = "EXIT";
        config.hook = hook;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = BID_PER_SECOND;
        config.maxBid = MAX_BID;
        config.resaleMultiplierBps = 12_000;
        config.askDecayWindow = 0;
        config.owner = owner;
        config.curve = makeAddr("curve");
        desk.initialize(config);
        _stockRouter(address(desk));
    }

    function _bagDesk() private returns (SweepERC20Strategy desk, FragileToken t) {
        t = new FragileToken();
        desk = SweepERC20Strategy(payable(LibClone.clone(address(new SweepERC20Strategy()))));
        SweepERC20Strategy.Config memory config;
        config.token = address(t);
        config.bagSize = BAG;
        config.burnRouter = address(router);
        config.name = "Bag Exit";
        config.symbol = "bEXIT";
        config.hook = hook;
        config.poolManager = makeAddr("poolManager");
        config.bidIncreasePerSecond = BID_PER_SECOND;
        config.maxBid = MAX_BID;
        config.resaleMultiplierBps = 12_000;
        config.askDecayWindow = 0;
        config.owner = owner;
        config.curve = makeAddr("curve");
        desk.initialize(config);
        _stockRouter(address(desk));

        t.mint(seller, 100 * BAG);
        vm.prank(seller);
        t.approve(address(desk), type(uint256).max);
    }

    function _retiredNftDesk(uint256 treasury) private returns (SweepNFTStrategy desk) {
        (desk,) = _nftDesk();
        _fund(address(desk), treasury);
        vm.warp(block.timestamp + _rampTo(treasury) + desk.RETIRE_GRACE());
        vm.prank(owner);
        desk.retire();
    }

    function _stockRouter(address desk) private {
        vm.prank(owner);
        SweepStrategy(payable(desk)).setDistributor(address(this), true);
        SweepStrategy(payable(desk)).transfer(address(router), 500_000_000e18);
    }

    function _fund(address desk, uint256 amount) private {
        vm.prank(hook);
        SweepStrategy(payable(desk)).addFees{value: amount}();
    }

    function _rampTo(uint256 amount) private pure returns (uint256) {
        return (amount + BID_PER_SECOND - 1) / BID_PER_SECOND;
    }

    function _sellerHolding(AdminCollection c, uint256 id) private returns (PieceSeller s) {
        s = new PieceSeller();
        c.transferFrom(address(this), address(s), id);
    }

    function _deliver(AdminCollection c, uint256 id, SweepNFTStrategy desk) private pure returns (bytes memory) {
        return abi.encodeCall(PieceSeller.deliver, (IERC721(address(c)), id, address(desk)));
    }

    function _buyPiece(SweepNFTStrategy desk, AdminCollection c, uint256 price) private returns (uint256 id) {
        vm.warp(block.timestamp + _rampTo(price));
        id = c.mint(address(this));
        PieceSeller s = _sellerHolding(c, id);
        desk.buyTargetNFT(price, _deliver(c, id, desk), id, address(s));
    }

    function _buyBag(SweepERC20Strategy desk) private returns (uint256 bagId) {
        vm.warp(block.timestamp + 100);
        vm.prank(seller);
        bagId = desk.buyTokens();
    }
}
