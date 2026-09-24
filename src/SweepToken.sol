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

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";

import {ISweepLockedToken} from "./interfaces/ISweepLockedToken.sol";

/**
 * @title SweepToken
 * @author 0xDAVZER
 * @notice The token every Sweep strategy is: a fixed supply minted once, a transfer lock that keeps
 * every trade on the hooked pool, and the transient allowance the hook opens for one swap at a time.
 *
 * @dev Nothing here knows what a strategy does with its fees. The desks stack a treasury, a bid and
 * a burn queue on top (`SweepStrategy`); the recursive strategy stacks an airdrop ledger. Keeping
 * the token alone in one contract is what lets the lock be tested once and trusted everywhere.
 */
abstract contract SweepToken is ERC20, Ownable, Initializable, ReentrancyGuard, ISweepLockedToken {
    /// @notice Every strategy mints exactly this, once, and never again.
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    /// @notice Where burnt supply goes.
    /// @dev Tokens are sent here rather than destroyed, so `totalSupply` keeps counting them
    /// forever. Read `circulatingSupply` instead wherever a number reaches a user.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant BPS = 10_000;

    /// @dev Transient slot holding how much the hook has authorised to move through the
    /// PoolManager in this transaction. Transient because the authorisation must not survive the
    /// swap that needed it.
    uint256 private constant TRANSFER_ALLOWANCE_SLOT = 0;

    string private _name;
    string private _symbol;

    /// @notice The only address allowed to fund the strategy or authorise a pool transfer.
    address public hook;

    /// @notice The Uniswap v4 singleton, whose transfers the lock treats specially.
    address public poolManager;

    /// @notice Addresses exempt from the transfer lock.
    /// @dev The router lives here, and nothing works without it. Every entry is a hole in one of
    /// the two things making the fee unavoidable, so the list is small and its changes are events.
    mapping(address account => bool allowed) public isDistributor;

    error OnlyHook();
    error TransferNotAllowed();
    error InvalidConfiguration();

    event DistributorUpdated(address indexed account, bool allowed);
    event TransferAllowanceIncreased(uint256 amount);

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /**
     * @notice Wires the token and mints its entire supply to the caller.
     * @dev The caller is the factory, which immediately pushes the whole supply into a
     * single-sided Uniswap v4 position. That position is the bonding curve, and its ownership goes
     * to the dead address, so nothing here can ever be withdrawn. A zero hook could never open an
     * allowance, a zero pool manager would make the lock's pool rule unreachable, and a zero owner
     * would leave every setter dead; all three are refused rather than deployed broken.
     */
    function __SweepToken_init(
        string memory name_,
        string memory symbol_,
        address hook_,
        address poolManager_,
        address owner_
    ) internal onlyInitializing {
        if (hook_ == address(0) || poolManager_ == address(0) || owner_ == address(0)) {
            revert InvalidConfiguration();
        }

        _name = name_;
        _symbol = symbol_;
        hook = hook_;
        poolManager = poolManager_;

        _initializeOwner(owner_);
        _mint(msg.sender, MAX_SUPPLY);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Supply actually in circulation, excluding everything burnt.
    /// @dev Burnt tokens sit at a dead address rather than being destroyed, so any market cap taken
    /// from `totalSupply` is wrong by exactly the amount burnt so far — an error that grows over
    /// the life of the strategy.
    function circulatingSupply() public view returns (uint256) {
        return totalSupply() - balanceOf(DEAD_ADDRESS);
    }

    /**
     * @notice Authorises `amount` of token movement through the PoolManager for this transaction.
     * @dev Transient on purpose. A persistent allowance would survive the swap that needed it and
     * leave a standing hole in the transfer lock, which is half of what makes the fee unavoidable.
     */
    function increaseTransferAllowance(uint256 amount) external override onlyHook {
        uint256 updated = _transferAllowance() + amount;
        assembly {
            tstore(TRANSFER_ALLOWANCE_SLOT, updated)
        }
        emit TransferAllowanceIncreased(amount);
    }

    /// @notice How much pool movement the hook has authorised in this transaction.
    function transferAllowance() external view returns (uint256) {
        return _transferAllowance();
    }

    /// @notice Exempts an address from the transfer lock, or removes it.
    /// @dev Restricted to the owner, and worth naming for what it grants: everything on this list
    /// trades without paying the fee, which is the only reason a competing hookless pool cannot
    /// exist. The power is kept because the router needs it, and it is named here for that reason.
    function setDistributor(address account, bool allowed) external onlyOwner {
        isDistributor[account] = allowed;
        emit DistributorUpdated(account, allowed);
    }

    function _transferAllowance() internal view returns (uint256 value) {
        assembly {
            value := tload(TRANSFER_ALLOWANCE_SLOT)
        }
    }

    /**
     * @notice Refuses every transfer that is not the mint, a distributor, a burn, or an authorised
     * pool movement.
     *
     * @dev This is half of what makes a 10% fee unavoidable. Without it anyone could open a pool
     * with no hook and trade for free, and the treasury would never fill. The cost is every form of
     * composability — no lending collateral, no bridge, no CEX listing, not even a send to your own
     * second wallet — and that has to be said plainly wherever a user can see it.
     *
     * @dev The other half is the hook's `RouterNotAllowed`, and this lock is not sufficient on its
     * own: it sees ERC-20 movements only, while v4 also keeps ERC-6909 claim balances that move
     * between wallets through the PoolManager without touching this function at all, and a
     * swapper holding such claims can fund a hookless pool and trade there for free. The hook
     * closes that gap by refusing any swap whose caller is not a router the factory lists, so no
     * claim on this token can be minted in the first place.
     *
     * @dev Sends to the dead address are always allowed: destroying your own balance can never be
     * a way around a fee, and refusing it would only make voluntary burns impossible.
     *
     * @dev Virtual so a strategy that keeps a ledger over balances can settle it before a balance
     * moves; an override must still call this, since the lock is the whole point.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0)) return;
        if (to == DEAD_ADDRESS) return;
        if (isDistributor[from] || isDistributor[to]) return;

        if (from == poolManager || to == poolManager) {
            uint256 allowed = _transferAllowance();
            if (allowed < amount) revert TransferNotAllowed();
            uint256 remaining = allowed - amount;
            assembly {
                tstore(TRANSFER_ALLOWANCE_SLOT, remaining)
            }
            return;
        }

        revert TransferNotAllowed();
    }
}
