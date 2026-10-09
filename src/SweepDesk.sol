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

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ISweepFactory, ISweepHooked} from "./interfaces/ISweepFactory.sol";
import {SweepStrategy} from "./SweepStrategy.sol";
import {ISweepBurnRouter} from "./interfaces/ISweepBurnRouter.sol";

/**
 * @title SweepDesk
 * @author 0xDAVZER
 * @notice What every desk has in common, whatever it buys: the record of what a holding cost, the
 * resale terms, the ask derived from them, and the road to the burn.
 *
 * @dev Two desks inherit this. The NFT desk holds pieces keyed by token id; the ERC-20 desk holds
 * bags keyed by a sequential id. The ask formula is the same for both and lives here once, so it is
 * tested once and cannot drift between them. Nothing here moves a piece or a bag: that is the one
 * thing the two desks do differently, and it stays with each of them.
 */
abstract contract SweepDesk is SweepStrategy {
    struct Holding {
        uint256 cost;
        uint256 acquiredAt;
    }

    /// @notice Where the burn's ETH is turned into this token.
    address public burnRouter;

    /// @notice Markup the resale opens at, in basis points of what was paid.
    uint256 public resaleMultiplierBps;

    /// @notice Seconds over which the ask falls from its markup back to what was paid.
    ///
    /// @dev **Three days at launch since 6 October 2026, decision 0020**, which supersedes
    /// decision 0004's fixed ask. The factory sets it from its own `askDecayWindow`.
    ///
    /// The cost of a fixed ask stopped being theoretical: when the floor falls below the ask, the
    /// piece becomes unsellable and the burn stops with it. Read live on ChimpStrategy — 355
    /// pieces held, about 9% of its collection, nothing pending burn — and then on our own mainnet
    /// fork, where the Hoodborn desk bought 54 floor pieces in 35 minutes that a 1.2x ask would
    /// never resell, with every purchase walking a longer shelf.
    ///
    /// The cost of a decaying ask is the one decision 0004 weighed: the protocol buys below floor,
    /// so an ask decaying toward what it paid can end up **under** the floor, competing with the
    /// collection's own sellers. Three days keeps the markup standing through most of a market
    /// cycle before it gives way. Zero still means a fixed ask, for a desk whose owner judges so.
    uint256 public askDecayWindow;

    error NotForSale();
    error WrongPayment();

    event ResaleTermsUpdated(uint256 multiplierBps, uint256 decayWindow);
    error RouterNotListed();
    error InventoryBreached();

    event BurnRouterUpdated(address router);

    /// @dev Wires the desk half of a strategy. A multiplier below `BPS` would list a holding for
    /// less than it cost, realising a loss on every cycle, so it is refused rather than discouraged;
    /// a zero router would make the first burn revert forever.
    function __SweepDesk_init(address burnRouter_, uint256 resaleMultiplierBps_, uint256 askDecayWindow_) internal {
        if (burnRouter_ == address(0)) revert InvalidConfiguration();
        if (resaleMultiplierBps_ < BPS) revert InvalidConfiguration();
        burnRouter = burnRouter_;
        resaleMultiplierBps = resaleMultiplierBps_;
        askDecayWindow = askDecayWindow_;
    }

    /**
     * @notice What a holding currently costs to buy from the protocol.
     *
     * @dev A descending auction, mirroring the ascending one on the buy side. It opens at the full
     * markup and falls back toward what the protocol paid, and it never goes below that — so a sale
     * is never a realised loss, only a smaller gain.
     *
     * @dev This is the fix for the reference's worst failure. It prices a resale once, at purchase,
     * and never moves it; when the floor falls below that number the piece becomes unsellable
     * forever, with no function to lower it. Observed live on ChimpStrategy: 355 pieces held, about
     * 9% of the whole collection, with nothing pending burn — the machine kept buying and stopped
     * selling, so the burn stopped entirely.
     *
     * @dev A zero window disables the decay entirely; the factory launches with three days. See
     * `askDecayWindow` for why. A holding with no cost is not held, and asks zero.
     */
    function _askFor(Holding memory holding) internal view returns (uint256) {
        if (holding.cost == 0) return 0;

        uint256 peak = (holding.cost * resaleMultiplierBps) / BPS;
        if (askDecayWindow == 0) return peak;

        uint256 elapsed = block.timestamp - holding.acquiredAt;
        if (elapsed >= askDecayWindow) return holding.cost;

        return holding.cost + ((peak - holding.cost) * (askDecayWindow - elapsed)) / askDecayWindow;
    }

    /**
     * @dev Refuses a sale paid below `ask`. Paid above is accepted: the ask descends every second,
     * so the amount a buyer read covers the ask in force when the sale lands, and the excess goes
     * back through `_refundExcess`. Demanding the exact ask refused every sale a wallet took more
     * than a second to sign, which was every sale made from the site (7 Oct 2026, mainnet preprod).
     */
    function _requireAsk(uint256 ask) internal view {
        if (msg.value < ask) revert WrongPayment();
    }

    /**
     * @dev Returns what a buyer sent above `ask`. Called last, after the sale is booked, so a buyer
     * that refuses ETH reverts its own purchase rather than leaving the excess with the desk; the
     * caller is `nonReentrant`, so the call cannot reach back into the desk.
     */
    function _refundExcess(uint256 ask) internal {
        if (msg.value > ask) SafeTransferLib.safeTransferETH(msg.sender, msg.value - ask);
    }

    /// @notice Retunes the resale terms for holdings bought from here on.
    /// @dev Applies to future purchases only in the sense that matters — the ask is recomputed on
    /// read, so a change moves every holding at once. That is deliberate: the alternative would
    /// leave old inventory stranded under terms the operator has already judged wrong.
    function setResaleTerms(uint256 multiplierBps, uint256 decayWindow) external onlyOwner {
        if (multiplierBps < BPS) revert InvalidConfiguration();
        resaleMultiplierBps = multiplierBps;
        askDecayWindow = decayWindow;
        emit ResaleTermsUpdated(multiplierBps, decayWindow);
    }

    /// @notice Points the burn at a different router, which must be one the factory lists.
    /// @dev Exists because a router is the kind of dependency that gets redeployed. The factory
    /// gate is decision 0015: without it this setter is a drain — point the burn at a contract
    /// that keeps the ETH and every queued sale proceeds is gone. Reached through the hook's
    /// immutable factory reference, so there is nothing here the owner can repoint first; the
    /// zero address is never listed, so the old zero check is subsumed rather than dropped.
    function setBurnRouter(address router) external onlyOwner {
        if (!ISweepFactory(ISweepHooked(hook).factory()).isRouter(router)) revert RouterNotListed();
        burnRouter = router;
        emit BurnRouterUpdated(router);
    }

    /// @dev Buys this token on its own pool and sends it straight to the dead address.
    /// @notice The burn router's live bound: a fixed share of the pool's ETH reserve.
    function _burnBound() internal view override returns (uint256) {
        return ISweepBurnRouter(burnRouter).maxBurnBuy(address(this));
    }

    function _executeBurn(uint256 amountIn) internal override {
        ISweepBurnRouter(burnRouter).buyTokenWithEth{value: amountIn}(address(this), DEAD_ADDRESS);
    }

    /// @notice Accepts ETH from venues returning change and from buyers at the desk.
    receive() external payable {}
}
