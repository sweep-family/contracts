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
    }

    /// @notice The token this strategy buys.
    IERC20 public token;

    /// @notice What one bag holds, in the target's base units. Fixed for the life of the strategy.
    uint256 public bagSize;

    /// @notice The id of the last bag bought. Ids are sequential from one and never reused.
    uint256 public lastBagId;

    /// @notice Bags currently on the shelf.
    uint256 public bagsHeld;

    /// @notice What the protocol paid for each bag it holds, and when.
    mapping(uint256 bagId => Holding) public bags;

    error NothingToSpend();
    error BagNotDelivered();
    error InvalidRange();

    event BagBought(uint256 indexed bagId, uint256 cost, address indexed seller, uint256 openingAsk);
    event BagSold(uint256 indexed bagId, uint256 price, address indexed buyer, uint256 cost);

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
     * @dev Named from the desk's side: the desk buys tokens. The caller is the seller, must have
     * approved a bag to this contract, and is paid `currentBid()` — the smallest of the ramp, the
     * cap and the treasury — so the desk can never pay more than it holds or more than it has
     * published. Permissionless and unrewarded: the seller is already
     * motivated by wanting the money.
     *
     * @dev `NothingToSpend` refuses a purchase at zero rather than making one. A bag bought for
     * nothing would be listed at nothing, and a zero ask is how "not held" is spelled, so the bag
     * would sit on the shelf forever with no way to sell it.
     *
     * @dev The bag is measured, not assumed: `BagNotDelivered` unless the balance rose by exactly
     * `bagSize`. A fee-on-transfer or rebasing token delivers less than was sent, and a desk that
     * did not check would resell a bag it does not fully hold.
     *
     * @dev The seller is paid last and with `safeTransferETH`, not a forced variant:
     * a seller that cannot receive ETH gets a revert and keeps their bag, which is the honest
     * outcome; forcing the payment would strand it in a throwaway contract. The id is taken before
     * the transfer so a reverted purchase never burns one; `nonReentrant` keeps a receive hook on
     * the seller's side from selling a second bag inside the first sale's payment.
     */
    function buyTokens() external nonReentrant returns (uint256 bagId) {
        uint256 cost = currentBid();
        if (cost == 0) revert NothingToSpend();

        bagId = ++lastBagId;

        uint256 before = token.balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), bagSize);
        if (token.balanceOf(address(this)) - before != bagSize) revert BagNotDelivered();

        bags[bagId] = Holding({cost: cost, acquiredAt: block.timestamp});
        ++bagsHeld;
        _recordPurchase(cost);

        SafeTransferLib.safeTransferETH(msg.sender, cost);

        emit BagBought(bagId, cost, msg.sender, askPrice(bagId));
    }

    /**
     * @notice Buys a held bag from the protocol at its current ask.
     *
     * @dev The exact ask is required rather than at-least, so a buyer cannot overpay into a price
     * the protocol never quoted. Because the ask may descend, the quote is only valid for the block
     * it was read in — a caller sending yesterday's price will simply be refused.
     *
     * @dev The move is checked: `safeTransfer` reverts on a token that returns false, and the
     * revert takes the cleared entry and the queued proceeds with it. Unchecked, a lying token
     * would take the buyer's ETH, keep the bag, and destroy the listing in one transaction. With
     * the transfer checked and the function `nonReentrant`, the order of the clearing and the move
     * is convention rather than a guard: swapping them changes no observable outcome.
     */
    function sellTokens(uint256 bagId) external payable nonReentrant {
        Holding memory holding = bags[bagId];
        if (holding.cost == 0) revert NotForSale();
        if (msg.value != _askFor(holding)) revert WrongPayment();

        delete bags[bagId];
        --bagsHeld;
        SafeTransferLib.safeTransfer(address(token), msg.sender, bagSize);
        _recordSale(msg.value);

        emit BagSold(bagId, msg.value, msg.sender, holding.cost);
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
