// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {SweepNFTStrategy} from "../src/SweepNFTStrategy.sol";
import {SweepERC20Strategy} from "../src/SweepERC20Strategy.sol";
import {SweepRecursiveStrategy} from "../src/SweepRecursiveStrategy.sol";
import {SweepNFTStrategyFactory} from "../src/SweepNFTStrategyFactory.sol";
import {SweepHook} from "../src/SweepHook.sol";
import {SweepBurnRouter} from "../src/SweepBurnRouter.sol";
import {SweepSwapRouter} from "../src/SweepSwapRouter.sol";
import {SweepBondingCurve} from "../src/SweepBondingCurve.sol";
import {ISweepFactory} from "../src/interfaces/ISweepFactory.sol";
import {UniswapV4Addresses} from "./config/UniswapV4Addresses.sol";

/**
 * @title DeploySweep
 * @author 0xDAVZER
 * @notice The whole protocol, in the only order it can be deployed in.
 *
 * @dev The factory and the hook depend on each other and neither can be built first. The hook's
 * address is not free — it has to encode its permissions, so it comes from a salt mined over an
 * initcode that already contains the factory's address. That settles the direction: the factory is
 * built first with no hook, the hook is mined against it, and the factory is told once.
 *
 * @dev `setHook` accepts one call and never another, so this script is not rerunnable against a
 * factory that already has one. That is the intent — every strategy already launched has that hook
 * welded into the identity of the pool it trades on.
 *
 * @dev The two routers are admitted to the factory's swap allow-list here — permanently, which
 * is decision 0015: with a transfer-locked token they are the only market, so a deploy freezes
 * them in and no owner, honest or compromised, can ever delist them. Since the pre-mainnet
 * review the hook refuses a swap whose caller is not on that list, which is what keeps ERC-6909
 * claims on a strategy's token from ever existing — both of these settle in ERC-20 and consume
 * the hook's transient allowance exactly. Anything else added later is an owner decision to be
 * read as carefully as a `setDistributor`.
 *
 * @dev The wiring runs with the BROADCASTER as the factory's owner and hands ownership to
 * `SWEEP_OWNER` as the very last step (decision 0015). Every wiring call is `onlyOwner`, so a
 * factory born owned by a Safe could never be wired by the deploying wallet at all; and a
 * strategy launched before the handover would be owned by the deployer forever, which is why
 * the transfer happens inside this same script rather than as a step someone remembers later.
 *
 * @dev Run with `--slow`. Each step here depends on the receipt of the one before, and `forge
 * script` does not wait for receipts otherwise — brick 1 lost a deployment to exactly that.
 */
/// @notice The one view of a Safe the script reads: how many signatures move it.
/// @dev Safe 1.4.1's published ABI; the deploy test creates real Safes from the canonical
/// deployments on Robinhood Chain mainnet and reads this back from them.
interface ISafeThreshold {
    function getThreshold() external view returns (uint256);
}

contract DeploySweep is Script {
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error MinedAddressMismatch(address expected, address actual);
    error OwnerIsTheDeployer();
    error OwnerIsNotAContract();
    error SafeThresholdTooLow(uint256 threshold);
    error FeeRecipientRejectsEth();
    error ReadBackMismatch(string what);
    error MainnetEconomicsRequired();

    /// @notice Everything a deployment is told, rather than derives.
    /// @dev The curve economics are the virtual reserve and the graduation threshold every
    /// launch of this stack will use. Mainnet takes exactly 1.68 and 4.2 ETH; a testnet may scale
    /// both by one factor, which keeps every ratio and shrinks only the ETH a graduation costs.
    /// `preprod` is the one exception on mainnet: a rehearsal stack at exactly a hundredth of the
    /// curve, owned by the same Safe, run before the database is erased and the real stack deployed.
    struct Terms {
        address owner;
        address feeRecipient;
        uint256 launchFee;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        bool preprod;
    }

    uint256 internal constant MAINNET_PHANTOM_QUOTE = 1.68 ether;
    uint256 internal constant MAINNET_GRADUATION_THRESHOLD = 4.2 ether;
    uint256 internal constant PREPROD_PHANTOM_QUOTE = 0.0168 ether;
    uint256 internal constant PREPROD_GRADUATION_THRESHOLD = 0.042 ether;

    uint256 internal constant ROBINHOOD_MAINNET = 4663;
    uint256 internal constant MIN_SAFE_THRESHOLD = 2;
    /// @dev A throwaway sender for the fee recipient probe: the script contract's own address is
    /// ephemeral, and forge refuses a script that relies on it.
    address internal constant FEE_PROBE = address(uint160(uint256(keccak256("sweep.deploy.fee-probe"))));

    /**
     * @notice Deploys the implementation, the factory and the hook, and wires them together.
     *
     * @dev `SWEEP_FEE_RECIPIENT` receives both the launch fee and the protocol's tenth of every
     * trading fee, on pools and on curves alike. `SWEEP_OWNER` — the Safe, on mainnet — ends up
     * owning the factory and, through it, every strategy it launches, but only after the wiring:
     * see the contract doc for why the handover is last.
     *
     * @dev The burn router is deployed after the hook because it reads the hook off the factory,
     * and set on the factory before any launch because a strategy holds its router from birth. The
     * swap router is the wallet's road onto the pool; it is not wired into anything, the front end
     * simply calls it. The curve implementation is what every launch clones its market from, and
     * the factory refuses one whose economics disagree with its own. `SWEEP_LAUNCH_FEE` overrides
     * the factory's default, which a testnet with a thin faucet has reason to.
     */
    function run()
        external
        returns (
            SweepNFTStrategyFactory factory,
            SweepHook hook,
            SweepBurnRouter burnRouter,
            SweepSwapRouter swapRouter,
            address implementation
        )
    {
        return deploy(
            Terms({
                owner: vm.envAddress("SWEEP_OWNER"),
                feeRecipient: vm.envAddress("SWEEP_FEE_RECIPIENT"),
                launchFee: vm.envOr("SWEEP_LAUNCH_FEE", uint256(0.001 ether)),
                phantomQuote: vm.envOr("SWEEP_PHANTOM_QUOTE", MAINNET_PHANTOM_QUOTE),
                graduationThreshold: vm.envOr("SWEEP_GRADUATION_THRESHOLD", MAINNET_GRADUATION_THRESHOLD),
                preprod: vm.envOr("SWEEP_MAINNET_PREPROD", false)
            })
        );
    }

    /**
     * @notice The deployment itself, with its three inputs as arguments rather than environment
     * variables.
     *
     * @dev Split from `run` so a test can drive it: the environment is one per process, and
     * tests that each set their own owner through it race one another when run in parallel. The
     * broadcaster is `msg.sender`, which `forge script --private-key` makes that key's address,
     * so the wallet the guards compare against is the wallet that signs.
     */
    function deploy(Terms memory terms)
        public
        returns (
            SweepNFTStrategyFactory factory,
            SweepHook hook,
            SweepBurnRouter burnRouter,
            SweepSwapRouter swapRouter,
            address implementation
        )
    {
        _assertHandover(terms);
        (factory, hook, burnRouter, swapRouter, implementation) = _broadcast(terms);
        _assertWiring(factory, hook, swapRouter, terms);
        _log(factory, hook, swapRouter);
    }

    /**
     * @notice The transactions, in the only order that works; see the contract doc and `run`.
     * @dev Split from `deploy` only to keep every function inside the reachable stack without
     * `via_ir`. The salt is logged here, where it is known, so a hook can be re-derived later.
     * @dev Launches open to every target on any chain but mainnet, before ownership moves
     * (decision 0018). A testnet stack exists to be launched on by anyone, and the factory deploys
     * curated; mainnet stays curated until its owner admits targets or opens launches itself.
     */
    function _broadcast(Terms memory terms)
        internal
        returns (
            SweepNFTStrategyFactory factory,
            SweepHook hook,
            SweepBurnRouter burnRouter,
            SweepSwapRouter swapRouter,
            address implementation
        )
    {
        (address poolManager, address positionManager, address permit2) = UniswapV4Addresses.forChain(block.chainid);

        vm.startBroadcast(msg.sender);

        implementation = address(new SweepNFTStrategy());
        factory = new SweepNFTStrategyFactory(
            positionManager,
            permit2,
            poolManager,
            implementation,
            terms.feeRecipient,
            msg.sender,
            terms.phantomQuote,
            terms.graduationThreshold
        );

        bytes memory args = abi.encode(IPoolManager(poolManager), ISweepFactory(address(factory)), terms.feeRecipient);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SweepHook).creationCode, args);

        hook = new SweepHook{salt: salt}(IPoolManager(poolManager), ISweepFactory(address(factory)), terms.feeRecipient);
        if (address(hook) != expected) revert MinedAddressMismatch(expected, address(hook));

        factory.setHook(address(hook));

        burnRouter = new SweepBurnRouter(IPoolManager(poolManager), ISweepFactory(address(factory)));
        factory.setBurnRouter(address(burnRouter));
        swapRouter = new SweepSwapRouter(IPoolManager(poolManager), ISweepFactory(address(factory)));
        factory.setRouterPermanent(address(swapRouter));
        factory.setCurveImplementation(address(new SweepBondingCurve(terms.phantomQuote, terms.graduationThreshold)));
        factory.setERC20Implementation(address(new SweepERC20Strategy()));
        factory.setRecursiveImplementation(address(new SweepRecursiveStrategy()));
        if (block.chainid != ROBINHOOD_MAINNET) factory.setOpenLaunches(true);
        if (terms.launchFee != factory.launchFee()) factory.setLaunchFee(terms.launchFee, terms.feeRecipient);
        if (terms.owner != msg.sender) factory.transferOwnership(terms.owner);

        vm.stopBroadcast();
        console2.log("hook salt");
        console2.logBytes32(salt);
    }

    /// @notice Prints the deployed stack as the deployment record wants it.
    function _log(SweepNFTStrategyFactory factory, SweepHook hook, SweepSwapRouter swapRouter) internal view {
        console2.log("chain           ", block.chainid);
        console2.log("owner           ", factory.owner());
        console2.log("curve impl      ", factory.curveImplementation());
        console2.log("implementation  ", factory.strategyImplementation());
        console2.log("erc20 impl      ", factory.erc20Implementation());
        console2.log("recursive impl  ", factory.recursiveImplementation());
        console2.log("factory         ", address(factory));
        console2.log("hook            ", address(hook));
        console2.log("hook flag bits  ", uint160(address(hook)) & 0x3FFF);
        console2.log("burn router     ", factory.burnRouter());
        console2.log("swap router     ", address(swapRouter));
        console2.log("launch fee wei  ", factory.launchFee());
    }

    /**
     * @notice Refuses, before the first transaction, a handover that cannot be undone.
     *
     * @dev Mainnet only: a testnet stack stays with its deployer on purpose, and may run scaled
     * economics. `MainnetEconomicsRequired` — mainnet launches take exactly the 1.68 / 4.2 ETH
     * curve the product announces; a testnet scale shipped by mistake would graduate every launch
     * at a tenth of the depth and open pools a sandwich could drain. The one exception is a
     * preprod stack, asked for by name (`SWEEP_MAINNET_PREPROD`), which takes exactly a hundredth
     * and nothing else: a rehearsal on real collections and real OpenSea orders for a few cents,
     * still behind the same Safe, and thrown away before the real deploy. `OwnerIsTheDeployer`
     * — a stack left with the deploying wallet is a stack one leaked key can retune, and every
     * strategy it launches inherits that owner. `OwnerIsNotAContract` — an externally owned
     * account is one key too, and a mistyped address with no code would own the protocol with
     * nobody able to sign for it. `SafeThresholdTooLow` — a Safe that one signature can move is
     * the same single key behind a contract; the owner is meant to need two people.
     *
     * @dev `FeeRecipientRejectsEth`, on every chain: the launch fee is paid to the recipient by
     * plain transfer inside every launch, and the hook pays the protocol's share the same way, so
     * a recipient that refuses ETH would revert every launch from the first. The probe sends one
     * wei from a funded throwaway address outside the broadcast, so nothing is ever sent for real.
     */
    function _assertHandover(Terms memory terms) internal {
        address owner = terms.owner;
        address feeRecipient = terms.feeRecipient;
        if (block.chainid == ROBINHOOD_MAINNET) {
            (uint256 phantom, uint256 graduation) = terms.preprod
                ? (PREPROD_PHANTOM_QUOTE, PREPROD_GRADUATION_THRESHOLD)
                : (MAINNET_PHANTOM_QUOTE, MAINNET_GRADUATION_THRESHOLD);
            if (terms.phantomQuote != phantom || terms.graduationThreshold != graduation) {
                revert MainnetEconomicsRequired();
            }
            if (owner == msg.sender) revert OwnerIsTheDeployer();
            if (owner.code.length == 0) revert OwnerIsNotAContract();
            uint256 threshold = ISafeThreshold(owner).getThreshold();
            if (threshold < MIN_SAFE_THRESHOLD) revert SafeThresholdTooLow(threshold);
        }
        vm.deal(FEE_PROBE, 1);
        vm.prank(FEE_PROBE);
        (bool accepted,) = feeRecipient.call{value: 1}("");
        if (!accepted) revert FeeRecipientRejectsEth();
    }

    /**
     * @notice Reads every wired value back from the chain after the broadcast and refuses a
     * deployment that does not match what was asked.
     *
     * @dev The broadcast is a sequence of separate transactions, and a step that lands wrong — a
     * router left delistable, a fee pointed elsewhere, ownership not handed over — would
     * otherwise be discovered by the first user it hurts. `ReadBackMismatch` names the value.
     */
    function _assertWiring(
        SweepNFTStrategyFactory factory,
        SweepHook hook,
        SweepSwapRouter swapRouter,
        Terms memory terms
    ) internal view {
        if (factory.owner() != terms.owner) revert ReadBackMismatch("owner");
        if (factory.PHANTOM_QUOTE() != terms.phantomQuote) revert ReadBackMismatch("phantom quote");
        if (factory.GRADUATION_THRESHOLD() != terms.graduationThreshold) {
            revert ReadBackMismatch("graduation threshold");
        }
        if (factory.hook() != address(hook)) revert ReadBackMismatch("hook");
        if (uint160(address(hook)) & 0x3FFF != FLAGS) revert ReadBackMismatch("hook flags");
        if (factory.burnRouter() == address(0)) revert ReadBackMismatch("burn router");
        if (!factory.isPermanentRouter(factory.burnRouter())) revert ReadBackMismatch("burn router permanent");
        if (!factory.isPermanentRouter(address(swapRouter))) revert ReadBackMismatch("swap router permanent");
        if (factory.strategyImplementation() == address(0)) revert ReadBackMismatch("nft implementation");
        if (factory.curveImplementation() == address(0)) revert ReadBackMismatch("curve implementation");
        if (factory.erc20Implementation() == address(0)) revert ReadBackMismatch("erc20 implementation");
        if (factory.recursiveImplementation() == address(0)) revert ReadBackMismatch("recursive implementation");
        if (factory.launchFee() != terms.launchFee) revert ReadBackMismatch("launch fee");
        if (factory.launchFeeRecipient() != terms.feeRecipient) revert ReadBackMismatch("launch fee recipient");
        if (hook.protocolFeeRecipient() != terms.feeRecipient) revert ReadBackMismatch("protocol fee recipient");
        if (factory.openLaunches() != (block.chainid != ROBINHOOD_MAINNET)) revert ReadBackMismatch("open launches");
    }
}
