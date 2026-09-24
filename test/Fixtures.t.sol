// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    sweeping the floor, one cycle at a time
*/

import {Test} from "forge-std/Test.sol";

import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {SweepTestToken} from "../src/testing/SweepTestToken.sol";
import {MockMarketplace} from "./mocks/MockMarketplace.sol";
import {HostileMarketplace, Betrayal} from "./mocks/HostileMarketplace.sol";

/**
 * @title FixturesTest
 * @author 0xDAVZER
 * @notice Pins the behaviour every later contract assumes of its test fixtures.
 *
 * @dev These are not tests of the protocol. They are tests of the instruments the protocol will be
 * measured with, and they exist first because the protocol's most dangerous function makes an
 * arbitrary external call and can only prove after the fact that it received what it paid for.
 * Each guard around that call answers one specific betrayal; a guard nobody has watched fire is a
 * line of code we believe in rather than one we know. So the liars come before the guards.
 */
contract FixturesTest is Test {
    SweepTestCollection internal collection;
    MockMarketplace internal market;
    HostileMarketplace internal hostile;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal protocol = makeAddr("protocol");

    function setUp() public {
        collection = new SweepTestCollection("Phantom Brokers", "PHANTOM", "ipfs://phantom/");
        market = new MockMarketplace();
        hostile = new HostileMarketplace();
    }

    /**
     * @notice The launch factory gates on exactly this interface id and rejects everything else.
     * @dev It is also why CryptoPunks can never use a generic NFT strategy: Punks predate ERC-721
     * and implement no `supportsInterface` at all, so they would need a bespoke strategy of their
     * own. A fixture failing this would make every later launch test revert for a reason
     * that looks unrelated to the collection.
     */
    /// @notice `tokenURI` is the base followed by the decimal id, which is the scheme of the real
    /// collections a phantom one borrows its pictures from. A fixture that rendered blanks would hide
    /// every layout bug behind the wrong one.
    function test_CollectionTokenUriIsBasePlusId() public {
        uint256 tokenId = collection.mint(address(this));
        assertEq(collection.tokenURI(tokenId), string.concat("ipfs://phantom/", vm.toString(tokenId)));
    }

    function test_CollectionAnswersERC721InterfaceId() public view {
        assertTrue(collection.supportsInterface(0x80ac58cd), "must present as ERC-721");
    }

    /// @notice Minting assigns real ownership, since every later assertion reads `ownerOf`.
    function test_MintAssignsOwnership() public {
        uint256 tokenId = collection.mint(seller);
        assertEq(collection.ownerOf(tokenId), seller);
        assertEq(collection.balanceOf(seller), 1);
    }

    /**
     * @notice A batch mint produces distinct, sequential ids.
     * @dev StonkBrokers has 4,444 pieces on Robinhood Chain. A fixture that can only mint one at a
     * time cannot reproduce the shape of a real collection, and the shape matters — a strategy
     * holding 9% of its collection behaves nothing like one holding a single piece.
     */
    function test_BatchMintProducesDistinctIds() public {
        (uint256 firstId, uint256 lastId) = collection.mintBatch(seller, 100);

        assertEq(lastId - firstId + 1, 100, "range must cover the quantity");
        assertEq(collection.balanceOf(seller), 100);
        assertEq(collection.ownerOf(firstId), seller);
        assertEq(collection.ownerOf(lastId), seller);
        assertEq(collection.totalSupply(), 100);
    }

    /// @notice Ids never collide across separate mints, so a test can hold two distinct pieces.
    function test_MintAfterBatchContinuesTheSequence() public {
        (, uint256 lastId) = collection.mintBatch(seller, 10);
        uint256 next = collection.mint(buyer);
        assertEq(next, lastId + 1);
    }

    /**
     * @notice The happy path everything downstream assumes: pay the exact price, receive the exact
     * piece, and the seller is paid.
     * @dev The venue pulls from the seller on fill rather than escrowing, which is how Seaport
     * actually behaves — the NFT stays with its owner until the moment of sale.
     */
    function test_MarketplaceDeliversExactlyOnePayingExactly() public {
        uint256 tokenId = collection.mint(seller);

        vm.startPrank(seller);
        collection.setApprovalForAll(address(market), true);
        market.list(address(collection), tokenId, 3.5 ether);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        hoax(buyer, 10 ether);
        market.fulfill{value: 3.5 ether}(address(collection), tokenId);

        assertEq(collection.ownerOf(tokenId), buyer, "buyer receives the piece");
        assertEq(seller.balance, sellerBefore + 3.5 ether, "seller is paid in full");
    }

    /// @notice Underpaying is refused, so a test can never accidentally buy below the listed price.
    function test_MarketplaceRefusesWrongPayment() public {
        uint256 tokenId = collection.mint(seller);

        vm.startPrank(seller);
        collection.setApprovalForAll(address(market), true);
        market.list(address(collection), tokenId, 3.5 ether);
        vm.stopPrank();

        hoax(buyer, 10 ether);
        vm.expectRevert(MockMarketplace.WrongPayment.selector);
        market.fulfill{value: 3.4 ether}(address(collection), tokenId);
    }

    /**
     * @notice A venue can take the money and send nothing.
     * @dev This is the betrayal the balance-delta guard answers: comparing the NFT balance before
     * and after the external call is the only way to know an arbitrary call actually delivered.
     */
    function test_VenueDeliveringNothingLeavesBalanceUnchanged() public {
        uint256 tokenId = collection.mint(address(hostile));
        hostile.setBetrayal(Betrayal.DeliverNothing);

        uint256 balanceBefore = collection.balanceOf(protocol);
        hoax(protocol, 10 ether);
        hostile.fulfill{value: 3.5 ether}(address(collection), tokenId);

        assertEq(collection.balanceOf(protocol), balanceBefore, "nothing was delivered");
    }

    /**
     * @notice A venue can deliver a real piece that is not the one requested.
     * @dev This is the betrayal that justifies two guards instead of one. The balance check passes
     * here — a piece genuinely did arrive — so a contract that only counted would accept the
     * substitution. Only asserting ownership of the *expected* id catches it. Without this test,
     * writing the balance check alone looks entirely reasonable.
     */
    function test_VenueDeliveringWrongIdStillIncrementsBalance() public {
        uint256 wanted = collection.mint(address(hostile));
        uint256 substitute = collection.mint(address(hostile));

        hostile.setBetrayal(Betrayal.DeliverWrongId);
        hostile.setSubstitute(substitute);

        hoax(protocol, 10 ether);
        hostile.fulfill{value: 3.5 ether}(address(collection), wanted);

        assertEq(collection.balanceOf(protocol), 1, "the balance check would pass");
        assertEq(collection.ownerOf(substitute), protocol, "but we got the wrong piece");
        assertEq(collection.ownerOf(wanted), address(hostile), "the one we paid for never moved");
    }

    /**
     * @notice A venue that reverts after taking payment costs nothing.
     * @dev The revert unwinds the transfer with everything else, which is why the purchase path can
     * treat a failed call as a non-event rather than needing to claw funds back.
     */
    function test_VenueRevertingReturnsTheEth() public {
        uint256 tokenId = collection.mint(address(hostile));
        hostile.setBetrayal(Betrayal.TakeAndRevert);

        vm.deal(protocol, 10 ether);
        uint256 balanceBefore = protocol.balance;

        vm.prank(protocol);
        vm.expectRevert(HostileMarketplace.Betrayed.selector);
        hostile.fulfill{value: 3.5 ether}(address(collection), tokenId);

        assertEq(protocol.balance, balanceBefore, "the revert unwound the payment");
    }

    /**
     * @notice A venue can call back into its caller mid-purchase.
     * @dev Nothing to reenter into yet, so this only pins that the callback fires and is
     * observable. `NFTStrategy.t.sol` points it at the strategy, where the reentrancy guard has to stop it.
     */
    function test_VenueCanReenterItsCaller() public {
        uint256 tokenId = collection.mint(address(hostile));
        ReentryProbe probe = new ReentryProbe();

        hostile.setBetrayal(Betrayal.Reenter);
        hostile.setReentryTarget(address(probe));

        hoax(protocol, 10 ether);
        hostile.fulfill{value: 3.5 ether}(address(collection), tokenId);

        assertTrue(probe.wasCalled(), "the venue reentered");
    }

    /**
     * @notice A batch of zero is refused rather than silently doing nothing.
     * @dev A no-op mint would leave a test asserting against a collection that was never populated,
     * and the failure would surface later as a confusing `ownerOf` revert on a piece that does not
     * exist.
     */
    function test_BatchMintRefusesZeroQuantity() public {
        vm.expectRevert(SweepTestCollection.InvalidQuantity.selector);
        collection.mintBatch(seller, 0);
    }

    /**
     * @notice A batch above the cap is refused up front.
     * @dev The bound exists so a mistyped quantity fails immediately instead of consuming a whole
     * block of gas and reverting at the end, which on a 101 ms chain is a genuinely confusing way
     * to fail.
     */
    function test_BatchMintRefusesAboveMaxBatch() public {
        uint256 tooMany = collection.MAX_BATCH() + 1;
        vm.expectRevert(SweepTestCollection.InvalidQuantity.selector);
        collection.mintBatch(seller, tooMany);
    }

    /**
     * @notice A zero-priced listing is refused.
     * @dev The listing mapping defaults to zero, so a zero price would be indistinguishable from an
     * absent listing and `fulfill` could never tell the two apart.
     */
    function test_ListingRefusesZeroPrice() public {
        uint256 tokenId = collection.mint(seller);
        vm.prank(seller);
        vm.expectRevert(MockMarketplace.ZeroPrice.selector);
        market.list(address(collection), tokenId, 0);
    }

    /// @notice Buying something that was never listed is refused rather than accepted for free.
    function test_FulfillRefusesUnlistedPiece() public {
        uint256 tokenId = collection.mint(seller);
        hoax(buyer, 10 ether);
        vm.expectRevert(MockMarketplace.NotListed.selector);
        market.fulfill{value: 1 ether}(address(collection), tokenId);
    }

    /**
     * @notice The same piece cannot be bought twice.
     * @dev The listing is cleared before the transfer and before the payout, so a collection or a
     * seller that reenters finds nothing left to buy.
     */
    function test_FulfillClearsTheListing() public {
        uint256 tokenId = collection.mint(seller);
        vm.startPrank(seller);
        collection.setApprovalForAll(address(market), true);
        market.list(address(collection), tokenId, 1 ether);
        vm.stopPrank();

        hoax(buyer, 10 ether);
        market.fulfill{value: 1 ether}(address(collection), tokenId);

        hoax(buyer, 10 ether);
        vm.expectRevert(MockMarketplace.NotListed.selector);
        market.fulfill{value: 1 ether}(address(collection), tokenId);
    }

    /// @notice A substitution with no substitute configured fails loudly, not silently.
    function test_SubstitutionRequiresASubstitute() public {
        uint256 tokenId = collection.mint(address(hostile));
        hostile.setBetrayal(Betrayal.DeliverWrongId);

        hoax(protocol, 10 ether);
        vm.expectRevert(HostileMarketplace.NoSubstituteSet.selector);
        hostile.fulfill{value: 1 ether}(address(collection), tokenId);
    }

    /// @notice A reentry with no target configured fails loudly, not silently.
    function test_ReentryRequiresATarget() public {
        uint256 tokenId = collection.mint(address(hostile));
        hostile.setBetrayal(Betrayal.Reenter);

        hoax(protocol, 10 ether);
        vm.expectRevert(HostileMarketplace.NoReentryTargetSet.selector);
        hostile.fulfill{value: 1 ether}(address(collection), tokenId);
    }

    /// @notice With no betrayal configured the hostile venue behaves exactly like the honest one,
    /// so a test can use it as a baseline before switching a mode on.
    function test_HostileVenueIsHonestByDefault() public {
        uint256 tokenId = collection.mint(address(hostile));

        hoax(protocol, 10 ether);
        hostile.fulfill{value: 1 ether}(address(collection), tokenId);

        assertEq(collection.ownerOf(tokenId), protocol);
    }
}

/// @notice Minimal witness that records a call, so the reentrancy path is observable before the
/// strategy that will have to defend against it exists.
contract ReentryProbe {
    bool public wasCalled;

    /// @notice Records that the venue called back into us.
    fallback() external payable {
        wasCalled = true;
    }
}

/**
 * @title TestTokenTest
 * @author 0xDAVZER
 * @notice Pins what the factory and the desk rely on from the phantom token: an owner, a supply
 * to size a bag from, and minting reserved to the owner.
 */
contract TestTokenTest is Test {
    SweepTestToken internal token;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        token = new SweepTestToken("Phantom Coin", "PHC");
    }

    function test_DeployerOwnsItAndHoldsTheWholeSupply() public view {
        assertEq(token.owner(), address(this));
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(address(this)), token.INITIAL_SUPPLY());
        assertEq(token.decimals(), 18);
    }

    function test_OnlyTheOwnerMints() public {
        token.mint(stranger, 1e18);
        assertEq(token.balanceOf(stranger), 1e18);

        vm.prank(stranger);
        vm.expectRevert();
        token.mint(stranger, 1e18);
    }
}
