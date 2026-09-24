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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SweepTestToken
 * @author 0xDAVZER
 * @notice A fungible token anyone can conjure, so a bag strategy can be exercised before a real
 * memecoin has been pointed at us.
 *
 * @dev The fungible twin of `SweepTestCollection`: staging exposes it as the "mint a phantom token"
 * action, it is deployed from the tester's own wallet so the tester is its `owner()` and therefore
 * the creator fee recipient, and it must never be presented to users as a Sweep token.
 *
 * The whole supply is minted to the deployer at construction, which is what a launched memecoin
 * looks like from the factory's side: a non-zero `totalSupply()` to size the bag from, and a
 * wallet holding enough of it to bring a bag to the desk. `mint` exists so a second tester can be
 * handed bags without a transfer, and is the owner's alone so the supply a strategy was sized on
 * cannot be inflated by a stranger.
 */
contract SweepTestToken is ERC20, Ownable {
    /// @notice What the deployer receives at construction: a memecoin-shaped supply.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Creates `amount` more for `to`. The owner's alone, so the supply a strategy's bag
    /// was sized on cannot be inflated by whoever wants a cheaper bag.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
