// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    the only road, from the wallet's side
*/

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ISweepFactory} from "./interfaces/ISweepFactory.sol";

/**
 * @title SweepSwapRouter
 * @author 0xDAVZER
 * @notice Buys and sells a Sweep token on its pool, for a wallet.
 *
 * @dev Not the Universal Router, for the same reasons as the burn router and one more: a router
 * that forwards tokens through itself needs to be a distributor, the command encoding is more
 * surface than the four calls it wraps, and this one can tell the hook who the trade is for. It
 * passes the wallet as `hookData`, which the hook records on `Trade`; the Universal Router passes
 * nothing, and every trade through it would be attributed to the router.
 *
 * @dev The transfer lock shapes both directions. A buy takes the tokens straight from the
 * PoolManager to the wallet, which the hook's transient allowance admits exactly. A sell pulls the
 * tokens from the wallet into the PoolManager, the one destination the lock admits for a stranger,
 * so the only approval a wallet ever grants is an ordinary ERC-20 approval to this contract, and
 * this contract never holds a token.
 */
contract SweepSwapRouter is IUnlockCallback {
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /// @dev Mirrored from the factory, like the burn router: a pool key built here is the pool key
    /// the factory opened, and a mismatch is a swap on a pool that does not exist.
    uint24 private constant LP_FEE = 0;
    int24 private constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    ISweepFactory public immutable factory;

    /// @notice The factory never launched this token, so there is no pool of ours to trade it on.
    error UnknownStrategy();
    /// @notice A swap of nothing.
    error NothingToSwap();
    /// @notice The deadline has passed; a transaction that sat in the mempool does not execute late.
    error Expired();
    /// @notice The pool would deliver less than the trader was willing to accept.
    error TooLittleReceived(uint256 received, uint256 minimum);
    /// @notice The settlement callback is the PoolManager's to make, and nobody else's.
    error NotPoolManager();
    /// @notice Not an error: how a quote leaves the PoolManager's window without settling anything.
    error QuoteResult(uint256 amountOut);
    /// @notice A quote's simulation failed for a reason other than delivering its result.
    error QuoteFailed(bytes reason);

    event Swapped(address indexed token, address indexed trader, bool buying, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager poolManager_, ISweepFactory factory_) {
        if (address(poolManager_) == address(0) || address(factory_) == address(0)) revert UnknownStrategy();
        poolManager = poolManager_;
        factory = factory_;
    }

    /**
     * @notice Spends `msg.value` of ETH buying `token`, delivered to the caller.
     *
     * @dev `minOut` is the trader's slippage bound and `deadline` their patience: a buy quoted at
     * one price and mined after the pool moved delivers less, and the trader said in advance how
     * much less they would take. Both are checked after the swap, against what actually happened.
     *
     * @dev The fee is already out of `amountOut`. The hook takes its cut inside the swap and the
     * PoolManager returns the trader's delta net of it, so what this delivers is what a quote from
     * the Quoter — which runs the same hook — promised.
     *
     * @dev Anything the pool did not consume is returned. A buy cannot run the pool out of tokens
     * short of buying the entire supply, so this is a wei of rounding at most, and it belongs to
     * the caller rather than to a contract with no way to give it back later.
     */
    function buy(address token, uint256 minOut, uint256 deadline) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (!factory.isStrategy(token)) revert UnknownStrategy();
        if (msg.value == 0) revert NothingToSwap();

        amountOut = abi.decode(poolManager.unlock(abi.encode(token, msg.sender, true, msg.value, false)), (uint256));
        if (amountOut < minOut) revert TooLittleReceived(amountOut, minOut);
        if (address(this).balance != 0) SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
        emit Swapped(token, msg.sender, true, msg.value, amountOut);
    }

    /**
     * @notice Sells `amountIn` of `token` for ETH, delivered to the caller.
     *
     * @dev The tokens are pulled from the caller inside the PoolManager's window, directly into the
     * PoolManager: the caller must have approved this contract for `amountIn`. A pool that runs out
     * of ETH before `amountIn` is consumed fills what it can, pulls only that, and leaves the rest
     * with the caller — `minOut` is what protects them from a fill they did not want.
     */
    function sell(address token, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (!factory.isStrategy(token)) revert UnknownStrategy();
        if (amountIn == 0) revert NothingToSwap();

        amountOut = abi.decode(poolManager.unlock(abi.encode(token, msg.sender, false, amountIn, false)), (uint256));
        if (amountOut < minOut) revert TooLittleReceived(amountOut, minOut);
        emit Swapped(token, msg.sender, false, amountIn, amountOut);
    }

    /**
     * @notice What a swap would deliver right now, fee included, without doing it.
     *
     * @dev The Quoter's trick, on our own contract: run the real swap inside an `unlock`, then
     * revert with the result. The revert unwinds the pool, the hook's fee and everything else, so
     * nothing is settled and no allowance is spent — and what comes back is exactly what `buy` or
     * `sell` would deliver in the same block, because it is the same code path through the same
     * hook. Called through `eth_call`; it is not `view` because the PoolManager's `unlock` is not,
     * but it never changes state in a transaction that succeeds.
     *
     * @dev `QuoteFailed` wraps any other revert — an unknown pool, a pool with nothing left to
     * sell — so a front end can tell "no quote" from "quote is zero".
     */
    function quote(address token, bool buying, uint256 amountIn) external returns (uint256 amountOut) {
        if (!factory.isStrategy(token)) revert UnknownStrategy();
        if (amountIn == 0) revert NothingToSwap();

        try poolManager.unlock(abi.encode(token, address(this), buying, amountIn, true)) {
            revert QuoteFailed("");
        } catch (bytes memory reason) {
            if (reason.length == 36 && bytes4(reason) == QuoteResult.selector) {
                return abi.decode(_slice(reason, 4), (uint256));
            }
            revert QuoteFailed(reason);
        }
    }

    /// @dev The bytes after a revert selector, for decoding a `QuoteResult`.
    function _slice(bytes memory data, uint256 from) private pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[from + i];
        }
    }

    /**
     * @notice The swap, inside the PoolManager's flash-accounting window.
     *
     * @dev `NotPoolManager` is the guard that matters: this settles and takes on the strength of
     * `data`, and only the PoolManager may be the one supplying it — echoing back what `buy` or
     * `sell` handed to `unlock` in the same call.
     *
     * @dev The trader's address rides along as `hookData`, which is how the hook's `Trade` names a
     * wallet rather than this contract. The deltas the PoolManager returns are net of the hook's
     * fee, so what is settled and taken here is exactly what the hook authorised the lock for.
     *
     * @dev A quote stops here: the swap has run and its delta is the answer, and the revert that
     * carries it undoes the swap. Nothing below runs for a quote.
     *
     * @dev A buy settles the ETH and takes the tokens straight to the trader. A sell syncs the
     * token, pulls what the pool consumed from the trader into the PoolManager, settles, and takes
     * the ETH to the trader. In neither direction does a token rest in this contract.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, address trader, bool buying, uint256 amountIn, bool quoting) =
            abi.decode(data, (address, address, bool, uint256, bool));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(factory.hook())
        });

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: buying,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: buying ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            abi.encode(trader)
        );

        if (quoting) revert QuoteResult(uint256(int256(buying ? delta.amount1() : delta.amount0())));

        if (buying) {
            uint256 tokensOut = uint256(int256(delta.amount1()));
            poolManager.settle{value: uint256(int256(-delta.amount0()))}();
            poolManager.take(key.currency1, trader, tokensOut);
            return abi.encode(tokensOut);
        }

        uint256 tokensIn = uint256(int256(-delta.amount1()));
        uint256 ethOut = uint256(int256(delta.amount0()));
        poolManager.sync(key.currency1);
        SafeTransferLib.safeTransferFrom(token, trader, address(poolManager), tokensIn);
        poolManager.settle();
        poolManager.take(key.currency0, trader, ethOut);
        return abi.encode(ethOut);
    }
}
