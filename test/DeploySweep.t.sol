// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeploySweep} from "../script/DeploySweep.s.sol";
import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {RejectingSink} from "./mocks/CurveTestActors.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepTestCollection} from "../src/testing/SweepTestCollection.sol";

/// @notice The two Safe 1.4.1 entry points the test uses to create a real Safe on the fork.
/// @dev The canonical deployments, present on Robinhood Chain mainnet at the fork block and
/// verified there (`SafeL2.VERSION()` answers "1.4.1"); the calls below are the published Safe ABI,
/// proven by the Safes they create.
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/**
 * @title DeploySweepTest
 * @author 0xDAVZER
 * @notice Runs the real deploy script against a fork of Robinhood Chain mainnet and pins its
 * guards: a mainnet stack can only be handed to a Safe that needs at least two signatures, never
 * to the deploying wallet, and its fees only to an address that can receive ETH. Every wiring
 * value is read back after the deploy.
 *
 * @dev A deployment is the one step nothing can undo: an owner typed wrong owns every strategy
 * the factory will ever launch, and a fee recipient that refuses ETH reverts every launch. Each
 * refusal here is a mistake the script now stops before its first transaction.
 */
contract DeploySweepTest is Test {
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    uint256 internal constant FORK_BLOCK = 57_000_000;
    uint256 internal constant LAUNCH_FEE = 0.001 ether;

    DeploySweep internal script;
    address internal feeRecipient = makeAddr("feeRecipient");

    error ArchiveRpcRequired();

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) revert ArchiveRpcRequired();
        vm.createSelectFork(rpc, FORK_BLOCK);
        script = new DeploySweep();
    }

    /// @dev The mainnet terms with the given owner and fee recipient.
    function _terms(address owner, address recipient) internal pure returns (DeploySweep.Terms memory) {
        return DeploySweep.Terms({
            owner: owner,
            feeRecipient: recipient,
            launchFee: LAUNCH_FEE,
            phantomQuote: 1.68 ether,
            graduationThreshold: 4.2 ether,
            preprod: false
        });
    }

    /// @dev A real Safe on the fork, with `threshold` of three fresh owners.
    function _safe(uint256 threshold, uint256 salt) internal returns (address) {
        address[] memory owners = new address[](3);
        owners[0] = makeAddr("signer0");
        owners[1] = makeAddr("signer1");
        owners[2] = makeAddr("signer2");
        bytes memory setup = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            address(0),
            bytes(""),
            address(0),
            address(0),
            uint256(0),
            address(0)
        );
        return ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, setup, salt);
    }

    /// @notice On mainnet the stack cannot stay with the wallet that deployed it.
    function test_MainnetRefusesTheDeployerAsOwner() public {
        vm.expectRevert(DeploySweep.OwnerIsTheDeployer.selector);
        script.deploy(_terms(address(this), feeRecipient));
    }

    /// @notice On mainnet the owner must be a contract: an externally owned account is one key.
    function test_MainnetRefusesAnOwnerWithNoCode() public {
        vm.expectRevert(DeploySweep.OwnerIsNotAContract.selector);
        script.deploy(_terms(makeAddr("aWallet"), feeRecipient));
    }

    /// @notice On mainnet a Safe that one signature can move is refused: it is one key again.
    function test_MainnetRefusesASafeWithASingleSignature() public {
        address safe = _safe(1, 1);
        vm.expectRevert(abi.encodeWithSelector(DeploySweep.SafeThresholdTooLow.selector, 1));
        script.deploy(_terms(safe, feeRecipient));
    }

    /// @notice A fee recipient that refuses ETH is refused before anything is deployed: every
    /// launch pays it the launch fee by plain transfer, and would revert.
    function test_MainnetRefusesAFeeRecipientThatRejectsEth() public {
        address safe = _safe(2, 2);
        address sink = address(new RejectingSink());
        vm.expectRevert(DeploySweep.FeeRecipientRejectsEth.selector);
        script.deploy(_terms(safe, sink));
    }

    /// @notice The happy path: a two-of-three Safe owns the factory at the end, and every value
    /// the script wired reads back as intended.
    function test_MainnetDeploysToATwoOfThreeSafeAndReadsBack() public {
        address safe = _safe(2, 3);

        (
            SweepNFTStrategyFactory factory,
            SweepHook hook,
            SweepBurnRouter burnRouter,
            SweepSwapRouter swapRouter,
            address implementation
        ) = script.deploy(_terms(safe, feeRecipient));

        assertEq(factory.owner(), safe);
        assertEq(factory.hook(), address(hook));
        assertEq(factory.burnRouter(), address(burnRouter));
        assertTrue(factory.isPermanentRouter(address(burnRouter)));
        assertTrue(factory.isPermanentRouter(address(swapRouter)));
        assertEq(factory.strategyImplementation(), implementation);
        assertEq(factory.launchFee(), 0.001 ether);
        assertEq(factory.launchFeeRecipient(), feeRecipient);
        assertEq(hook.protocolFeeRecipient(), feeRecipient);
    }

    /// @notice Mainnet takes exactly the announced curve: a testnet scale shipped by mistake
    /// would graduate every launch at a tenth of the depth.
    function test_MainnetRefusesScaledEconomics() public {
        DeploySweep.Terms memory terms = _terms(_safe(2, 4), feeRecipient);
        terms.phantomQuote = 0.168 ether;
        terms.graduationThreshold = 0.42 ether;
        vm.expectRevert(DeploySweep.MainnetEconomicsRequired.selector);
        script.deploy(terms);
    }

    /// @notice A mainnet preprod stack runs exactly a hundredth of the curve, still handed to a
    /// two-signature Safe: a launch graduates at 0.042 ETH and the factory reads it back.
    function test_MainnetPreprodDeploysAHundredthScaleStack() public {
        DeploySweep.Terms memory terms = _terms(_safe(2, 5), feeRecipient);
        terms.phantomQuote = 0.0168 ether;
        terms.graduationThreshold = 0.042 ether;
        terms.preprod = true;
        (SweepNFTStrategyFactory factory,,,,) = script.deploy(terms);
        assertEq(factory.PHANTOM_QUOTE(), 0.0168 ether);
        assertEq(factory.GRADUATION_THRESHOLD(), 0.042 ether);
    }

    /// @notice The preprod flag opens one scale and no other: a tenth, or the full curve, under
    /// it is refused.
    function test_MainnetPreprodRefusesAnyOtherScale() public {
        DeploySweep.Terms memory terms = _terms(_safe(2, 6), feeRecipient);
        terms.preprod = true;
        vm.expectRevert(DeploySweep.MainnetEconomicsRequired.selector);
        script.deploy(terms);
        terms.phantomQuote = 0.168 ether;
        terms.graduationThreshold = 0.42 ether;
        vm.expectRevert(DeploySweep.MainnetEconomicsRequired.selector);
        script.deploy(terms);
    }

    /// @notice The preprod flag does not lift the Safe requirement.
    function test_MainnetPreprodStillRefusesTheDeployerAsOwner() public {
        DeploySweep.Terms memory terms = _terms(address(this), feeRecipient);
        terms.phantomQuote = 0.0168 ether;
        terms.graduationThreshold = 0.042 ether;
        terms.preprod = true;
        vm.expectRevert(DeploySweep.OwnerIsTheDeployer.selector);
        script.deploy(terms);
    }

    /// @notice A testnet stack at a tenth of the scale keeps every ratio: a launch graduates at
    /// 0.42 ETH, the pool opens at the curve's final price, and the factory keeps nothing.
    /// @dev The testnet shares mainnet's Uniswap v4 addresses, so the mainnet fork stands in for
    /// it once the chain id says 46630.
    function test_TestnetDeploysATenthScaleStackThatGraduates() public {
        vm.chainId(46_630);
        DeploySweep.Terms memory terms = _terms(address(this), feeRecipient);
        terms.phantomQuote = 0.168 ether;
        terms.graduationThreshold = 0.42 ether;
        (SweepNFTStrategyFactory factory,,,,) = script.deploy(terms);
        assertEq(factory.PHANTOM_QUOTE(), 0.168 ether);
        assertEq(SweepBondingCurve(payable(factory.curveImplementation())).GRADUATION_THRESHOLD(), 0.42 ether);

        address launcher = makeAddr("tenthLauncher");
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        SweepTestCollection collection = new SweepTestCollection("Tenth", "TEN", "");
        vm.prank(launcher);
        address strategy = factory.launch{value: LAUNCH_FEE}(address(collection), "Tenth", "sTEN", 1e15, 1 ether);
        SweepBondingCurve curve = SweepBondingCurve(payable(factory.curveOf(strategy)));
        assertEq(curve.reservedTokens(), (curve.trackedTokens() * 2) / 7, "the reserved share moved with the scale");

        vm.warp(block.timestamp + 5);
        address whale = makeAddr("tenthWhale");
        vm.deal(whale, 2 ether);
        vm.prank(whale);
        curve.buy{value: 1 ether}(0, whale);
        assertTrue(curve.graduated(), "a tenth-scale curve did not graduate on 1 ETH");
        assertGe(whale.balance, 2 ether - 0.45 ether, "the crossing buy was not refunded down to the threshold");

        factory.createGraduatedPool(strategy);
        assertTrue(factory.positionIdOf(strategy) != 0);
        assertEq(address(factory).balance, 0);
        assertEq(SweepNFTStrategy(payable(strategy)).balanceOf(address(factory)), 0);
    }
}
