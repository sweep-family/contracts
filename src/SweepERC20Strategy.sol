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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {SweepDesk} from "./SweepDesk.sol";

/**
 * @title SweepERC20Strategy
 * @author 0xDAVZER
 * @notice The bag desk. Buys a fungible token by the bag with the treasury, offers each bag on
 * again at a markup, and turns what it fetches into destroyed supply.
 *
 * @dev The same machine as the NFT desk with a piece replaced by a bag: a fixed quantity of the
 * target token, decided at launch. Two things make this desk simpler than the other. There is no
 * venue and no arbitrary call, because the seller is `msg.sender` and the bag arrives by
 * `transferFrom`; and a bag has no identity, so the desk numbers them itself.
 */
contract SweepERC20Strategy is SweepDesk {
    /// @notice Everything a strategy is wired to at birth, in one named place.
    ///
    /// @dev A struct rather than twelve positional arguments, five of which are addresses. That
    /// signature is exactly the shape that gets wired to the wrong contract without anything
    /// failing to compile — and a launch is the one moment where a mistake is permanent.
    struct Config {
        address token;
        uint256 bagSize;
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

    /// @notice The token this strategy buys.
    IERC20 public token;

    /// @notice What one bag holds, in the target's base units. Fixed for the life of the strategy.
    uint256 public bagSize;

    /// @notice The id of the last bag bought. Ids are sequential from one and never reused.
    uint256 public lastBagId;

    /// @notice Bags currently on the shelf.
    uint256 public bagsHeld;

    /// @notice The target tokens all held bags sum to — what the desk's balance must always
    /// cover, checked after every external call that could have moved it (decision 0015).
    uint256 public heldBagTokens;

    /// @notice What the protocol paid for each bag it holds, and when.
    mapping(uint256 bagId => Holding) public bags;

    error NothingToSpend();
    error BagNotDelivered();
    error InvalidRange();
    error PriceBelowMinimum();
    error Expired();
    error NoShortfall();

    event BagBought(uint256 indexed bagId, uint256 cost, address indexed seller, uint256 openingAsk);
    event BagSold(uint256 indexed bagId, uint256 price, address indexed buyer, uint256 cost);
    event BagWrittenOff(uint256 indexed bagId, uint256 cost, address indexed caller);

    /**
     * @notice Wires a strategy to its target.
     * @dev A zero token could never be bought from; a zero bag would make every purchase a purchase
     * of nothing, listed at a real price. The desk half (router, resale terms) is validated by
     * `__SweepDesk_init`.
     */
    function initialize(Config calldata config) external initializer {
        if (config.token == address(0) || config.bagSize == 0) revert InvalidConfiguration();

        token = IERC20(config.token);
        bagSize = config.bagSize;
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

    /// @notice What a held bag currently costs to buy from the protocol: the desk's ask over its
    /// holding. The formula, and the failure it prevents, are explained on `SweepDesk._askFor`.
    function askPrice(uint256 bagId) public view returns (uint256) {
        return _askFor(bags[bagId]);
    }

    /**
     * @notice Sells one bag to the protocol, at the price it is publishing right now.
     *
     * @dev Named from the desk's side, as the reference names it: the desk buys tokens. The caller
     * is the seller, must have approved a bag to this contract, and is paid `currentBid()` — the
     * smallest of the ramp, the cap and the treasury — so the desk can never pay more than it
     * holds or more than it has published. Permissionless and unrewarded: the seller is already
     * motivated by wanting the money.
     *
     * @dev `NothingToSpend` refuses a purchase at zero rather than making one. A bag bought for
     * nothing would be listed at nothing, and a zero ask is how "not held" is spelled, so the bag
     * would sit on the shelf forever with no way to sell it. This is the reference's `NoZeroBuys`.
     *
     * @dev The bag is measured, not assumed: `BagNotDelivered` unless the balance rose by exactly
     * `bagSize`. A fee-on-transfer or rebasing token delivers less than was sent, and a desk that
     * did not check would resell a bag it does not fully hold.
     *
     * @dev The seller is paid last and with `safeTransferETH`, not the reference's forced variant:
     * a seller that cannot receive ETH gets a revert and keeps their bag, which is the honest
     * outcome; forcing the payment would strand it in a throwaway contract. The id is taken before
     * the transfer so a reverted purchase never burns one; `nonReentrant` keeps a receive hook on
     * the seller's side from selling a second bag inside the first sale's payment.
     *
     * @dev This form states no minimum and no deadline: it sells at whatever the bid is when it
     * lands. It is the bounded form with both bounds open, kept so existing callers still work.
     * A seller who cares what they receive uses `buyTokensBounded(minPrice, deadline)`.
     */
    function buyTokens() external nonReentrant returns (uint256 bagId) {
        return _buyTokens(0, type(uint256).max);
    }

    /**
     * @notice Sells one bag to the protocol, refusing anything below `minPrice` or after
     * `deadline` (SC-05 of the 2 October audit).
     *
     * @dev The bid restarts from zero after every purchase, and the seller cannot see where it
     * will stand when their transaction lands. Without a minimum, a seller whose sale lands a
     * second or two after a rival's gives up a whole bag for that second of bid, and a bot can
     * buy it straight back at the 1.2x ask. `PriceBelowMinimum` refuses such a sale and the
     * seller keeps the bag. `Expired` refuses one that sat waiting, as the swap router's
     * deadline does, so an offer made against yesterday's bid cannot execute today.
     *
     * @dev Named apart from `buyTokens()` rather than overloading it. An overload changes how
     * tools address the existing call: go-ethereum renames one of the pair `buyTokens0`, and a
     * typed client must disambiguate by arguments. A distinct name leaves every existing caller
     * of `buyTokens()` and every generated binding exactly as it was.
     */
    function buyTokensBounded(uint256 minPrice, uint256 deadline) external nonReentrant returns (uint256 bagId) {
        return _buyTokens(minPrice, deadline);
    }

    /**
     * @dev The purchase both forms share. Every guard but the two bounds is explained on
     * `buyTokens()`; the bounds are explained on `buyTokensBounded`. The bounds are
     * read before anything moves, so a refused sale costs the seller only gas.
     */
    function _buyTokens(uint256 minPrice, uint256 deadline) private returns (uint256 bagId) {
        if (block.timestamp > deadline) revert Expired();
        uint256 cost = currentBid();
        if (cost == 0) revert NothingToSpend();
        if (cost < minPrice) revert PriceBelowMinimum();

        bagId = ++lastBagId;

        uint256 before = token.balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), bagSize);
        if (token.balanceOf(address(this)) - before != bagSize) revert BagNotDelivered();

        bags[bagId] = Holding({cost: cost, acquiredAt: block.timestamp});
        ++bagsHeld;
        heldBagTokens += bagSize;
        _recordPurchase(cost);

        SafeTransferLib.safeTransferETH(msg.sender, cost);
        _assertBagsIntact();

        emit BagBought(bagId, cost, msg.sender, askPrice(bagId));
    }

    /**
     * @notice Buys a held bag from the protocol at its current ask.
     *
     * @dev The sale fills at the ask in force when it lands and refunds the rest (`_requireAsk`,
     * `_refundExcess`): the protocol never takes more than it quotes, and a buyer whose read is a
     * few seconds old, and so a little high, still buys. Below the ask is refused.
     *
     * @dev The move is checked: `safeTransfer` reverts on a token that returns false, and the
     * revert takes the cleared entry and the queued proceeds with it. The reference clears first
     * and calls `transfer` unchecked, so a lying token would take the buyer's ETH, keep the bag,
     * and destroy the listing in one transaction. With the transfer checked and the function
     * `nonReentrant`, the order of the clearing and the move is convention rather than a guard:
     * a mutation swapping them passes every test, which is the honest description of it.
     *
     * @dev A `true` return is not proof of delivery, so the buyer's balance is measured across
     * the send: `BagNotDelivered` unless it rose by at least `bagSize`, mirroring the buy side's
     * check. A target that reports success and moves nothing would otherwise take the buyer's
     * ETH and clear the bag from the books (finding 12 of the 22 September review). A target
     * that lies on `balanceOf` too is beyond any on-chain guard.
     */
    function sellTokens(uint256 bagId) external payable nonReentrant {
        Holding memory holding = bags[bagId];
        if (holding.cost == 0) revert NotForSale();
        uint256 ask = _askFor(holding);
        _requireAsk(ask);

        delete bags[bagId];
        --bagsHeld;
        heldBagTokens -= bagSize;
        uint256 before = token.balanceOf(msg.sender);
        SafeTransferLib.safeTransfer(address(token), msg.sender, bagSize);
        if (token.balanceOf(msg.sender) < before + bagSize) revert BagNotDelivered();
        _assertBagsIntact();
        _recordSale(ask);

        emit BagSold(bagId, ask, msg.sender, holding.cost);
        _refundExcess(ask);
    }

    /**
     * @notice Strikes one bag from the books while the desk's balance no longer covers them, so
     * the balance assertion stops refusing every purchase and every sale (decision 0017).
     *
     * @dev Exists because `_assertBagsIntact` cannot tell a balance drained during a call from one
     * the target shrank on its own: a negative rebase, a slashing, an issuer's wipe. One wei of
     * that refuses both paths for good, and the treasury behind them has no other spender. One bag
     * per call, chosen by the caller, until the books are covered again: every bag is the same
     * size, so which one goes changes only which cost basis the shelf keeps. Permissionless,
     * because no ETH and no token moves.
     *
     * @dev `nonReentrant` is load-bearing for the same reason as on the NFT desk: a seller's or a
     * buyer's transfer hook must not be able to write off the bags it is draining before the
     * assertion of the call it is inside looks at the balance.
     *
     * @dev `NotForSale` refuses a bag that is not on the shelf. `NoShortfall` refuses while the
     * balance still covers every bag, so nothing can be struck from a desk that is whole.
     */
    function writeOffBag(uint256 bagId) external nonReentrant {
        Holding memory holding = bags[bagId];
        if (holding.cost == 0) revert NotForSale();
        if (token.balanceOf(address(this)) >= heldBagTokens) revert NoShortfall();

        delete bags[bagId];
        --bagsHeld;
        heldBagTokens -= bagSize;

        emit BagWrittenOff(bagId, holding.cost, msg.sender);
    }

    /**
     * @dev Proves the desk's balance still covers every bag it holds, after any external call
     * that could have moved it (decision 0015). The per-purchase delta check counts what one
     * transferFrom delivered; it says nothing about a target token whose own transfer machinery
     * — a pre-approved operator, a DN404 twin, a callback on the seller's payment — can move
     * the desk's balance while control is outside. Without this, such a target empties the
     * shelf while every bag stays listed, and the first honest buyer pays real ETH for a bag
     * the desk no longer holds.
     */
    function _assertBagsIntact() private view {
        if (token.balanceOf(address(this)) < heldBagTokens) revert InventoryBreached();
    }

    /// @notice The ask of every bag from the first to the last ever bought, zero where sold.
    /// @dev Unbounded; a shelf with thousands of ids should read `list(start, end)` in pages.
    function list() external view returns (uint256[] memory asks) {
        return list(1, lastBagId);
    }

    /// @notice The ask of every bag with an id in `[startId, endId]`, zero where sold or never
    /// bought. `InvalidRange` for an inverted range, since it would size an array from an
    /// underflow.
    function list(uint256 startId, uint256 endId) public view returns (uint256[] memory asks) {
        if (endId < startId) revert InvalidRange();
        uint256 length = endId - startId + 1;
        asks = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            asks[i] = askPrice(startId + i);
        }
    }
}
