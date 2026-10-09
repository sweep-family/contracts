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
    /// whole inventory survived the venue's call, and so the shelf can be surfaced at all — the
    /// reference's inventory is invisible to every market. `_heldIndexPlusOne` is the position
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
    error StillHeld();
    error ProbeStarved();
    error LostPieceNotWrittenOff();
    error InventoryFull();

    /// @notice Gas the write-off's `ownerOf` probe is given. An honest `ownerOf` costs a few
    /// thousand; anything that needs more than this is treated as not answering.
    uint256 public constant OWNERSHIP_PROBE_GAS = 100_000;

    /// @notice Most pieces the shelf may hold; a purchase beyond it is refused (decision 0020).
    /// @dev Every purchase walks the whole shelf (`_assertInventoryIntact`), about 5.5k gas a
    /// piece cold. Unbounded, the 6 October 2026 mainnet fork put a purchase past the keeper's 20M
    /// gas cap near 3,600 pieces, after which the desk could never buy again. At 500 the last
    /// purchase allowed costs about 3M, measured in `DeskShelfBounds.t.sol`.
    uint256 public constant MAX_INVENTORY = 500;

    event NFTPurchased(
        uint256 indexed tokenId, uint256 cost, address indexed venue, address indexed caller, uint256 openingAsk
    );
    event NFTSold(uint256 indexed tokenId, uint256 price, address indexed buyer, uint256 cost);
    event PieceWrittenOff(uint256 indexed tokenId, uint256 cost, address indexed caller);

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
     * @dev The delta adds back whatever the treasury gained while the call was open, which is
     * finding 3 of the pre-mainnet review of 22 September 2026. `addFees` raises the balance and
     * the treasury together, so a venue that trades the strategy's own token before returning had
     * its fee counted twice: once as a credit, once as a smaller cost. The ledger then outgrew the
     * money held — 0.165 ETH booked against 0.083 actually there, on the fork — and two such
     * purchases with proceeds queued left `pendingBurn` above the balance and `processBurn`
     * reverting for good. Reading `treasury` on both sides of the call makes `cost` what the venue
     * kept, and nothing else.
     *
     * @dev `NothingToSpend` refuses a purchase that cost nothing, which is finding 4 of the same
     * review and the guard the bag desk always had. A venue that delivers the piece and refunds
     * the whole price reset the bid ramp to zero and put a piece on the shelf that can never be
     * sold, since a zero cost is how "not held" is spelled in `holdings`. Anyone holding a piece
     * of the collection could do it at will and front-run a genuine seller into `BidExceeded`.
     *
     * @dev `LostPieceNotWrittenOff` refuses a piece that still has a shelf entry, which is A-1 of
     * the audit of 4 October 2026. A piece can only have one while the desk does not own it if it
     * left outside a sale (a seizure, a burn, an upgraded collection), which is what `writeOff`
     * exists for. Bought back before that write-off, it got a second entry: the sale then removed
     * one entry and cleared `holdings`, the other named a piece the desk no longer owned, every
     * later purchase reverted `InventoryBreached`, and `writeOff` refused it as `NotForSale`, so
     * the desk could not buy again until `retire`. Write the piece off first; it can then be
     * bought back like any other.
     *
     * @dev `InventoryFull` refuses a purchase once the shelf holds `MAX_INVENTORY` pieces, and is
     * read first so a full desk refuses before any ETH moves. Without it the inventory walk grows
     * with every unsold piece until a purchase no longer fits any gas cap, and the desk can never
     * buy again (the 6 October 2026 fork finding). It is a pause, not a death: a resale or a
     * write-off frees a place, and the decaying ask is what brings the resale.
     */
    function buyTargetNFT(uint256 value, bytes calldata data, uint256 expectedId, address target)
        external
        nonReentrant
    {
        if (_heldIds.length >= MAX_INVENTORY) revert InventoryFull();
        if (value > currentBid()) revert BidExceeded();
        if (target == address(collection)) revert TargetIsCollection();
        if (collection.ownerOf(expectedId) == address(this)) revert AlreadyOwned();
        if (_heldIndexPlusOne[expectedId] != 0) revert LostPieceNotWrittenOff();

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
     * @dev The sale fills at the ask in force when it lands and refunds the rest (`_requireAsk`,
     * `_refundExcess`): the protocol never takes more than it quotes, and a buyer whose read is a
     * few seconds old, and so a little high, still buys. Below the ask is refused.
     *
     * @dev The transfer happens before the entry is cleared, and its result is checked. The
     * reference clears first and calls `transferFrom` unchecked while using a safe wrapper
     * everywhere else, so a collection that returns false rather than reverting would take the
     * buyer's ETH, keep the piece, and destroy the listing in a single transaction.
     */
    function sellTargetNFT(uint256 tokenId) external payable nonReentrant {
        Holding memory holding = holdings[tokenId];
        if (holding.cost == 0) revert NotForSale();
        uint256 ask = askPrice(tokenId);
        _requireAsk(ask);

        collection.transferFrom(address(this), msg.sender, tokenId);
        if (collection.ownerOf(tokenId) != msg.sender) revert DeliveryFailed();

        delete holdings[tokenId];
        _removeHolding(tokenId);
        _recordSale(ask);

        emit NFTSold(tokenId, ask, msg.sender, holding.cost);
        _refundExcess(ask);
    }

    /**
     * @notice Strikes from the shelf a piece the desk provably no longer holds, so the inventory
     * assertion stops refusing every purchase over it (decision 0017).
     *
     * @dev Exists because `_assertInventoryIntact` cannot tell a piece lifted during a purchase
     * from one the collection took away on its own: an admin burn, a seizure through an upgraded
     * implementation, an expired name. Without it one such piece refuses every purchase for good,
     * and the treasury behind it has no other spender. Permissionless, because no ETH moves and
     * the only thing it can remove is an entry the collection itself says is not the desk's.
     *
     * @dev `nonReentrant` is load-bearing. The inventory assertion exists to catch a venue that
     * lifts a held piece inside `buyTargetNFT`; were this callable from inside that call, the
     * venue could write the lifted piece off before the assertion looked for it.
     *
     * @dev `NotForSale` refuses an id that is not on the shelf. `StillHeld` refuses a piece the
     * collection still names the desk as owner of, whoever asks.
     */
    function writeOff(uint256 tokenId) external nonReentrant {
        Holding memory holding = holdings[tokenId];
        if (holding.cost == 0) revert NotForSale();
        if (_stillHolds(tokenId)) revert StillHeld();

        delete holdings[tokenId];
        _removeHolding(tokenId);

        emit PieceWrittenOff(tokenId, holding.cost, msg.sender);
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
     * (decision 0015). The existing delivery checks count and identify what arrived; they say
     * nothing about what left. A collection with a pre-approved marketplace operator, or a
     * DN404-style token whose transfers move its NFTs, lets a crafted order deliver the expected
     * piece while lifting a held one — net count still plus one, expected piece still owned,
     * every old check green. Without this walk, that order sells the desk's best piece back to
     * the attacker for nothing. Linear in inventory, which is why the shelf is capped at
     * `MAX_INVENTORY`; the walk runs before the new piece is booked so it covers exactly the
     * pieces the desk owned when the call went out.
     */
    function _assertInventoryIntact() private view {
        uint256 count = _heldIds.length;
        for (uint256 i = 0; i < count; ++i) {
            if (collection.ownerOf(_heldIds[i]) != address(this)) revert InventoryBreached();
        }
    }

    /**
     * @dev Asks the collection whether the desk still owns `tokenId`, inside a fixed gas budget,
     * reading at most one word of its answer. Anything but a clean word naming this desk counts
     * as not held: a revert, an empty or short answer, another address, or an `ownerOf` that
     * burns the whole budget.
     *
     * @dev `ProbeStarved` is what makes "reverted" trustworthy. A call is given at most 63/64 of
     * the gas left, so a caller sending just too little could starve an honest `ownerOf` into
     * failing and have a piece the desk still owns written off. Refusing to probe on less than
     * the budget needs, plus room to finish, means a failed probe is the collection's doing,
     * never the caller's.
     *
     * @dev The call is made in assembly so only the first word of return data is copied. A
     * high-level call copies all of it, and a collection returning megabytes could make every
     * write-off on it run out of gas.
     */
    function _stillHolds(uint256 tokenId) private view returns (bool held) {
        if (gasleft() < OWNERSHIP_PROBE_GAS + OWNERSHIP_PROBE_GAS / 63 + 10_000) revert ProbeStarved();
        address target = address(collection);
        uint256 budget = OWNERSHIP_PROBE_GAS;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x6352211e00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), tokenId)
            let ok := staticcall(budget, target, ptr, 0x24, ptr, 0x20)
            held := and(and(ok, gt(returndatasize(), 0x1f)), eq(mload(ptr), address()))
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
