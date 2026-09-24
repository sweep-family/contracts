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

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SweepTestCollection
 * @author 0xDAVZER
 * @notice A collection anyone can conjure, so a strategy can be exercised before a real collection
 * has agreed to launch with us.
 *
 * @dev Staging exposes this as the "mint a phantom collection" action. It is the only fixture that
 * reaches a real network, which is why it lives under `src/testing/` rather than `test/` — but it
 * is a fixture all the same and must never be presented to users as a Sweep collection.
 *
 * Two properties here are load-bearing rather than cosmetic. It must answer `true` to
 * `supportsInterface(0x80ac58cd)`, because the launch factory gates on exactly that and refuses
 * everything else; that same gate is why CryptoPunks can never use a generic NFT strategy, since
 * Punks predate ERC-721 and answer no such call. And it must be able to mint in bulk, because a
 * real collection has thousands of pieces and a strategy holding 9% of one behaves nothing like a
 * strategy holding a single piece.
 */
contract SweepTestCollection is ERC721, Ownable {
    /// @notice Largest number of pieces a single batch may create.
    ///
    /// @dev Set from measurement, not from taste. One mint costs ~25,065 gas, so 500 pieces is
    /// about 12.5M — roughly 40% of a 30M block, leaving room for the rest of a transaction and
    /// working in every environment we run against.
    ///
    /// The first value here was 5,000, which would have cost ~125M gas and could therefore never
    /// have executed anywhere. It passed every unit test, because the tests only ever minted 100.
    /// It failed the moment the collection was deployed to a local chain for real, which is the
    /// whole argument for deploying locally before trusting a bound.
    ///
    /// Robinhood Chain reports a block gas limit of 2^50, the Arbitrum convention for "metered
    /// differently". We size against the 30M local chain instead: a fixture has to work everywhere
    /// it runs, and the tighter limit is the one that binds.
    uint256 public constant MAX_BATCH = 500;

    /// @notice Number of pieces minted so far, and therefore the id of the most recent one.
    /// @dev Tracked directly rather than inherited from ERC721Enumerable, whose per-transfer
    /// bookkeeping we would pay for on every trade and never read.
    uint256 public totalSupply;

    /// @notice Where each piece's metadata lives: `baseURI` followed by the token id.
    ///
    /// @dev A fixture with no images renders as a grid of blanks, which hides every layout bug
    /// behind the wrong one. On the testnet a phantom collection borrows the metadata of a real
    /// collection on Robinhood mainnet whose scheme is exactly base-plus-id — CashCat's, or
    /// Wasteland's — so `tokenURI(7)` resolves to a real picture. Fixed at deployment, like the
    /// collections it imitates.
    string public baseURI;

    /// @notice Requested batch was empty or above `MAX_BATCH`.
    error InvalidQuantity();

    /// @dev Owned by its deployer, because that is what the launch checks: only a collection's
    /// `owner()` may launch a strategy on it, and a phantom collection on staging has to be
    /// launchable by whoever minted it.
    constructor(string memory name_, string memory symbol_, string memory baseURI_)
        ERC721(name_, symbol_)
        Ownable(msg.sender)
    {
        baseURI = baseURI_;
    }

    /// @dev OpenZeppelin's `tokenURI` is `_baseURI()` concatenated with the decimal id, which is
    /// the scheme both borrowed collections use.
    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    /**
     * @notice Mints one piece to `to` and returns its id.
     * @dev Ids run from 1 upward and are never reused, so a test can hold two pieces and tell them
     * apart. Zero is left unused because several call sites treat a zero id as "none".
     */
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = ++totalSupply;
        _mint(to, tokenId);
    }

    /**
     * @notice Mints `quantity` consecutive pieces to `to` and returns the inclusive id range.
     * @dev Uses `_mint` rather than `_safeMint` deliberately: the receiver callback would make a
     * batch to a contract cost a call per piece, and a fixture minting four thousand pieces to a
     * test harness has no need to ask that harness whether it consents.
     */
    function mintBatch(address to, uint256 quantity) external returns (uint256 firstId, uint256 lastId) {
        if (quantity == 0 || quantity > MAX_BATCH) revert InvalidQuantity();

        firstId = totalSupply + 1;
        lastId = totalSupply + quantity;
        totalSupply = lastId;

        for (uint256 id = firstId; id <= lastId; ++id) {
            _mint(to, id);
        }
    }
}
