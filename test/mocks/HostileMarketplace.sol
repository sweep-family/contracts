// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice The ways a venue can betray a buyer who hands it ETH and a blob of calldata.
/// @dev Declared at file scope so tests can name a mode without reaching through the contract.
enum Betrayal {
    None,
    DeliverNothing,
    DeliverWrongId,
    TakeAndRevert,
    Reenter,
    ReturnChange,
    CreditFees
}

/**
 * @title HostileMarketplace
 * @author 0xDAVZER
 * @notice A venue that lies, one way at a time.
 *
 * @dev Exists because the strategy's purchase path executes an arbitrary external call with real
 * ETH and can only prove afterwards that it received what it paid for. Every guard around that call
 * answers one specific betrayal, and a guard nobody has watched fire is a line of code we believe
 * in rather than one we know. This contract is how we watch them fire.
 *
 * Holds its own inventory rather than pulling from a seller, so a single test can set up a
 * substitution — it needs two pieces in hand to hand over the wrong one.
 *
 * The betrayals and the guard each answers:
 *   DeliverNothing   takes the ETH, sends no piece        the balance-delta check
 *   DeliverWrongId   sends a real piece, not the one paid for   the ownership assertion
 *   TakeAndRevert    reverts after being paid             the call's own success check
 *   Reenter          calls back mid-purchase              the reentrancy guard
 *   ReturnChange     hands part of the payment back       the cost is measured, not assumed
 *   CreditFees       pays fees in mid-fill                the cost excludes what the treasury gained
 *
 * `DeliverWrongId` is the one that justifies having two guards instead of one: the balance really
 * does go up by one, so a contract that only counted would accept the substitution.
 */
contract HostileMarketplace is IERC721Receiver {
    /// @notice How this venue will misbehave on the next fill.
    Betrayal public betrayal;

    /// @notice Piece handed over instead of the one requested, in `DeliverWrongId`.
    uint256 public substitute;

    /// @notice Address called back into, in `Reenter`.
    address public reentryTarget;

    /// @notice Wei handed back to the buyer in `ReturnChange`, so the price actually paid is less
    /// than the price offered.
    uint256 public change;

    /// @notice Wei paid back to the buyer as a *fee* in `CreditFees`, raising its treasury and its
    /// balance at once while the purchase is still open.
    uint256 public fees;

    /// @notice Raised by `TakeAndRevert` after payment has been received.
    error Betrayed();
    /// @notice `DeliverWrongId` was selected without a substitute piece to hand over.
    error NoSubstituteSet();
    /// @notice `Reenter` was selected without a target to call back into.
    error NoReentryTargetSet();

    event Filled(address indexed collection, uint256 indexed tokenId, address buyer, Betrayal mode);

    /// @notice Chooses how the next fill misbehaves.
    function setBetrayal(Betrayal mode) external {
        betrayal = mode;
    }

    /// @notice Sets the piece handed over in place of the one requested.
    function setSubstitute(uint256 tokenId) external {
        substitute = tokenId;
    }

    /// @notice Sets the address called back into mid-fill.
    function setReentryTarget(address target) external {
        reentryTarget = target;
    }

    /// @notice Sets how much is paid back as a fee mid-fill.
    /// @dev The real shape of this on a fork is a venue that trades the strategy's own token before
    /// returning, so the hook credits the strategy inside the purchase. A unit test cannot reach
    /// the hook, so the strategy under test names this venue as its hook: what is pinned is the
    /// cost arithmetic, not who may call `addFees`.
    function setFees(uint256 amount) external {
        fees = amount;
    }

    /// @notice Sets how much of the payment is handed back.
    /// @dev A venue charging less than it was offered is ordinary, not hostile — a marketplace
    /// filling at a better price does exactly this. It belongs here because it proves the buyer
    /// measures what it spent rather than assuming it spent what it sent.
    function setChange(uint256 amount) external {
        change = amount;
    }

    /**
     * @notice Accepts payment and then behaves according to the configured betrayal.
     *
     * @dev Takes the money first in every branch, because that is the situation the strategy has to
     * survive: the ETH has already left before anything can be verified. Reverting afterwards is
     * safe only because the revert unwinds the payment with it, which is precisely the property
     * `test_VenueRevertingReturnsTheEth` pins.
     *
     * @dev `DeliverWrongId` transfers a genuine piece, so the caller's NFT balance really does rise
     * by one. That is the point: it is indistinguishable from an honest fill to anything that only
     * counts, and only an assertion on the *expected* id separates them.
     *
     * @dev The `Reenter` branch calls back before delivering, so a caller without a reentrancy
     * guard is reached while its own accounting is half-written.
     */
    function fulfill(address collection, uint256 tokenId) external payable {
        if (betrayal == Betrayal.TakeAndRevert) revert Betrayed();

        if (betrayal == Betrayal.DeliverNothing) {
            emit Filled(collection, tokenId, msg.sender, betrayal);
            return;
        }

        if (betrayal == Betrayal.DeliverWrongId) {
            if (substitute == 0) revert NoSubstituteSet();
            IERC721(collection).transferFrom(address(this), msg.sender, substitute);
            emit Filled(collection, tokenId, msg.sender, betrayal);
            return;
        }

        if (betrayal == Betrayal.Reenter) {
            if (reentryTarget == address(0)) revert NoReentryTargetSet();
            (bool reentered,) = reentryTarget.call("");
            reentered;
        }

        if (betrayal == Betrayal.CreditFees && fees != 0) {
            (bool credited,) = msg.sender.call{value: fees}(abi.encodeWithSignature("addFees()"));
            if (!credited) revert Betrayed();
        }

        IERC721(collection).transferFrom(address(this), msg.sender, tokenId);

        if (betrayal == Betrayal.ReturnChange && change != 0) {
            (bool refunded,) = msg.sender.call{value: change}("");
            if (!refunded) revert Betrayed();
        }

        emit Filled(collection, tokenId, msg.sender, betrayal);
    }

    /// @notice Accepts the pieces this venue hands out.
    /// @dev Present so a test can `safeTransferFrom` inventory in; plain `mint` needs no callback.
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Accepts payment.
    receive() external payable {}
}
