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
    }

    /// @notice The collection this strategy buys from.
    IERC721 public collection;

    /// @notice What the protocol paid for each piece it holds, and when.
    mapping(uint256 tokenId => Holding) public holdings;

    /// @notice Pieces currently on the shelf.
    uint256 public inventoryCount;

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

        uint256 cost = ethBefore + (treasury - treasuryBefore) - address(this).balance;
        if (cost == 0) revert NothingToSpend();
        _recordPurchase(cost);

        holdings[expectedId] = Holding({cost: cost, acquiredAt: block.timestamp});
        ++inventoryCount;

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
        --inventoryCount;
        _recordSale(msg.value);

        emit NFTSold(tokenId, msg.value, msg.sender, holding.cost);
    }

    /// @notice Accepts the pieces this desk buys.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
