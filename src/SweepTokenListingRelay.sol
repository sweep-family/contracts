// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    the floor in another currency
*/

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {ISeaport} from "./interfaces/ISeaport.sol";

/**
 * @title SweepTokenListingRelay
 * @author 0xDAVZER
 * @notice Buys a Seaport listing priced in an ERC-20 with ETH, for whoever calls it: a desk's
 * `buyTargetNFT` names this contract as its target (decision 0023).
 *
 * @dev No deployed contract knows this one. A desk already sends its `value` to any target but its
 * collection, then checks that the piece arrived and charges the treasury only the ETH that did not
 * come back; this contract turns that ETH into exactly the tokens the order asks for, has Seaport
 * deliver the piece, and returns the rest. The desk's guards all still apply, so a fault here can
 * make a purchase fail or cost at most the bid, like any other target.
 *
 * @dev It holds nothing between transactions, calls only Seaport and the PoolManager, both fixed at
 * construction, and never forwards an arbitrary call: a contract holding an approval that did would
 * be a gadget for anyone.
 */
contract SweepTokenListingRelay is IUnlockCallback, ReentrancyGuard {
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    IPoolManager public immutable poolManager;
    ISeaport public immutable seaport;

    /// @notice What to buy and how: the pool to buy the token on, how much of it the order
    /// consumes, and the Seaport call that consumes it.
    struct Fill {
        PoolKey key;
        uint256 tokenAmount;
        bytes seaportCall;
    }

    /// @notice A fill with no ETH to spend or no token to buy.
    error NothingToSpend();
    /// @notice The pool's first currency is not native ETH.
    error NotANativePool();
    /// @notice The pool has a hook.
    error HookedPool();
    /// @notice The pool hit its price limit before delivering the whole token amount.
    error PartialSwap(uint256 delivered, uint256 wanted);
    /// @notice Seaport refused the fulfillment.
    error SeaportFailed(bytes reason);
    /// @notice The fulfillment consumed less of the token than was bought.
    error TokensLeftOver(uint256 amount);
    /// @notice The settlement callback is the PoolManager's to make, and nobody else's.
    error NotPoolManager();
    /// @notice A constructor argument is the zero address.
    error ZeroAddress();

    event Filled(address indexed caller, address indexed token, uint256 tokenAmount, uint256 ethSpent);

    /// @dev `ZeroAddress` refuses a relay that could never swap or never fill.
    constructor(IPoolManager poolManager_, ISeaport seaport_) {
        if (address(poolManager_) == address(0) || address(seaport_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        seaport = seaport_;
    }

    /**
     * @notice Buys `f.tokenAmount` of the token with `msg.value` of ETH, runs `f.seaportCall`
     * against Seaport with exactly that allowance, and returns the unspent ETH to the caller.
     *
     * @dev `NothingToSpend` refuses a call with no ETH or no token amount: there is nothing to
     * buy, and an empty swap would only cost the caller gas to learn it.
     *
     * @dev `NotANativePool` refuses a key whose first currency is not native ETH: the relay pays
     * only with the ETH it was sent, and a pool in another currency would need a balance it does
     * not hold. `HookedPool` refuses a key with a hook, which could charge any fee it likes on the
     * swap, bounded only by the caller's `value`.
     *
     * @dev The balances in place before the call are excluded from everything that follows. ETH
     * force-sent here earlier is never spent and never refunded, or it would go to whoever called
     * next; tokens sent here earlier are never counted as consumed by this fill.
     *
     * @dev The approval is exactly `f.tokenAmount`, to Seaport itself. A fulfillment through a
     * conduit pulls from an address with no approval and fails, which is the right answer: this
     * contract approves nothing else. `SeaportFailed` carries Seaport's reason.
     *
     * @dev `TokensLeftOver` refuses a fulfillment that consumed less than was bought: the surplus
     * was paid for with the caller's ETH, and kept here it would be stranded with no way back. It
     * is also what leaves no allowance behind: Seaport spends the exact approval down to zero, and
     * a fill that did not spend all of it reverts, approval included.
     *
     * @dev `nonReentrant` covers the whole call: Seaport moves a piece to its recipient, and a
     * recipient calling back in would find this contract holding tokens mid-fill.
     */
    function fill(Fill calldata f) external payable nonReentrant returns (uint256 ethSpent) {
        if (msg.value == 0 || f.tokenAmount == 0) revert NothingToSpend();
        if (Currency.unwrap(f.key.currency0) != address(0)) revert NotANativePool();
        if (address(f.key.hooks) != address(0)) revert HookedPool();

        address token = Currency.unwrap(f.key.currency1);
        uint256 stray = address(this).balance - msg.value;
        uint256 tokensBefore = SafeTransferLib.balanceOf(token, address(this));

        ethSpent = abi.decode(poolManager.unlock(abi.encode(f.key, f.tokenAmount)), (uint256));
        _fulfill(token, f.tokenAmount, f.seaportCall);

        uint256 left = SafeTransferLib.balanceOf(token, address(this)) - tokensBefore;
        if (left != 0) revert TokensLeftOver(left);

        uint256 change = address(this).balance - stray;
        if (change != 0) SafeTransferLib.safeTransferETH(msg.sender, change);
        emit Filled(msg.sender, token, f.tokenAmount, ethSpent);
    }

    /**
     * @notice The fulfillment: approve Seaport for exactly `amount` and call it.
     *
     * @dev The approval is always set from zero: the previous fill spent its own down to nothing
     * or reverted (see `TokensLeftOver` on `fill`), which also suits tokens that refuse to move a
     * non-zero allowance to another non-zero one.
     */
    function _fulfill(address token, uint256 amount, bytes calldata seaportCall) private {
        SafeTransferLib.safeApprove(token, address(seaport), amount);
        (bool ok, bytes memory reason) = address(seaport).call(seaportCall);
        if (!ok) revert SeaportFailed(reason);
    }

    /**
     * @notice The swap, inside the PoolManager's flash-accounting window: exactly `tokenAmount` out,
     * whatever ETH that costs in.
     *
     * @dev `NotPoolManager` is the guard that matters: this settles and takes on the strength of
     * `data`, and only the PoolManager may be the one supplying it, echoing what `fill` handed to
     * `unlock`.
     *
     * @dev A positive `amountSpecified` is an exact-output swap in v4. `PartialSwap` refuses a pool
     * that reached its price limit before delivering the whole amount, since the order needs all of
     * it. The ETH settled is what the pool asked; a pool that asks for more than this contract
     * holds fails inside `settle`, and the whole fill with it.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 tokenAmount) = abi.decode(data, (PoolKey, uint256));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(tokenAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ""
        );

        uint256 delivered = uint256(int256(delta.amount1()));
        if (delivered != tokenAmount) revert PartialSwap(delivered, tokenAmount);
        uint256 ethIn = uint256(int256(-delta.amount0()));
        poolManager.settle{value: ethIn}();
        poolManager.take(key.currency1, address(this), tokenAmount);
        return abi.encode(ethIn);
    }
}
