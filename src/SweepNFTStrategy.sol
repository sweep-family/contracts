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

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {SweepDesk} from "./SweepDesk.sol";

/**
 * @title SweepNFTStrategy
 * @author 0xDAVZER
 * @notice The desk. Acquires NFTs from a collection's floor with the treasury, offers them on again
 * at a markup that decays, and turns what they fetch into destroyed supply.
 *
 * @dev Two functions, and they are not symmetric. Buying reaches into a world it cannot verify and
 * must prove afterwards what it received. Selling happens entirely at home, so it only has to be
 * ordered correctly.
 */
contract SweepNFTStrategy is SweepDesk {
    /// @notice Everything a strategy is wired to at birth, in one named place.
    ///
    /// @dev A struct rather than eleven positional arguments, four of which are addresses in a row.
    /// That signature is exactly the shape that gets wired to the wrong contract without anything
    /// failing to compile — and a launch is the one moment where a mistake is permanent, since a
    /// strategy is initialised once and its pool identity is fixed from that instant.
    struct Config {
        address collection;
        address burnRouter;
        string name;
        string symbol;
        address hook;
        address poolManager;
        uint256 bidIncreasePerSecond;
        uint256 maxBid;
        uint256 resaleMultiplierBps;
        uint256 askDecayWindow;
        address owner;
        address curve;
    }

    /// @notice The collection this strategy buys from.
    IERC721 public collection;

    /// @notice What the protocol paid for each piece it holds, and when.
    mapping(uint256 tokenId => Holding) public holdings;

    /// @dev Every piece on the shelf, enumerable so a purchase can prove afterwards that the
    /// whole inventory survived the venue's call, and so the shelf can be surfaced at all — an
    /// inventory kept only as a mapping is invisible to every market. `_heldIndexPlusOne` is the position
    /// in `_heldIds` plus one, so zero means "not held" without an existence flag of its own.
    uint256[] private _heldIds;
    mapping(uint256 tokenId => uint256 indexPlusOne) private _heldIndexPlusOne;

    error AlreadyOwned();
    error BidExceeded();
    error TargetIsCollection();
    error NothingDelivered();
    error WrongPieceDelivered();
    error VenueFailed(bytes reason);
    error NothingToSpend();
    error DeliveryFailed();

    event NFTPurchased(
        uint256 indexed tokenId, uint256 cost, address indexed venue, address indexed caller, uint256 openingAsk
    );
    event NFTSold(uint256 indexed tokenId, uint256 price, address indexed buyer, uint256 cost);

    /**
     * @notice Wires a strategy to its collection.
     * @dev The desk half (router, resale terms) is validated by `__SweepDesk_init`; a zero
     * collection is refused here because nothing below could ever buy from it.
     */
    function initialize(Config calldata config) external initializer {
        if (config.collection == address(0)) revert InvalidConfiguration();

        collection = IERC721(config.collection);
        __SweepCurve_init(config.curve);
        __SweepDesk_init(config.burnRouter, config.resaleMultiplierBps, config.askDecayWindow);

        __SweepStrategy_init(
            config.name,
            config.symbol,
            config.hook,
            config.poolManager,
            config.bidIncreasePerSecond,
            config.maxBid,
            config.owner
        );
    }

    /// @notice What a held piece currently costs to buy from the protocol: the desk's ask over its
    /// holding. The formula, and the failure it prevents, are explained on `SweepDesk._askFor`.
    function askPrice(uint256 tokenId) public view returns (uint256) {
        return _askFor(holdings[tokenId]);
    }

    /**
     * @notice Buys `expectedId` by executing `data` against `target`, paying at most `value`.
     *
     * @dev Permissionless and unrewarded, because the natural caller is the seller: they supply the
     * venue, the calldata and the piece, and they are already motivated by wanting the money. A
     * keeper bounty here would be paying for something that happens anyway.
     *
     * @dev The external call is arbitrary and cannot be verified in advance, so every guard is
     * either a bound on what may be spent or a proof of what arrived.
     *
     * `value <= currentBid()` keeps the spend inside the price the protocol has published, so a
     * caller cannot name their own. `target != collection` stops a collection owner pointing the
     * call at their own payable `mint` and selling the protocol freshly-created supply at the bid,
     * forever — it forces the purchase onto the secondary market. The balance check catches a venue
     * that takes the ETH and delivers nothing. The ownership check catches one that delivers a real
     * piece that is not the one paid for, which the balance check alone would accept, and is why
     * both exist. And the cost is measured as a balance delta rather than assumed to be `value`, so
     * a venue returning change is credited honestly.
     *
     * @dev The delta adds back whatever the treasury gained while the call was open. `addFees`
     * raises the balance and the treasury together, so without it a venue that trades the
     * strategy's own token before returning would have its fee counted twice: once as a credit,
     * once as a smaller cost. The ledger would then outgrow the money held, and two such purchases
     * with proceeds queued would leave `pendingBurn` above the balance and `processBurn` reverting
     * for good. Reading `treasury` on both sides of the call makes `cost` what the venue kept, and
     * nothing else.
     *
     * @dev `NothingToSpend` refuses a purchase that cost nothing, the same guard the bag desk
     * carries. Without it a venue that delivers the piece and refunds the whole price would reset
     * the bid ramp to zero and put a piece on the shelf that can never be sold, since a zero cost
     * is how "not held" is spelled in `holdings`. Anyone holding a piece
     * of the collection could do it at will and front-run a genuine seller into `BidExceeded`.
     */
    function buyTargetNFT(uint256 value, bytes calldata data, uint256 expectedId, address target)
        external
        nonReentrant
    {
        if (value > currentBid()) revert BidExceeded();
        if (target == address(collection)) revert TargetIsCollection();
        if (collection.ownerOf(expectedId) == address(this)) revert AlreadyOwned();

        uint256 ethBefore = address(this).balance;
        uint256 treasuryBefore = treasury;
        uint256 nftBefore = collection.balanceOf(address(this));

        (bool ok, bytes memory reason) = target.call{value: value}(data);
        if (!ok) revert VenueFailed(reason);

        if (collection.balanceOf(address(this)) != nftBefore + 1) revert NothingDelivered();
        if (collection.ownerOf(expectedId) != address(this)) revert WrongPieceDelivered();
        _assertInventoryIntact();

        uint256 cost = ethBefore + (treasury - treasuryBefore) - address(this).balance;
        if (cost == 0) revert NothingToSpend();
        _recordPurchase(cost);

        holdings[expectedId] = Holding({cost: cost, acquiredAt: block.timestamp});
        _addHolding(expectedId);

        emit NFTPurchased(expectedId, cost, target, msg.sender, askPrice(expectedId));
    }

    /**
     * @notice Buys a held piece from the protocol at its current ask.
     *
     * @dev The exact ask is required rather than at-least, so a buyer cannot overpay into a price
     * the protocol never quoted. Because the ask descends, the quote is only valid for the block it
     * was read in — a caller sending yesterday's price will simply be refused.
     *
     * @dev The transfer happens before the entry is cleared, and its result is checked by reading
     * `ownerOf` afterwards. Clearing first with an unchecked `transferFrom` would let a collection
     * that returns false rather than reverting take the buyer's ETH, keep the piece, and destroy
     * the listing in a single transaction.
     */
    function sellTargetNFT(uint256 tokenId) external payable nonReentrant {
        Holding memory holding = holdings[tokenId];
        if (holding.cost == 0) revert NotForSale();
        if (msg.value != askPrice(tokenId)) revert WrongPayment();

        collection.transferFrom(address(this), msg.sender, tokenId);
        if (collection.ownerOf(tokenId) != msg.sender) revert DeliveryFailed();

        delete holdings[tokenId];
        _removeHolding(tokenId);
        _recordSale(msg.value);

        emit NFTSold(tokenId, msg.value, msg.sender, holding.cost);
    }

    /// @notice Pieces currently on the shelf.
    /// @dev A view over the enumerable inventory rather than a counter of its own, so the two
    /// can never disagree. Keeps the selector the counter had, so nothing downstream changes.
    function inventoryCount() external view returns (uint256) {
        return _heldIds.length;
    }

    /// @notice Every piece on the shelf, by id. The board's inventory panel reads this.
    function heldTokenIds() external view returns (uint256[] memory) {
        return _heldIds;
    }

    /// @notice Accepts the pieces this desk buys.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev Proves the desk still owns every piece it held before a venue's arbitrary call
     *. The existing delivery checks count and identify what arrived; they say
     * nothing about what left. A collection with a pre-approved marketplace operator, or a
     * DN404-style token whose transfers move its NFTs, lets a crafted order deliver the expected
     * piece while lifting a held one — net count still plus one, expected piece still owned,
     * every old check green. Without this walk, that order sells the desk's best piece back to
     * the attacker for nothing. Linear in inventory, on a chain where gas is cheap; the walk
     * runs before the new piece is booked so it covers exactly the pieces the desk owned when
     * the call went out.
     */
    function _assertInventoryIntact() private view {
        uint256 count = _heldIds.length;
        for (uint256 i = 0; i < count; ++i) {
            if (collection.ownerOf(_heldIds[i]) != address(this)) revert InventoryBreached();
        }
    }

    /// @dev Books a piece into the enumerable inventory.
    function _addHolding(uint256 tokenId) private {
        _heldIds.push(tokenId);
        _heldIndexPlusOne[tokenId] = _heldIds.length;
    }

    /// @dev Removes a piece by swapping the last id into its slot, so removal stays O(1) and the
    /// array never holds gaps the intactness walk would trip on.
    function _removeHolding(uint256 tokenId) private {
        uint256 indexPlusOne = _heldIndexPlusOne[tokenId];
        uint256 lastIndex = _heldIds.length - 1;
        if (indexPlusOne != lastIndex + 1) {
            uint256 lastId = _heldIds[lastIndex];
            _heldIds[indexPlusOne - 1] = lastId;
            _heldIndexPlusOne[lastId] = indexPlusOne;
        }
        _heldIds.pop();
        delete _heldIndexPlusOne[tokenId];
    }
}
