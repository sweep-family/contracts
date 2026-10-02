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

import {Initializable} from "solady/src/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {SweepCurveMath} from "./libraries/SweepCurveMath.sol";
import {ISweepCurveHook, ISweepCurveToken} from "./interfaces/ISweepBondingCurve.sol";

/**
 * @title SweepBondingCurve
 * @author 0xDAVZER
 * @notice The launch market. One clone per launch holds the strategy token's entire supply and
 * trades it against a virtual 1.68 ETH reserve until 4.2 ETH of real ETH has come in; the buy
 * that crosses the line graduates the launch, and the factory then moves everything here into
 * the strategy's Uniswap v4 pool at this curve's exact final price.
 *
 * @dev The quote asset is fixed to native ETH. That single narrowing removes any need for
 * fee-on-transfer accounting, blocklist failure modes, and the owner rescue path those would
 * exist to serve: this contract has no owner, no setters and no rescue, and its reserves can only
 * ever move toward the pool.
 *
 * @dev The reserves are counters — `trackedQuote`, `trackedTokens` — never balances. ETH forced
 * in by `selfdestruct` or tokens transferred straight in sit outside the books: they move no
 * price, bring graduation no closer, and are stranded here rather than folded into the pool's
 * seed. The economics are compile-time constants for the same reason `FEE_BPS` is one on the
 * hook: the protocol has decided them once, for everyone, and a per-launch parameter would only
 * be a way to mis-set them.
 */
contract SweepBondingCurve is Initializable, ReentrancyGuard {
    /// @notice The virtual ETH the pricing starts against: an opening FDV of 1.68 ETH.
    uint256 public constant PHANTOM_QUOTE = 1.68 ether;

    /// @notice The real ETH that ends the curve and seeds the pool.
    uint256 public constant GRADUATION_THRESHOLD = 4.2 ether;

    /// @notice The protocol's cut of every trade's quote leg.
    uint256 public constant CURVE_FEE_BPS = 100;

    /// @notice The creator's cut of every trade's quote leg.
    uint256 public constant CREATOR_TAX_BPS = 200;

    /// @notice Where the anti-snipe tax starts, at the launch second.
    uint256 public constant SNIPE_TAX_START_BPS = 9900;

    /// @notice How long the anti-snipe tax takes to decay to zero: five seconds, about fifty
    /// blocks here.
    uint256 public constant SNIPE_TAX_SECONDS = 5;

    uint256 internal constant BPS = 10_000;

    /// @notice The strategy token this curve sells, which is the strategy itself.
    address public token;

    /// @notice The factory that deployed and initialized this curve, and the only address the
    /// reserves can ever be released to.
    address public factory;

    /// @notice The hook the launch was welded to, read off the token at initialize. The curve
    /// only ever asks it one thing: the live protocol fee recipient.
    address public hook;

    /// @notice Who earns the creator tax. Written once at launch; the zero address folds the
    /// creator's share into the protocol's, mirroring the hook's own distribution.
    address public creatorFeeRecipient;

    /// @notice The wallet that sent the launch. Exempt from the snipe tax, with the creator
    /// recipient.
    address public launcher;

    /// @notice When trading opened, which anchors the snipe tax's decay.
    uint256 public launchedAt;

    /// @notice Every wei that entered through a buy and has not left through a sell or a fee
    /// sweep. The fee buckets below are earmarks inside this number, not additions to it.
    uint256 public trackedQuote;

    /// @notice Every token the curve holds for sale or for the pool. Donated tokens are not in
    /// this number and never will be.
    uint256 public trackedTokens;

    /// @notice The allocation the curve never sells: exactly the tokens the pool is seeded and
    /// priced with, fixed at initialize as `supply · P / (P + T)`.
    uint256 public reservedTokens;

    /// @notice Quote fees owed to the protocol, the snipe tax included.
    uint256 public protocolFeeBalance;

    /// @notice Quote fees owed to the creator.
    uint256 public creatorFeeBalance;

    /// @notice Set by `graduate`, before anything else it does. Once true, trading is over for
    /// good and the only remaining move is the factory's `completeGraduation`.
    bool public graduated;

    /// @dev One buy's pricing, boxed so the hot path fits the reachable stack without `via_ir`,
    /// which `forge coverage` cannot run.
    struct BuyQuote {
        uint256 spent;
        uint256 fee;
        uint256 tax;
        uint256 snipeTax;
        uint256 tokensOut;
    }

    event CurveBuy(
        address indexed buyer,
        address indexed recipient,
        uint256 ethIn,
        uint256 tokensOut,
        uint256 protocolFee,
        uint256 creatorFee,
        uint256 snipeTax,
        uint256 quoteReserveAfter,
        uint256 tokenReserveAfter
    );
    event CurveSell(
        address indexed seller,
        address indexed recipient,
        uint256 tokensIn,
        uint256 ethOut,
        uint256 protocolFee,
        uint256 creatorFee,
        uint256 quoteReserveAfter,
        uint256 tokenReserveAfter
    );
    event BuyRefunded(address indexed buyer, uint256 refund);
    event SnipeTaxCharged(address indexed recipient, uint256 amount);
    event FeesSwept(uint256 protocolAmount, uint256 creatorAmount);
    event Graduated(uint256 finalQuote, uint256 finalTokens);
    event CurveCompleted(uint256 ethOut, uint256 tokenOut);
    event AutoGraduationFailed(uint256 gasRemaining);

    error CurveGraduated();
    error AlreadyGraduated();
    error NotReadyToGraduate();
    error NotGraduated();
    error NothingToComplete();
    error OnlyFactory();
    error ZeroAddress();
    error ZeroAmount();
    error SlippageExceeded(uint256 delivered, uint256 minimum);
    error SupplyNotDelivered();
    error InvalidLaunchEconomics();
    error NothingToSweep();
    error DirectPaymentRejected();
    error InvalidRecipient();

    /// @dev The implementation behind the clones must not be initializable by a stranger, who
    /// would otherwise own a contract at the very address the deployment record names.
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Wires one launch's curve. Called by the factory in the launch transaction, after
     * it has transferred the token's whole supply here.
     *
     * @dev `factory` is `msg.sender` and never a parameter: the deploy and the initialize happen
     * in one factory transaction, and a recorded sender cannot be spoofed where a parameter can.
     * `SupplyNotDelivered` requires this curve to hold the token's entire supply — a partial
     * delivery would misprice every trade and seed a wrong pool. `InvalidLaunchEconomics`
     * refuses a supply so small the reserved allocation rounds to nothing, where the graduation
     * price would be undefined. The hook is read off the token rather than trusted from
     * calldata, so the curve pays the protocol wherever the launch's actual hook points.
     * The launcher and the creator recipient are the snipe-tax exemptions: the
     * launch's own side set the terms, so taxing its opening buys protects nobody. They are two
     * wallets on a bag desk, where the recipient is the target token's owner and not the
     * sender. There is deliberately no way to exempt anyone else: a list of bundle
     * wallets would let a creator take a large share of the supply untaxed through
     * wallets of their own, which is the one thing the tax exists to stop.
     */
    function initialize(address token_, address creatorFeeRecipient_, address launcher_) external initializer {
        if (token_ == address(0) || launcher_ == address(0)) revert ZeroAddress();

        uint256 supply = ISweepCurveToken(token_).totalSupply();
        if (ISweepCurveToken(token_).balanceOf(address(this)) != supply) revert SupplyNotDelivered();

        uint256 reserved = FixedPointMathLib.fullMulDiv(supply, PHANTOM_QUOTE, PHANTOM_QUOTE + GRADUATION_THRESHOLD);
        if (reserved == 0 || reserved >= supply) revert InvalidLaunchEconomics();

        token = token_;
        factory = msg.sender;
        hook = ISweepCurveToken(token_).hook();
        creatorFeeRecipient = creatorFeeRecipient_;
        launcher = launcher_;
        reservedTokens = reserved;
        trackedTokens = supply;
        launchedAt = block.timestamp;
    }

    /**
     * @notice Buys the token with the ETH sent, at the curve's price, for `recipient`.
     *
     * @dev The pricing and its guards live in `_priceBuy`, shared with `quoteBuy` so a front end
     * quoting through the view can never disagree with the fill. On top of it:
     *
     * The slippage check is a bound on the price paid, not the quantity received —
     * `spent · minTokensOut > received · tokensOut` — because the crossing buy is clamped to
     * what the curve still has and refunded the rest; a quantity bound would fail every honest
     * partial fill, and rejecting the partial fill instead would let a dust buy placed just
     * under the line keep a launch from ever graduating.
     *
     * The counters move before the token transfer and the refund, so nothing observable
     * mid-transfer disagrees with the books. The refund goes back with a plain reverting send:
     * the buyer chose their own address and a contract that cannot receive ETH should keep its
     * money, not lose the change.
     *
     * `_tryAutoGraduate` runs last: the buy that crosses the threshold settles the launch in the
     * same transaction whenever it can, and a failure there must never take the user's trade
     * down with it.
     */
    function buy(uint256 minTokensOut, address recipient) external payable nonReentrant returns (uint256 tokensOut) {
        uint256 received = msg.value;
        BuyQuote memory quote = _priceBuy(received, recipient);
        if (quote.spent * minTokensOut > received * quote.tokensOut) {
            revert SlippageExceeded(quote.tokensOut, minTokensOut);
        }

        protocolFeeBalance += quote.fee + quote.snipeTax;
        creatorFeeBalance += quote.tax;
        trackedQuote += quote.spent;
        trackedTokens -= quote.tokensOut;
        SafeTransferLib.safeTransfer(token, recipient, quote.tokensOut);

        uint256 refund = received - quote.spent;
        if (refund != 0) {
            emit BuyRefunded(msg.sender, refund);
            SafeTransferLib.safeTransferETH(msg.sender, refund);
        }
        if (quote.snipeTax != 0) emit SnipeTaxCharged(recipient, quote.snipeTax);

        (uint256 quoteReserveAfter,) = getReserves();
        emit CurveBuy(
            msg.sender,
            recipient,
            quote.spent,
            quote.tokensOut,
            quote.fee,
            quote.tax,
            quote.snipeTax,
            quoteReserveAfter,
            trackedTokens
        );

        _tryAutoGraduate();
        return quote.tokensOut;
    }

    /**
     * @notice Sells tokens back to the curve for ETH, fees off the quote leg, no snipe tax.
     *
     * @dev Refused not just once `graduated` but already when `readyToGraduate()`: between the
     * crossing buy and the flag there is a window where the curve is full, and a sell landing in
     * it would push tokens back and pull ETH out, seeding the pool deeper and cheaper than the
     * reserved allocation fixes it.
     * Nobody is stranded: `graduate` is permissionless, so a blocked seller can settle the
     * launch themselves and trade the pool in the same transaction.
     *
     * `InvalidRecipient` refuses the factory as the payee. The factory admits ETH from any curve
     * it deployed, because that is how graduation reserves arrive, and has no function that sends
     * ETH on: a sale paid there would strand the seller's ETH for good.
     *
     * The reserves are read before the tokens are pulled in, so the trade prices against the
     * pre-trade state. `trackedQuote` loses only the net payout: the fee wei stay in the
     * contract and move into the buckets, which are earmarks inside `trackedQuote`.
     */
    function sell(uint256 tokensIn, uint256 minEthOut, address recipient)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == factory) revert InvalidRecipient();

        (uint256 quoteReserve, uint256 tokenReserve) = getReserves();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), tokensIn);

        uint256 gross = SweepCurveMath.getAmountOut(tokensIn, tokenReserve, quoteReserve);
        uint256 fee = (gross * CURVE_FEE_BPS) / BPS;
        uint256 tax = (gross * CREATOR_TAX_BPS) / BPS;
        ethOut = gross - fee - tax;
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);

        protocolFeeBalance += fee;
        creatorFeeBalance += tax;
        trackedQuote -= ethOut;
        trackedTokens += tokensIn;
        SafeTransferLib.safeTransferETH(recipient, ethOut);

        (uint256 quoteReserveAfter,) = getReserves();
        emit CurveSell(msg.sender, recipient, tokensIn, ethOut, fee, tax, quoteReserveAfter, trackedTokens);
    }

    /**
     * @notice Marks the curve graduated and sweeps the fee buckets. Permissionless: the natural
     * caller is the crossing buy itself, and after a gas-starved failure, anyone.
     *
     * @dev Deliberately not `nonReentrant`, because it is invoked from inside `buy`'s own
     * guarded scope through the external self-call in `_tryAutoGraduate`. `graduated = true` is
     * written before the sweep pays a single wei: the sweep's ETH sends can hand control to a
     * recipient, and the flag is the only thing closing `buy` and `sell` at that instant —
     * re-entering while it was still false would let a recipient refill fee buckets that had
     * already been zeroed.
     */
    function graduate() external {
        if (graduated) revert AlreadyGraduated();
        if (!readyToGraduate()) revert NotReadyToGraduate();

        graduated = true;
        _sweepFees();
        emit Graduated(trackedQuote, trackedTokens);
    }

    /**
     * @notice Hands every tracked wei and token to the factory, which is seeding the pool with
     * them in this same transaction.
     *
     * @dev `OnlyFactory` because the reserves are the pool's seed and nothing else may ever
     * receive them; `NotGraduated` because taking them earlier would strand traders on a live
     * curve; `NothingToComplete` refuses a second call, which would otherwise transfer nothing
     * and emit a lying event. The factory calls this inside `createGraduatedPool`, so the
     * reserves are only ever on the curve or in the pool — a failed seed reverts the whole
     * transaction back to a halted, solvent, retryable curve, which is why no rescue function
     * exists. The token is told `markGraduated` before the transfers: the strategy uses it to
     * reset its bid ramp, and it must observe graduation before any balance moves.
     */
    function completeGraduation() external nonReentrant returns (uint256 ethOut, uint256 tokenOut) {
        if (msg.sender != factory) revert OnlyFactory();
        if (!graduated) revert NotGraduated();

        ethOut = trackedQuote;
        tokenOut = trackedTokens;
        if (tokenOut == 0) revert NothingToComplete();
        trackedQuote = 0;
        trackedTokens = 0;

        ISweepCurveToken(token).markGraduated();
        SafeTransferLib.safeTransfer(token, msg.sender, tokenOut);
        if (ethOut != 0) SafeTransferLib.safeTransferETH(msg.sender, ethOut);

        emit CurveCompleted(ethOut, tokenOut);
    }

    /**
     * @notice Pays the fee buckets out. Permissionless, so the keeper is a convenience and not a
     * dependency; reverts on empty buckets so a mis-scheduled sweep reads as a revert rather
     * than a silent success.
     */
    function sweepFees() external nonReentrant {
        if (protocolFeeBalance + creatorFeeBalance == 0) revert NothingToSweep();
        _sweepFees();
    }

    /// @notice The reserves the pricing sees: the phantom plus every tracked wei not earmarked
    /// as fees, against the tracked tokens.
    function getReserves() public view returns (uint256 quoteReserve, uint256 tokenReserve) {
        quoteReserve = PHANTOM_QUOTE + trackedQuote - protocolFeeBalance - creatorFeeBalance;
        tokenReserve = trackedTokens;
    }

    /// @notice The real ETH the curve has taken in and not earmarked — the pool's future seed,
    /// and the number the graduation progress bar reads.
    function realQuoteReserve() public view returns (uint256) {
        return trackedQuote - protocolFeeBalance - creatorFeeBalance;
    }

    /// @notice Tokens still buyable before the curve is full.
    function sellableTokens() public view returns (uint256) {
        uint256 tracked = trackedTokens;
        uint256 reserved = reservedTokens;
        return tracked > reserved ? tracked - reserved : 0;
    }

    /// @notice True when the curve is full and waiting to be flagged. Expressed on the token
    /// side because it is the side a buy cannot overshoot: the crossing buy is clamped to land
    /// exactly on the reserved allocation.
    function readyToGraduate() public view returns (bool) {
        return !graduated && sellableTokens() == 0;
    }

    /**
     * @notice The snipe tax a recipient would pay right now, before the in-trade clamp.
     *
     * @dev Fourteen halvings spread across the window, in integer shifts: 9,900 at second zero,
     * 2,475 at one, 309 at two, 38 at three, 4 at four, zero from five. Fourteen because 2^14
     * exceeds the starting rate, so the tax reaches zero inside the window instead of cutting
     * off at a rate that still matters. Keyed on the recipient, so routing a taxed buy through
     * an exempt wallet buys no discount. A zero creator recipient exempts nobody, because the
     * zero address is never a buyer (`_priceBuy` refuses it).
     */
    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        if (recipient == launcher || recipient == creatorFeeRecipient) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= SNIPE_TAX_SECONDS) return 0;
        return SNIPE_TAX_START_BPS >> ((elapsed * 14) / SNIPE_TAX_SECONDS);
    }

    /// @notice What a buy of `ethIn` for `recipient` would deliver right now, and the effective
    /// snipe tax it would pay. This is the buy path's own arithmetic, so a front end quoting
    /// here never disagrees with the fill in the same block.
    function quoteBuy(uint256 ethIn, address recipient) external view returns (uint256 tokensOut, uint256 snipeTaxBps) {
        BuyQuote memory quote = _priceBuy(ethIn, recipient);
        return (quote.tokensOut, _clampedSnipeTaxBps(recipient));
    }

    /// @notice What a sell of `tokensIn` would return right now, net of both fees.
    function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut) {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();

        (uint256 quoteReserve, uint256 tokenReserve) = getReserves();
        uint256 gross = SweepCurveMath.getAmountOut(tokensIn, tokenReserve, quoteReserve);
        return gross - (gross * CURVE_FEE_BPS) / BPS - (gross * CREATOR_TAX_BPS) / BPS;
    }

    /// @dev Money enters through `buy` or it does not enter: refusing plain sends keeps "the
    /// balance covers the books exactly, donations aside" an invariant instead of a hope. A
    /// `selfdestruct` can still force ETH in, which is why the books are counters.
    receive() external payable {
        revert DirectPaymentRejected();
    }

    /**
     * @dev One buy's pricing, shared verbatim by `buy` and `quoteBuy`.
     *
     * `CurveGraduated` twice: once on the flag, and once when the sellable side is empty but the
     * flag not yet set — the ready window must refuse buys just as `sell` refuses sells, or a
     * trade lands between the crossing buy and a gas-starved graduation. `ZeroAddress` refuses a
     * recipient that would burn the fill; `ZeroAmount` a spend that prices nothing.
     *
     * The fee legs each come off the gross spend, and the fill prices the remainder. The snipe
     * tax is clamped so the combined take always nets the buyer at least 1% — which is also what
     * keeps the clamp's gross-up denominator away from zero. A fill larger than the sellable
     * remainder is clamped to it: the needed net input is re-derived from the token side, then
     * grossed back up for the three fee legs, rounded up so the reserves never lose the wei, and
     * capped at what was actually sent.
     */
    function _priceBuy(uint256 received, address recipient) private view returns (BuyQuote memory quote) {
        if (graduated) revert CurveGraduated();
        if (recipient == address(0)) revert ZeroAddress();
        if (received == 0) revert ZeroAmount();

        (uint256 quoteReserve, uint256 tokenReserve) = getReserves();
        uint256 snipeBps = _clampedSnipeTaxBps(recipient);

        quote.spent = received;
        quote.fee = (received * CURVE_FEE_BPS) / BPS;
        quote.tax = (received * CREATOR_TAX_BPS) / BPS;
        quote.snipeTax = (received * snipeBps) / BPS;
        quote.tokensOut =
            SweepCurveMath.getAmountOut(received - quote.fee - quote.tax - quote.snipeTax, quoteReserve, tokenReserve);

        uint256 sellable = sellableTokens();
        if (sellable == 0) revert CurveGraduated();
        if (quote.tokensOut > sellable) {
            quote.tokensOut = sellable;
            uint256 net = SweepCurveMath.getAmountIn(sellable, quoteReserve, tokenReserve);
            uint256 grossed = FixedPointMathLib.fullMulDivUp(net, BPS, BPS - CURVE_FEE_BPS - CREATOR_TAX_BPS - snipeBps);
            quote.spent = grossed < received ? grossed : received;
            quote.fee = (quote.spent * CURVE_FEE_BPS) / BPS;
            quote.tax = (quote.spent * CREATOR_TAX_BPS) / BPS;
            quote.snipeTax = (quote.spent * snipeBps) / BPS;
        }
    }

    /// @dev The effective snipe tax a buy prices with: the raw decay, bounded so the buyer
    /// always nets at least 1% of their spend.
    function _clampedSnipeTaxBps(address recipient) private view returns (uint256) {
        uint256 taxBps = currentSnipeTaxBps(recipient);
        if (taxBps == 0) return 0;
        uint256 maxBps = BPS - CURVE_FEE_BPS - CREATOR_TAX_BPS - 100;
        return taxBps > maxBps ? maxBps : taxBps;
    }

    /**
     * @dev Zeroes both buckets, releases their wei from the tracked quote, and pays them out by
     * force. The force-send is the guard: a recipient that reverts on receive must not be able
     * to block the crossing buy's automatic sweep or hold the other bucket hostage — the same
     * reasoning that already pays `processBurn`'s caller by force. The protocol's recipient is
     * read live off the hook so the one setter that governs protocol revenue governs all of it;
     * a zero creator folds into the protocol, mirroring the hook's `_distribute`. Tolerates
     * empty buckets silently because `graduate` calls it unconditionally; the external
     * `sweepFees` is the one that treats empty as a mistake.
     */
    function _sweepFees() private {
        uint256 protocolAmount = protocolFeeBalance;
        uint256 creatorAmount = creatorFeeBalance;
        if (protocolAmount + creatorAmount == 0) return;

        protocolFeeBalance = 0;
        creatorFeeBalance = 0;
        trackedQuote -= protocolAmount + creatorAmount;

        address creator = creatorFeeRecipient;
        if (creator == address(0)) {
            protocolAmount += creatorAmount;
            creatorAmount = 0;
        }

        if (protocolAmount != 0) {
            SafeTransferLib.forceSafeTransferETH(ISweepCurveHook(hook).protocolFeeRecipient(), protocolAmount);
        }
        if (creatorAmount != 0) {
            SafeTransferLib.forceSafeTransferETH(creator, creatorAmount);
        }
        emit FeesSwept(protocolAmount, creatorAmount);
    }

    /**
     * @dev Settles the launch the instant a buy fills the curve, without ever failing the buy.
     * The external self-call is what buys try/catch; the event is what lets the keeper notice a
     * crossing buy whose caller starved graduation of gas under the 63/64 rule and finish the
     * job permissionlessly.
     */
    function _tryAutoGraduate() private {
        if (!readyToGraduate()) return;
        try this.graduate() {}
        catch {
            emit AutoGraduationFailed(gasleft());
        }
    }
}
