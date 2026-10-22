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

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SweepToken} from "./SweepToken.sol";
import {ISweepFactory, ISweepHooked} from "./interfaces/ISweepFactory.sol";
import {ISweepBurnRouter} from "./interfaces/ISweepBurnRouter.sol";
import {ISweepFeeReceiver} from "./interfaces/ISweepFeeReceiver.sol";

/**
 * @title SweepRecursiveStrategy
 * @author 0xDAVZER
 * @notice The token that airdrops itself to its holders. Fees buy the token back on its own pool;
 * what is bought is owed to every holder in proportion to what they hold, and delivered to their
 * wallets as plain transfers.
 *
 * @dev No treasury, no bid, no shelf: the whole machine is a ledger. The ledger is the reward
 * accumulator every staking contract uses, kept inside the token's own transfer hook so it is
 * settled the instant a balance moves and can never be gamed by timing a transfer around a
 * distribution. The split is computed here; whoever calls `distribute` and `claimFor` decides only
 * when, never who gets what.
 */
contract SweepRecursiveStrategy is SweepToken, ISweepFeeReceiver {
    /// @notice Everything a recursive strategy is wired to at birth, in one named place.
    struct Config {
        address burnRouter;
        string name;
        string symbol;
        address hook;
        address poolManager;
        address owner;
        address curve;
    }

    /// @dev Scale of `rewardPerToken`. At 1e36 the floor in the accumulator loses under a wei per
    /// holder on any supply this token can have, so two holders at 2:1 are owed exactly 2:1. The
    /// products it appears in (a balance times the accumulator, a pot times the scale) can exceed
    /// 2^256, so every one of them goes through a 512-bit multiply-divide.
    uint256 private constant ACC_SCALE = 1e36;

    /// @notice Below this many tokens a claim is left in the ledger rather than transferred.
    /// @dev An airdrop to twenty thousand wallets is twenty thousand transfers; paying a few wei to
    /// each of them would cost more than it delivers. The share is not lost, it waits.
    uint256 public constant REWARD_DUST = 1e12;

    /// @notice Highest minimum the owner may require before a distribution runs.
    /// @dev Bounds the setter so it cannot be used to switch distributions off: a minimum of a
    /// thousand ETH would freeze the ledger while leaving the mechanism nominally in place.
    uint256 public constant MAX_REWARD_MIN = 1 ether;

    /// @notice Shortest gap between two distributions, the burn's own pace.
    /// @dev Each distribution is bounded by the pool's depth, and without a gap one transaction
    /// could chain bounded distributions into one unbounded buy and sandwich the sum.
    uint256 public constant DISTRIBUTE_COOLDOWN = 12;

    /// @notice Where the buyback's ETH is turned into this token.
    address public burnRouter;

    /// @notice ETH received from the hook and not yet spent on a distribution.
    uint256 public pendingRewards;

    /// @notice Least pending ETH a distribution needs, so the keeper never buys dust on the hour.
    uint256 public rewardMin;

    /// @notice Tokens owed per eligible token since the beginning, scaled by `ACC_SCALE`.
    uint256 public rewardPerToken;

    /// @notice Supply held by accounts that share in distributions: everything not excluded.
    uint256 public eligibleSupply;

    /// @notice Tokens this contract holds on behalf of holders, claimable and not yet claimed.
    uint256 public reserved;

    /// @notice Tokens bought while nobody was eligible, held for the next distribution.
    uint256 public carry;

    /// @notice When the last distribution ran; what the keeper paces its hour from.
    uint256 public lastDistributedAt;

    /// @notice Tokens handed to the ledger over the life of the strategy.
    uint256 public totalDistributed;

    /// @notice The accumulator value each holder was last settled at.
    mapping(address holder => uint256 value) public paid;

    /// @notice Tokens settled to each holder and not yet claimed.
    mapping(address holder => uint256 amount) public owed;

    /// @notice Accounts that hold the token without being holders: the pool, the dead address,
    /// the hook, the router, the desk, the launch's curve, and the factory (which holds the
    /// whole supply for one transaction at graduation). Fixed at initialisation; there is no
    /// setter, because an exclusion added later is how a rewards token is quietly rugged.
    mapping(address account => bool excluded) public excludedFromRewards;

    error NothingToDistribute();
    error DistributeCooldownNotElapsed();
    error Excluded();
    error RouterNotListed();

    event FeesReceived(uint256 amount, uint256 pending);
    event RewardsDistributed(uint256 ethSpent, uint256 tokensBought, uint256 eligibleSupply);
    event RewardClaimed(address indexed holder, uint256 amount);
    event RewardMinUpdated(uint256 rewardMin);
    event BurnRouterUpdated(address router);

    /**
     * @notice Wires the strategy, excludes every account that is not a holder, and makes the desk
     * a distributor of its own token so airdrops pass the lock.
     * @dev A zero router would make the first distribution revert forever. Exclusions are written
     * before the mint so the minted supply is counted where it lands.
     */
    function initialize(Config calldata config) external initializer {
        if (config.burnRouter == address(0)) revert InvalidConfiguration();

        burnRouter = config.burnRouter;
        rewardMin = 0.001 ether;
        excludedFromRewards[config.poolManager] = true;
        excludedFromRewards[DEAD_ADDRESS] = true;
        excludedFromRewards[config.hook] = true;
        excludedFromRewards[config.burnRouter] = true;
        excludedFromRewards[address(this)] = true;
        excludedFromRewards[config.curve] = true;
        excludedFromRewards[msg.sender] = true;
        isDistributor[address(this)] = true;

        __SweepCurve_init(config.curve);
        __SweepToken_init(config.name, config.symbol, config.hook, config.poolManager, config.owner);
    }

    /// @notice Queues a trade's fee for the next distribution: a pool swap's, through the hook, or
    /// a curve trade's, through the launch's curve (decision 0021). A curve's share waits here
    /// until graduation, since `distribute` buys the token on the pool.
    /// @dev Restricted to those two because they are the only things that observe a trade.
    function addFees() external payable onlyFeeSource {
        pendingRewards += msg.value;
        emit FeesReceived(msg.value, pendingRewards);
    }

    /**
     * @notice Spends pending fees on buying the token back, and owes what was bought to the holders
     * in proportion to their balances.
     *
     * @dev Permissionless: the keeper calls it on the hour, anyone else may call it sooner.
     * `NothingToDistribute` while `pendingRewards` is below `rewardMin` keeps a pass from buying
     * dust, and again when the depth bound leaves nothing to spend. The minimum gates the queue,
     * not the bounded pass: compared against the pass, any minimum above `maxBurnBuy` (4% of the
     * pool's ETH, about 0.17 ETH on a fresh 4.2 ETH pool, less as the price falls) refused every
     * distribution for good while the queue kept growing (LR-6 of the 3 October re-audit).
     *
     * @dev The buy is bounded by the burn router's `maxBurnBuy`, a share of the pool's live ETH
     * reserve, and the rest stays pending: spending the whole pot at once was one market order a
     * caller could sandwich, since the caller chooses the moment (review of the fixes,
     * 2026-10-02). `DistributeCooldownNotElapsed` keeps the bound from being chained within one
     * transaction, which used to be possible because nothing paced distributions on-chain.
     *
     * @dev The router delivers the tokens to this contract, and that delivery runs this contract's
     * own transfer hook mid-call. That is safe because the hook only settles ledgers and moves
     * `eligibleSupply` across the excluded boundary, and both the router and this contract are
     * excluded, so the delivery moves nothing; the amount bought is then read as the balance
     * delta over what was already reserved or carried, after the router returns. `nonReentrant`
     * keeps a second distribution out of the same call.
     *
     * @dev With nobody eligible the tokens are carried rather than divided by zero, and join the
     * next distribution. The whole pot is reserved, not only what the floors will pay out: a
     * holder settled across several distributions at once floors a sum rather than a sum of
     * floors, and can be owed a wei more than the per-distribution floors add up to. Reserving the
     * pot keeps `reserved` above every claim; the price is at most a wei stranded per distribution.
     */
    function distribute() external nonReentrant {
        if (block.timestamp < lastDistributedAt + DISTRIBUTE_COOLDOWN) revert DistributeCooldownNotElapsed();
        uint256 spend = pendingRewards;
        if (spend < rewardMin) revert NothingToDistribute();
        uint256 bound = ISweepBurnRouter(burnRouter).maxBurnBuy(address(this));
        if (bound < spend) spend = bound;
        if (spend == 0) revert NothingToDistribute();
        pendingRewards -= spend;

        ISweepBurnRouter(burnRouter).buyTokenWithEth{value: spend}(address(this), address(this));

        uint256 bought = balanceOf(address(this)) - reserved - carry;
        uint256 pot = bought + carry;
        uint256 eligible = eligibleSupply;
        lastDistributedAt = block.timestamp;

        if (eligible == 0) {
            carry = pot;
            emit RewardsDistributed(spend, bought, 0);
            return;
        }

        carry = 0;
        rewardPerToken += FixedPointMathLib.fullMulDiv(pot, ACC_SCALE, eligible);
        reserved += pot;
        totalDistributed += pot;
        emit RewardsDistributed(spend, bought, eligible);
    }

    /// @notice Sends the caller everything the ledger owes them.
    function claim() external nonReentrant {
        if (excludedFromRewards[msg.sender]) revert Excluded();
        _pay(msg.sender);
    }

    /**
     * @notice Sends each holder what the ledger owes them, skipping shares below `REWARD_DUST`.
     * @dev Permissionless and unrewarded, because the natural caller is the keeper and a holder can
     * always claim alone. An excluded address in the list is skipped rather than reverting the
     * batch, and so is a share below the dust threshold; a batch never fails because of one entry.
     */
    function claimFor(address[] calldata holders) external nonReentrant {
        for (uint256 i = 0; i < holders.length; i++) {
            if (excludedFromRewards[holders[i]]) continue;
            _pay(holders[i]);
        }
    }

    /// @notice What the ledger owes `holder` right now: settled plus accrued since.
    function claimable(address holder) public view returns (uint256) {
        if (excludedFromRewards[holder]) return 0;
        return owed[holder] + _accrued(holder);
    }

    /// @notice Retunes the least pending ETH a distribution needs, within `MAX_REWARD_MIN`.
    function setRewardMin(uint256 minimum) external onlyOwner {
        if (minimum > MAX_REWARD_MIN) revert InvalidConfiguration();
        rewardMin = minimum;
        emit RewardMinUpdated(minimum);
    }

    /// @notice Points the buyback at a different router, which must be one the factory lists and
    /// is excluded from rewards like the one before it. The old router stays excluded: it never
    /// held a holder's share.
    /// @dev The factory gate is decision 0015, for the same reason as on the desks: without it
    /// this setter sends every pending distribution to an arbitrary address. Reached through the
    /// hook's immutable factory reference; the zero address is never listed.
    function setBurnRouter(address router) external onlyOwner {
        if (!ISweepFactory(ISweepHooked(hook).factory()).isRouter(router)) revert RouterNotListed();
        burnRouter = router;
        excludedFromRewards[router] = true;
        emit BurnRouterUpdated(router);
    }

    /// @dev Settles a holder's ledger and transfers what it holds, if it is worth transferring.
    function _pay(address holder) private {
        _settle(holder);
        uint256 amount = owed[holder];
        if (amount < REWARD_DUST) return;
        owed[holder] = 0;
        reserved -= amount;
        _transfer(address(this), holder, amount);
        emit RewardClaimed(holder, amount);
    }

    /// @dev Moves what `holder` has accrued since its last settlement into `owed`, so a balance
    /// change that follows cannot alter it.
    function _settle(address holder) private {
        if (excludedFromRewards[holder]) return;
        owed[holder] += _accrued(holder);
        paid[holder] = rewardPerToken;
    }

    /// @dev What `holder` has earned since its last settlement: its balance times the accumulator's
    /// rise since then, scaled back down.
    function _accrued(address holder) private view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(balanceOf(holder), rewardPerToken - paid[holder], ACC_SCALE);
    }

    /// @notice Settles both sides of a transfer before the balances move, then applies the lock.
    /// @dev Settling first is what makes the ledger exact: a holder's share of every distribution
    /// so far is frozen with the balance they had, and the new balance only earns from here on.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        _settle(from);
        _settle(to);
        super._beforeTokenTransfer(from, to, amount);
    }

    /// @notice Keeps `eligibleSupply` equal to the supply held by non-excluded accounts.
    /// @dev The zero address counts as excluded, so a mint into a holder is eligible from the first
    /// block and a burn to the dead address leaves the eligible supply.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        bool fromExcluded = from == address(0) || excludedFromRewards[from];
        bool toExcluded = to == address(0) || excludedFromRewards[to];
        if (fromExcluded && !toExcluded) eligibleSupply += amount;
        else if (!fromExcluded && toExcluded) eligibleSupply -= amount;
    }

    /// @notice Accepts nothing but the hook's fees, which arrive through `addFees`.
    receive() external payable {
        revert OnlyHook();
    }
}
