// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title UniswapV4Addresses
 * @notice Canonical Uniswap v4 deployment addresses per chain, used by the deploy scripts.
 *
 * Every address below was taken from Uniswap's official deployments page and then
 * **verified on-chain** rather than trusted:
 *
 *   - code exists at each address
 *   - `PositionManager.poolManager()` returns the PoolManager listed for the same chain
 *   - `StateView.poolManager()` returns it too
 *   - `PositionManager.permit2()` returns the canonical Permit2
 *
 * Those cross-checks are not decorative. A launchpad that initializes pools on one PoolManager
 * while minting positions through a PositionManager wired to a different one would deploy
 * cleanly and then fail every single launch, after taking the creator's fee.
 *
 * Verified 2026-09-07 against https://rpc.mainnet.chain.robinhood.com (chain id 4663, block
 * 56,688,788), 2026-09-08 against https://rpc.testnet.chain.robinhood.com (chain id 46630, block
 * 115,614,797), and, for the Base entries, against https://mainnet.base.org and
 * https://sepolia.base.org. The Base addresses are retained because the protocol is
 * chain-agnostic and Base remains a plausible second deployment, not because anything ships
 * there today.
 */
library UniswapV4Addresses {
    error UnsupportedChain(uint256 chainId);

    uint256 internal constant ROBINHOOD = 4663;
    uint256 internal constant ROBINHOOD_TESTNET = 46_630;
    uint256 internal constant BASE = 8453;
    uint256 internal constant BASE_SEPOLIA = 84_532;

    /// @dev Permit2 is deployed at the same address on every chain via the deterministic
    /// deployer, and Robinhood Chain's own contract documentation confirms it for both its
    /// mainnet and its testnet.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant RH_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant RH_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant RH_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant BASE_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;

    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;

    /// @notice Uniswap v4 addresses for `chainId`.
    /// @dev Reverts on an unsupported chain rather than returning zero, so a deploy against the
    /// wrong network fails immediately instead of silently deploying a factory wired to
    /// address(0). Every entry here was verified on-chain before being added, including the
    /// testnet's: an unverified guess would be worse than a revert.
    function forChain(uint256 chainId)
        internal
        pure
        returns (address poolManager, address positionManager, address permit2)
    {
        permit2 = PERMIT2;
        if (chainId == ROBINHOOD) return (RH_POOL_MANAGER, RH_POSITION_MANAGER, permit2);
        if (chainId == ROBINHOOD_TESTNET) return (RH_POOL_MANAGER, RH_POSITION_MANAGER, permit2);
        if (chainId == BASE) return (BASE_POOL_MANAGER, BASE_POSITION_MANAGER, permit2);
        if (chainId == BASE_SEPOLIA) {
            return (BASE_SEPOLIA_POOL_MANAGER, BASE_SEPOLIA_POSITION_MANAGER, permit2);
        }
        revert UnsupportedChain(chainId);
    }

    /// @dev Robinhood Chain's testnet carries the **same** Uniswap v4 deployment at the **same**
    /// addresses as its mainnet, which is not something to assume — it was checked. Code is present
    /// at all five, and the same three cross-checks pass: `PositionManager.poolManager()` and
    /// `StateView.poolManager()` both return the PoolManager above, and `PositionManager.permit2()`
    /// returns the canonical Permit2. The CREATE2 proxy the hook is mined against is there too, so
    /// a testnet deployment is the same sequence as a mainnet one and proves the same things.

    /// @notice The Universal Router for `chainId`, needed by the buy-and-burn swap path.
    /// @dev Split from `forChain` because only the strategy's burn leg routes through it, while
    /// pool creation and position minting do not, and returning an unverified zero from the
    /// common path would be easy to miss.
    function routerForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == ROBINHOOD || chainId == ROBINHOOD_TESTNET) return RH_UNIVERSAL_ROUTER;
        revert UnsupportedChain(chainId);
    }
}
