// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SweepTokenListingRelay} from "../src/SweepTokenListingRelay.sol";
import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {UniswapV4Addresses} from "../script/config/UniswapV4Addresses.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

/**
 * @title TokenListingRelayTest
 * @author 0xDAVZER
 * @notice Decision 0023 on a fork of Robinhood Chain mainnet: a desk launched on the live factory
 * buys a piece listed in USDG through the relay, then every guard of the relay, one test each.
 *
 * @dev Everything that moves money is the real deployment at `FORK_BLOCK`: the live factory of
 * 21 October 2026, the PoolManager and its hookless ETH/USDG pool, USDG, and Seaport 1.6. The
 * listing is signed here by a test seller with no zone, because an OpenSea order carries a zone
 * signature that expires within minutes and cannot be replayed on a pinned fork; the relay does not
 * read the order, so what it is tested against is the call it makes, not who signed the order.
 */
contract TokenListingRelayTest is Test {
    uint256 internal constant FORK_BLOCK = 94_880_000;

    address internal constant FACTORY = 0x7ba2aDD3144313542F191029b6Ed8c2c76FB9F6D;
    address internal constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint24 internal constant POOL_FEE = 500;
    int24 internal constant POOL_SPACING = 10;
    uint256 internal constant PRICE = 20e6;

    uint8 internal constant ITEM_ERC20 = 1;
    uint8 internal constant ITEM_ERC721 = 2;

    SweepTokenListingRelay internal relay;
    SweepNFTStrategyFactory internal factory = SweepNFTStrategyFactory(payable(FACTORY));
    ISeaport internal seaport = ISeaport(SEAPORT);
    IERC20 internal usdg = IERC20(USDG);
    SweepTestCollection internal collection;

    uint256 internal sellerKey = 0xA11CE;
    address internal seller;
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    /// @dev The fork needs an archive endpoint; the public one is not.
    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), FORK_BLOCK);
        relay = new SweepTokenListingRelay(IPoolManager(UniswapV4Addresses.RH_POOL_MANAGER), ISeaport(SEAPORT));
        collection = new SweepTestCollection("Relay Pieces", "RLY", "ipfs://relay/");
        seller = vm.addr(sellerKey);
        vm.deal(address(this), 10 ether);
    }

    receive() external payable {}

    /// @dev The hookless ETH/USDG pool the relay swaps on.
    function _usdgPool() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDG),
            fee: POOL_FEE,
            tickSpacing: POOL_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev What the pool asks, in ETH, for exactly `amount` USDG right now.
    function _quote(uint256 amount) internal returns (uint256 ethIn) {
        (ethIn,) = IV4Quoter(UniswapV4Addresses.RH_QUOTER)
            .quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: _usdgPool(), zeroForOne: true, exactAmount: uint128(amount), hookData: ""
                })
            );
    }

    /// @dev A fresh piece in the seller's wallet, approved to Seaport, listed for `price` USDG and
    /// signed by the seller. No zone and no conduit, so Seaport pulls the piece itself.
    function _listing(uint256 price) internal returns (uint256 tokenId, ISeaport.AdvancedOrder memory order) {
        tokenId = collection.mint(seller);
        vm.prank(seller);
        collection.setApprovalForAll(SEAPORT, true);

        ISeaport.OfferItem[] memory offer = new ISeaport.OfferItem[](1);
        offer[0] = ISeaport.OfferItem(ITEM_ERC721, address(collection), tokenId, 1, 1);
        ISeaport.ConsiderationItem[] memory consideration = new ISeaport.ConsiderationItem[](1);
        consideration[0] = ISeaport.ConsiderationItem(ITEM_ERC20, USDG, 0, price, price, payable(seller));

        ISeaport.OrderComponents memory components = ISeaport.OrderComponents({
            offerer: seller,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: 0,
            startTime: block.timestamp - 1,
            endTime: block.timestamp + 1 days,
            zoneHash: bytes32(0),
            salt: tokenId,
            conduitKey: bytes32(0),
            counter: seaport.getCounter(seller)
        });
        (, bytes32 domainSeparator,) = seaport.information();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, seaport.getOrderHash(components)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, digest);

        order = ISeaport.AdvancedOrder({
            parameters: ISeaport.OrderParameters({
                offerer: seller,
                zone: address(0),
                offer: offer,
                consideration: consideration,
                orderType: 0,
                startTime: components.startTime,
                endTime: components.endTime,
                zoneHash: bytes32(0),
                salt: components.salt,
                conduitKey: bytes32(0),
                totalOriginalConsiderationItems: 1
            }),
            numerator: 1,
            denominator: 1,
            signature: abi.encodePacked(r, s, v),
            extraData: ""
        });
    }

    /// @dev The relay's argument for buying `order` for `recipient`, swapping for `tokenAmount`.
    function _fill(ISeaport.AdvancedOrder memory order, uint256 tokenAmount, address recipient)
        internal
        pure
        returns (SweepTokenListingRelay.Fill memory)
    {
        return SweepTokenListingRelay.Fill({
            key: _usdgPool(),
            tokenAmount: tokenAmount,
            seaportCall: abi.encodeCall(
                ISeaport.fulfillAdvancedOrder, (order, new ISeaport.CriteriaResolver[](0), bytes32(0), recipient)
            )
        });
    }

    /// @dev A desk on the live factory with 0.024 ETH of treasury and a bid ramped past it.
    function _fundedDesk() internal returns (SweepNFTStrategy desk) {
        uint256 fee = factory.launchFee();
        desk = SweepNFTStrategy(
            payable(factory.launch{value: fee}(address(collection), "Relay Desk", "RDESK", 0.000_01 ether, 1 ether))
        );
        vm.warp(block.timestamp + 5);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        SweepBondingCurve(payable(factory.curveOf(address(desk)))).buy{value: 1 ether}(0, trader);
        vm.warp(block.timestamp + 1 hours);
        assertEq(desk.currentBid(), desk.treasury(), "the bid has not reached the treasury");
    }

    /// @notice The whole point: a desk buys a piece listed in USDG with the ETH it already spends.
    /// The seller is paid in USDG, the desk owns the piece, its treasury is charged exactly what
    /// the pool asked for the USDG and not the bid it sent, and the relay ends holding nothing.
    function test_ADeskBuysAUSDGListingThroughTheRelay() public {
        SweepNFTStrategy desk = _fundedDesk();
        (uint256 tokenId, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        uint256 quoted = _quote(PRICE);
        uint256 bid = desk.currentBid();
        uint256 treasuryBefore = desk.treasury();
        assertLt(quoted, bid, "fixture: the bid cannot cover the listing");

        vm.prank(keeper);
        desk.buyTargetNFT(
            bid, abi.encodeCall(relay.fill, (_fill(order, PRICE, address(desk)))), tokenId, address(relay)
        );

        assertEq(collection.ownerOf(tokenId), address(desk), "the desk does not own the piece");
        assertEq(usdg.balanceOf(seller), PRICE, "the seller was not paid in USDG");
        assertEq(treasuryBefore - desk.treasury(), quoted, "the desk was charged more than the swap");
        assertEq(address(relay).balance, 0, "the relay kept ETH");
        assertEq(usdg.balanceOf(address(relay)), 0, "the relay kept USDG");
    }

    /// @notice Called directly, the relay returns the caller every wei the swap did not use.
    function test_TheRelayReturnsTheChangeToItsCaller() public {
        (uint256 tokenId, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        uint256 quoted = _quote(PRICE);
        uint256 before = address(this).balance;

        uint256 spent = relay.fill{value: 0.05 ether}(_fill(order, PRICE, address(this)));

        assertEq(spent, quoted);
        assertEq(before - address(this).balance, quoted, "the change was not returned");
        assertEq(collection.ownerOf(tokenId), address(this));
    }

    /// @notice ETH force-sent to the relay earlier is neither spent on a fill nor handed to the
    /// next caller as change.
    function test_ADonationIsNeitherSpentNorRefunded() public {
        vm.deal(address(relay), 1 ether);
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        uint256 quoted = _quote(PRICE);
        uint256 before = address(this).balance;

        relay.fill{value: 0.05 ether}(_fill(order, PRICE, address(this)));

        assertEq(address(relay).balance, 1 ether, "the donation moved");
        assertEq(before - address(this).balance, quoted, "the caller was refunded the donation");
    }

    /// @notice No allowance outlives the fill: Seaport may spend the relay's tokens only inside the
    /// call that bought them.
    function test_NoAllowanceOutlivesTheFill() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);

        relay.fill{value: 0.05 ether}(_fill(order, PRICE, address(this)));

        assertEq(usdg.allowance(address(relay), SEAPORT), 0, "Seaport kept an allowance on the relay");
    }

    /// @notice Not enough ETH for the tokens: nothing moves, the piece stays with its seller.
    function test_TooLittleETHBuysNothing() public {
        (uint256 tokenId, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, PRICE, address(this));

        vm.expectRevert();
        relay.fill{value: 1 gwei}(f);

        assertEq(collection.ownerOf(tokenId), seller);
        assertEq(usdg.balanceOf(seller), 0);
    }

    /// @notice A pool that runs out before delivering the whole amount is refused: the order needs
    /// every unit, and a partial buy would leave it unfillable with the ETH already spent.
    function test_APoolThatCannotDeliverTheWholeAmountIsRefused() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, 1e18 * 1e6, address(this));

        vm.expectPartialRevert(SweepTokenListingRelay.PartialSwap.selector);
        relay.fill{value: 0.05 ether}(f);
    }

    /// @notice A fill that buys more tokens than the order consumes is refused rather than leaving
    /// the surplus, bought with the desk's ETH, in a contract with no way to return it.
    function test_TokensLeftOverRevertTheFill() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, PRICE + 1e6, address(this));

        vm.expectRevert(abi.encodeWithSelector(SweepTokenListingRelay.TokensLeftOver.selector, 1e6));
        relay.fill{value: 0.05 ether}(f);
    }

    /// @notice A Seaport failure fails the whole fill, with Seaport's reason attached.
    function test_ASeaportFailureRevertsTheFill() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, PRICE, address(this));
        f.seaportCall = abi.encodeWithSelector(bytes4(0xdeadbeef));

        vm.expectPartialRevert(SweepTokenListingRelay.SeaportFailed.selector);
        relay.fill{value: 0.05 ether}(f);
    }

    /// @notice No ETH, or no token amount, is not a fill.
    function test_NothingToSpendIsRefused() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, PRICE, address(this));

        vm.expectRevert(SweepTokenListingRelay.NothingToSpend.selector);
        relay.fill(f);

        f.tokenAmount = 0;
        vm.expectRevert(SweepTokenListingRelay.NothingToSpend.selector);
        relay.fill{value: 0.05 ether}(f);
    }

    /// @notice The relay only pays with the ETH it was sent: a pool whose first currency is not
    /// native ETH is refused.
    function test_APoolThatIsNotPricedInETHIsRefused() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, PRICE, address(this));
        f.key.currency0 = Currency.wrap(address(1));

        vm.expectRevert(SweepTokenListingRelay.NotANativePool.selector);
        relay.fill{value: 0.05 ether}(f);
    }

    /// @notice A hooked pool is refused: its hook could charge any fee it likes.
    function test_AHookedPoolIsRefused() public {
        (, ISeaport.AdvancedOrder memory order) = _listing(PRICE);
        SweepTokenListingRelay.Fill memory f = _fill(order, PRICE, address(this));
        f.key.hooks = IHooks(address(0x2444));

        vm.expectRevert(SweepTokenListingRelay.HookedPool.selector);
        relay.fill{value: 0.05 ether}(f);
    }

    /// @notice The settlement callback is the PoolManager's alone.
    function test_OnlyThePoolManagerCallsBack() public {
        vm.expectRevert(SweepTokenListingRelay.NotPoolManager.selector);
        relay.unlockCallback("");
    }
}
