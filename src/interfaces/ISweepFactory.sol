// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISweepFactory
 * @author 0xDAVZER
 * @notice The narrow surface the hook needs from whatever launched the pool it guards.
 *
 * @dev The factory and the hook cannot both be constructed first: the factory needs the hook's
 * address to build the `PoolKey`, and the hook needs the factory's to ask whether a launch is in
 * progress. Naming the dependency here rather than importing the factory is what lets the hook be
 * proven against a mock before the factory exists — the same reason `ISweepBurnRouter` exists.
 */
interface ISweepFactory {
    /**
     * @notice True only while the factory is mid-launch, inside its own unlock callback.
     * @dev The single gate on pool creation and on liquidity deposits. Because a launch is one
     * transaction the factory controls end to end, this flag being true means the caller is the
     * factory and nothing else — which is how the pool ends up with exactly one position, deposited
     * once, and no way for anyone to add a second.
     */
    function loadingLiquidity() external view returns (bool);

    /// @notice Who may retune the hook's protocol-level settings.
    function owner() external view returns (address);

    /// @notice The hook every launched pool is welded to.
    /// @dev The burn router reads it to rebuild a strategy's `PoolKey`, rather than storing its own
    /// copy that could disagree.
    function hook() external view returns (address);

    /// @notice The NFT collection a strategy sweeps, or the zero address if it launched nothing
    /// or sweeps nothing.
    /// @dev The hook reads it to find out who may claim a strategy's creator fee share. A recursive
    /// strategy has no collection and answers zero, which is how its recipient stays fixed.
    function strategyToCollection(address strategy) external view returns (address);

    /// @notice Whether `token` is a strategy this factory launched, whatever it buys.
    /// @dev What the routers gate on. A strategy's collection cannot serve, since a recursive
    /// strategy has none; this answers for every kind, and for nothing the factory did not launch.
    function isStrategy(address token) external view returns (bool);

    /// @notice Whether `router` may call `PoolManager.swap` on a pool this hook guards.
    /// @dev The hook gates every swap on it, which is what keeps ERC-6909 claims on a strategy's
    /// token from ever existing — see the hook's `_afterSwap`. It is a list of contracts we wrote,
    /// not a permission a trader holds: anyone may trade, through one of them.
    function isRouter(address router) external view returns (bool);
}
