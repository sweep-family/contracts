// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";

/**
 * @title OperatorCollection
 * @author 0xDAVZER
 * @notice A minimal ERC-721 whose contract pre-approves one global operator for every holder,
 * the shape OpenSea's conduit takes on collections that bake it in. Nothing here is exotic:
 * collections like this exist in numbers, and the desk cannot refuse to hold them.
 */
contract OperatorCollection {
    address public globalOperator;
    uint256 public nextId = 1;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) public balanceOf;

    function setGlobalOperator(address operator) external {
        globalOperator = operator;
    }

    function mint(address to) external returns (uint256 id) {
        id = nextId++;
        _ownerOf[id] = to;
        balanceOf[to] += 1;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address holder = _ownerOf[id];
        require(holder != address(0), "no such piece");
        return holder;
    }

    function isApprovedForAll(address, address operator) external view returns (bool) {
        return operator == globalOperator;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(_ownerOf[id] == from, "not the owner");
        require(msg.sender == from || msg.sender == globalOperator, "not allowed");
        _ownerOf[id] = to;
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd || interfaceId == 0x01ffc9a7;
    }
}

/**
 * @title OperatorThiefMarketplace
 * @author 0xDAVZER
 * @notice The venue of the pre-approved-operator attack. In its honest mode it delivers the
 * piece it was paid for and keeps the ETH, like any marketplace. In its thieving mode it
 * delivers TWO junk pieces — so the desk's balance check reads net plus one — including the
 * expected one, and uses the collection's global operator right to lift a piece the desk
 * already held. Every delivery guard passes: count up by one, expected piece owned. Only the
 * inventory walk catches the lifted piece.
 */
contract OperatorThiefMarketplace {
    OperatorCollection public collection;
    address public fence;

    constructor(OperatorCollection collection_, address fence_) {
        collection = collection_;
        fence = fence_;
    }

    function fulfill(uint256 deliverId) external payable {
        collection.transferFrom(address(this), msg.sender, deliverId);
    }

    function fulfillAndSteal(uint256 deliverId, uint256 extraId, uint256 stealId) external payable {
        collection.transferFrom(address(this), msg.sender, deliverId);
        collection.transferFrom(address(this), msg.sender, extraId);
        collection.transferFrom(msg.sender, fence, stealId);
    }

    receive() external payable {}
}

/**
 * @title OperatorBagToken
 * @author 0xDAVZER
 * @notice An ERC-20 with a pre-approved global operator — the DN404 / conduit shape on the
 * fungible side: one address the token's own machinery lets move anyone's balance.
 */
contract OperatorBagToken is ERC20 {
    address public globalOperator;

    function name() public pure override returns (string memory) {
        return "Operator Bag";
    }

    function symbol() public pure override returns (string memory) {
        return "OBAG";
    }

    function setGlobalOperator(address operator) external {
        globalOperator = operator;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (msg.sender == globalOperator) {
            _transfer(from, to, amount);
            return true;
        }
        return super.transferFrom(from, to, amount);
    }
}

/**
 * @title BagThiefSeller
 * @author 0xDAVZER
 * @notice A seller whose payment hook drains the desk. `buyTokens` pays the seller last, and a
 * seller that is a contract runs code inside that payment: this one uses the token's global
 * operator right to lift the desk's previously-held bags while the desk's own delta check — a
 * before/after around its `transferFrom` alone — has already passed. Only the closing balance
 * assertion catches it.
 */
contract BagThiefSeller {
    OperatorBagToken public token;
    address public desk;
    address public fence;
    uint256 public loot;

    constructor(OperatorBagToken token_, address desk_, address fence_) {
        token = token_;
        desk = desk_;
        fence = fence_;
    }

    function sellBag() external {
        (bool ok, bytes memory data) = desk.call(abi.encodeWithSignature("buyTokens()"));
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function approveDesk(uint256 amount) external {
        token.approve(desk, amount);
    }

    receive() external payable {
        uint256 held = token.balanceOf(desk);
        if (held != 0) {
            loot = held;
            token.transferFrom(desk, fence, held);
        }
    }
}
