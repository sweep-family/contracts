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
    /// @dev **Zero by default.** A fixed ask is what ships. The decay is retained as a lever, off
    /// unless deliberately switched on.
    ///
    /// The cost of a fixed ask is real and known: when the floor falls below the ask, the piece
    /// becomes unsellable and the burn stops with it. Inventory accumulates, and nothing reaches
    /// the burn.
    ///
    /// The cost of a decaying ask is subtler and is why it stays off. The protocol buys below floor,
    /// so an ask decaying toward what it paid ends up **under** the floor — and the protocol becomes
    /// a competitor to the collection's own sellers, who are exactly the people it needs on side.
    /// Unsold inventory is a slower failure than antagonising the collection.
    uint256 public askDecayWindow;

    error NotForSale();
    error WrongPayment();

    event ResaleTermsUpdated(uint256 multiplierBps, uint256 decayWindow);
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
     * @dev A resale priced once, at purchase, and never moved becomes unsellable the moment the
     * floor falls below it. A fixed ask above a falling floor strands the inventory: the machine
     * keeps buying and stops selling, and every burn stops with it. The decay is the lever that
     * lets the ask follow the market down.
     *
     * @dev A zero window disables the decay entirely, and that is what ships. See `askDecayWindow`
     * for why the lever exists but stays off. A holding with no cost is not held, and asks zero.
     */
    function _askFor(Holding memory holding) internal view returns (uint256) {
        if (holding.cost == 0) return 0;

        uint256 peak = (holding.cost * resaleMultiplierBps) / BPS;
        if (askDecayWindow == 0) return peak;

        uint256 elapsed = block.timestamp - holding.acquiredAt;
        if (elapsed >= askDecayWindow) return holding.cost;

        return holding.cost + ((peak - holding.cost) * (askDecayWindow - elapsed)) / askDecayWindow;
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

    /// @notice Points the burn at a different router.
    /// @dev Exists because a router is the kind of dependency that gets redeployed.
    function setBurnRouter(address router) external onlyOwner {
        if (router == address(0)) revert InvalidConfiguration();
        burnRouter = router;
        emit BurnRouterUpdated(router);
    }

    /// @dev Buys this token on its own pool and sends it straight to the dead address.
    function _executeBurn(uint256 amountIn) internal override {
        ISweepBurnRouter(burnRouter).buyTokenWithEth{value: amountIn}(address(this), DEAD_ADDRESS);
    }

    /// @notice Accepts ETH from venues returning change and from buyers at the desk.
    receive() external payable {}
}
