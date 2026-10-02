<p align="center">
<pre align="center">
    ███████╗██╗    ██╗███████╗███████╗██████╗
    ██╔════╝██║    ██║██╔════╝██╔════╝██╔══██╗
    ███████╗██║ █╗ ██║█████╗  █████╗  ██████╔╝
    ╚════██║██║███╗██║██╔══╝  ██╔══╝  ██╔═══╝
    ███████║╚███╔███╔╝███████╗███████╗██║
    ╚══════╝ ╚══╝╚══╝ ╚══════╝╚══════╝╚═╝

    sweeping the floor, one cycle at a time
</pre>
</p>

<p align="center">
  <b>Sweep</b> — strategy tokens on Robinhood Chain, built on Uniswap v4.<br/>
  A token whose trading fees buy the floor of a collection, or bags of a token, and burn the proceeds;
  or buy the token itself and airdrop it to its holders.
</p>

<p align="center">
  <a href="https://sweep.family">sweep.family</a> ·
  <a href="https://x.com/SweepFamily">@SweepFamily</a>
</p>

<p align="center">
  <a href="#what-this-is">What this is</a> ·
  <a href="#the-machine">The machine</a> ·
  <a href="#contracts">Contracts</a> ·
  <a href="#numbers-that-matter">Numbers</a> ·
  <a href="#trust-model">Trust model</a> ·
  <a href="#build-and-test">Build and test</a> ·
  <a href="#security">Security</a>
</p>

---

## What this is

Sweep is a launchpad for strategy tokens on [Robinhood Chain](https://chain.robinhood.com), an
Arbitrum Orbit L2 with ~101 ms blocks. A launch moves its whole supply of one billion tokens onto
its own bonding curve, which sells it against a virtual 1.68 ETH reserve until the curve holds
4.2 ETH of real ETH. The buy that crosses that line graduates the launch: a Uniswap v4 pool opens
at the curve's exact final price, seeded with every wei the curve took in, and the position NFT
goes to the dead address, so the liquidity can never be withdrawn by anyone. From then on every
trade on the pool pays a ten percent fee to a hook. Eighty percent of that fee funds a treasury
that buys what the strategy targets, relists it at a markup at the strategy's own desk, and burns
the proceeds back into the token.

Most launches never find 4.2 ETH of demand. Those never open a pool and never run a desk: the
curve is the filter.

**The token is not backed by what the treasury holds.** There is no redemption, no NAV, no claim.
The inventory is a machine. Value reaches holders as buy pressure and burnt supply, never as a
claim on anything.

Three kinds of strategy ship. Two are desks; the third buys its own token and gives it away:

| Strategy | Buys | What holders get | Who may launch |
| --- | --- | --- | --- |
| `SweepNFTStrategy` | pieces of an ERC-721 collection, one id at a time | buy pressure and burnt supply | anyone, for the launch fee |
| `SweepERC20Strategy` | bags of a fungible token, `totalSupply / 1000` each | buy pressure and burnt supply | anyone, for the launch fee |
| `SweepRecursiveStrategy` | its own token, on its own pool | a periodic airdrop of that token, pro rata | anyone, for the launch fee |

A launch records on its event whether the launcher was the target's own `owner()` at that moment,
and grants nothing else for it. Any number of strategies may exist on the same target.

The recursive strategy keeps no treasury and no desk. Its fees queue as ETH; `distribute()` buys
the token back through the burn router, and `claimFor()` hands what was bought to every holder in
proportion to their balance, as plain transfers. The split is a reward accumulator settled inside
the token's transfer hook, so a balance only earns from distributions it was held through. The
pool, the dead address, the hook, the router, the curve, the factory and the strategy itself are
excluded, fixed at launch, with no setter. Curve buyers are holders from their first buy.

## The machine

```
   ┌────────────── SweepBondingCurve (one clone per launch) ─────────┐
   │  the whole supply, sold against a virtual 1.68 ETH reserve       │
   │  1% to the protocol + 2% to the creator on every trade           │
   │  99% snipe tax in the first second, gone after five              │
   │  the token stays transfer-locked: the curve is the only market   │
   └──────────────────────────────────────────────────────────────────┘
                                 │ the curve holds 4.2 ETH: graduation
                                 ▼  createGraduatedPool (anyone)
   ┌────────────── the pool opens at the curve's final price ────────┐
   │  all the curve's ETH against the reserved 2/7 of the supply      │
   │  the part the price does not need (4/49) is burnt                │
   │  full-range position, owned by 0x…dEaD                           │
   └──────────────────────────────────────────────────────────────────┘
                                 │
                          trade on the pool
                                 │
                                 ▼
   ┌────────────── SweepHook (Uniswap v4 afterSwap) ─────────────────┐
   │  10% of every swap, in both directions, from the pool's first    │
   │  block                                                           │
   │  refuses any swap not sent through a router the factory lists    │
   │  80% ──► strategy treasury            (push, addFees)            │
   │  10% ──► collection / token owner     (pull, claimFeesFor)       │
   │  10% ──► protocol                     (pull, claimFeesFor)       │
   └──────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
   ┌────────────── the desk (SweepNFTStrategy / SweepERC20Strategy) ──┐
   │  currentBid = min(seconds since last buy × pace, cap, treasury)  │
   │  a seller brings a piece or a bag and is paid the bid            │
   │  the desk lists it at cost × 1.20                                │
   │  a buyer pays the exact ask ──► pendingBurn                      │
   └──────────────────────────────────────────────────────────────────┘
                                 │ processBurn (anyone, 0.5% reward)
                                 ▼
   ┌────────────── SweepBurnRouter ───────────────────────────────────┐
   │  buys the strategy's own token on its own pool                   │
   │  delivers it to 0x…dEaD                                          │
   └──────────────────────────────────────────────────────────────────┘
```

Five design choices worth knowing before reading the code:

- **No rescue path.** The curve has no owner, no setter and no upgrade. Its reserves move to the
  pool in the same transaction that opens it, so they are only ever on the curve or in the pool;
  a seed that fails reverts the whole graduation back onto the curve, where anyone can retry it.

- **Time, not blocks.** The bid ramp is paced by `block.timestamp`. Robinhood Chain produces a
  block every ~101 ms, so anything paced by `block.number` runs about 119× faster here than on
  Ethereum, and a block-paced bid ramp would pass 1 ETH in ten seconds on this chain.
- **The bid is bounded by the treasury, on every read.** `currentBid` is the smallest of the ramp,
  the cap and what the treasury actually holds, so a published bid can never exceed what the desk
  can pay, however long the ramp has run.
- **Only listed routers may trade the pool.** The hook refuses a swap whose caller the factory does
  not list, and both shipped routers settle in ERC-20 only. This is what keeps ERC-6909 claim
  balances, which the token's transfer lock cannot see, from ever existing.
- **Fees are pulled, never pushed.** Creator and protocol shares accrue in the hook and are paid
  out by `claimFeesFor(recipient)`, which anyone may call. A recipient that cannot receive ETH
  blocks nobody but itself.

## Contracts

```
src/
  SweepBondingCurve.sol        the launch market: buy / sell / graduate, one clone per launch
  SweepToken.sol               the token: supply, transfer lock, hook wiring            (abstract)
  SweepStrategy.sol            the treasury, the bid, the burn queue                   (abstract)
  SweepDesk.sol                resale terms, the ask, the burn router                  (abstract)
  SweepNFTStrategy.sol         pieces: buyTargetNFT / sellTargetNFT
  SweepERC20Strategy.sol       bags:   buyTokens / sellTokens
  SweepRecursiveStrategy.sol   airdrops: distribute / claimFor / claim
  SweepNFTStrategyFactory.sol  launch, launchERC20, launchRecursive; createGraduatedPool
  SweepHook.sol                the fee, its split, the router gate, the Trade event
  SweepBurnRouter.sol          proceeds → the strategy's own token → the dead address
  SweepSwapRouter.sol          buy / sell / quote for a front end, with the trader in hookData
  libraries/                   SweepCurveMath (the curve's pricing), SweepGraduationMath (the seed)
  interfaces/                  ISweepFactory, ISweepFeeReceiver, ISweepLockedToken, ISweepBondingCurve,
                               ISweepHookRegistry, ISweepBurnRouter, IOwnable
  testing/                     SweepTestCollection, SweepTestToken: testnet fixtures, never for mainnet
script/
  DeploySweep.s.sol            the whole stack: implementations → factory → mined hook → routers
  DeployHook.s.sol             re-mine and redeploy the hook alone
  DeploySwapRouter.s.sol       redeploy the swap router alone
  DeployTestCollection.s.sol   a fixture collection on a testnet
  config/UniswapV4Addresses.sol  Uniswap v4 addresses per chain, each verified on-chain before being pinned
test/
  *.t.sol                      one suite per contract, plus EndToEnd, Invariants, PoolBypass, GasProbe
  mocks/                       hostile venues, lying collections, probes that read transient state
  shared/SweepForkTest.sol     the protocol deployed against the real Uniswap v4 at a pinned block
```

Inheritance, bottom up:

```
SweepToken                    ERC-20, Ownable, Initializable, ReentrancyGuard
  ├── SweepStrategy           treasury, bid ramp, burn queue, fee receiver
  │     └── SweepDesk         resale terms, ask, burn router
  │           ├── SweepNFTStrategy
  │           └── SweepERC20Strategy
  └── SweepRecursiveStrategy  reward accumulator, fee receiver
```

Strategies and curves are clones of implementation contracts the factory owner publishes; an
implementation itself can never be initialised. The factory, the hook and the routers are plain
contracts with no proxy and no upgrade path. Nothing
in the protocol is upgradeable: a change ships as a new stack.

### Solidity conventions

- Custom errors, never `require` strings.
- **No comments inside a function body.** Every guard is explained in the NatSpec above the
  signature, by naming what breaks without it. If a guard cannot be explained from above the
  function, the function is split.
- Explicit named imports. Money is `uint256`. Prices are wei per 10¹⁸ tokens.
- Tests are named after the property they pin: `test_PurchaseRefusesAShortBag`,
  `test_FeesCreditedDuringTheFillAreNotBookedAsChange`.

## Numbers that matter

| Constant | Value | Where |
| --- | --- | --- |
| Supply | 1,000,000,000 tokens, all on the launch's curve | `SweepToken.MAX_SUPPLY` |
| Opening price | 1.68 ETH FDV: the virtual reserve over the supply | `SweepBondingCurve.PHANTOM_QUOTE` |
| Graduation | at 4.2 ETH of real ETH on the curve; 5/7 of the supply sellable before it | `SweepBondingCurve.GRADUATION_THRESHOLD` |
| Graduation price | 12.25× the opening price, 20.58 ETH FDV; the pool opens at exactly this price | `SweepNFTStrategyFactory` |
| Burnt at graduation | 4/49 of the supply (~8.16%), the reserved allocation the pool does not need | `createGraduatedPool` |
| Curve fees | 1% to the protocol + 2% to the creator, on every curve trade's ETH leg | `SweepBondingCurve` |
| Snipe tax | 99% at second zero, ~25% at one, ~3% at two, zero from second five; launcher and creator exempt | `SweepBondingCurve` |
| Pool | ETH / token, LP fee 0, tick spacing 60, hooked, full range | `SweepNFTStrategyFactory` |
| Swap fee | 10% in both directions, flat from the pool's first block | `SweepHook.FEE_BPS` |
| Fee split | 80 treasury / 10 owner / 10 protocol | `SweepHook` |
| Bid pace | 10¹² to 10¹⁶ wei per second, cap ≤ 100 ETH, chosen at launch | `SweepNFTStrategyFactory` bounds |
| Resale markup | ×1.20, set on the factory and retunable per strategy by the owner | `resaleMultiplierBps` |
| Ask decay | off (window 0): a fixed ask; the decay is a lever kept switched off | `SweepDesk.askDecayWindow` |
| Burn pacing | 0.1 ETH per pass by default, never above 0.25 ETH, 12 s cooldown, 0.5% to the caller | `SweepStrategy.MAX_BURN_INCREMENT` |
| Bag | `totalSupply / 1000`, sized by the factory, never by a front end | `SweepNFTStrategyFactory.BAG_DIVISOR` |
| Launch fee | 0.001 ETH by default, exact in both directions | `SweepNFTStrategyFactory.launchFee` |
| Airdrop floor | 0.001 ETH pending before a distribution runs; shares under 10¹² wei are left in the pot | `SweepRecursiveStrategy` |
| Hook permissions | `0x2444`: before-initialize, after-add-liquidity, after-swap, after-swap-returns-delta | `SweepHook.getHookPermissions` |

The hook's address encodes its permissions in its low bits and is mined with CREATE2 over an
initcode that contains the factory's address, so a new factory always means a new hook.

## Trust model

What nobody can do, including the protocol:

- withdraw the pool's liquidity (the position NFT is owned by the dead address);
- touch a curve's ETH: the curve has no owner, no setter and no rescue, and its entry in the
  token's transfer lock cannot be changed, so it cannot be frozen either;
- change a launched pool's hook, mint supply, or take pieces out of a desk;
- bypass the fee through a second, unhooked pool: transfers of the token are locked to the curve
  and the pool, every movement through the PoolManager needs the hook's allowance — distributors
  included — and the hook refuses swaps that do not come through a listed router;
- delist the base swap and burn routers, which are permanent.

What the factory owner can do, immediately and with no timelock, on every strategy it owns, within
the bounds each setter enforces:

- set a desk's bid pace and cap (within the launch bounds; a raise at most doubles, once per seven
  days), its resale terms, its burn pacing (at most 0.25 ETH a pass) and its burn router (only a
  router the factory lists);
- list a new router, and name distributors that may send wallet to wallet;
- launch on behalf of a target, change the launch fee and its recipient, and change which
  implementation future launches clone.

Each setter's NatSpec says what the lever reaches and why it exists. The owner is a multisig.
The transfer lock is a deliberate product decision and costs composability: no bridging, no
lending collateral, no wallet-to-wallet sends.

## Build and test

Foundry, Solidity `0.8.26`, EVM `cancun`. Dependencies are git submodules pinned to exact commits,
except `solady`, which is vendored in the tree. Initialise everything except `v4-hooks-public`'s
own nested libraries, which nothing here compiles against:

```bash
for lib in forge-std openzeppelin-contracts permit2 v4-core v4-periphery; do
  git submodule update --init --recursive "lib/${lib}"
done
git submodule update --init lib/v4-hooks-public     # not --recursive

forge fmt --check
forge build --sizes
forge test -vvv                                     # every suite; the fork suites need the RPC below
FOUNDRY_PROFILE=coverage forge build                # optimizer off: proves nothing is stack-too-deep
forge coverage --ir-minimum --report summary
```

The fork suites (`Factory`, `FactoryERC20`, `FactoryRecursive`, `BurnRouter`, `SwapRouter`,
`PoolBypass`, `EndToEnd`, `Invariants`) deploy the protocol against
the real Uniswap v4 on Robinhood Chain at block 57,000,000. They need an **archive** endpoint in
`ROBINHOOD_RPC_URL`: the public RPC does not serve historical state, so the
harness refuses to start without one rather than failing inside the EVM. Without it, run the rest:

```bash
forge test --no-match-path 'test/{Factory,FactoryERC20,FactoryRecursive,BurnRouter,EndToEnd,Invariants,PoolBypass,SwapRouter}.t.sol'
```

CI runs both: the unit job on every pull request, the fork job and coverage on every push and on
pull requests from this repository. Deep fuzz and invariant runs are a profile away:

```bash
FOUNDRY_PROFILE=intense forge test
```

Uniswap v4 on Robinhood Chain (mainnet and testnet share the addresses, verified on-chain):
PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. The rest is in
`script/config/UniswapV4Addresses.sol`.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

- 351 tests across 22 suites: unit suites against mocks, fuzz suites on every piece of arithmetic
  (the curve's pricing round trip included), invariant suites on the money ledgers and on the
  curve's books, and fork suites that run every launch, curve trade, graduation, pool trade,
  purchase, resale, burn and airdrop against the real Uniswap v4 bytecode on Robinhood Chain. CI
  runs all of them on every push.
- The one arbitrary external call in the protocol, `SweepNFTStrategy.buyTargetNFT`, is bounded by
  the bid and by the treasury, refused when the venue is the collection itself, costed as a balance
  delta net of any fee credited during the call, refused at zero cost, and followed by an assertion
  that the desk owns the exact piece it paid for.

## Acknowledgements

- [Robinhood](https://robinhood.com) for Robinhood Chain.
- [Uniswap](https://uniswap.org) for v4, and for a hook that makes a fee unavoidable.
- [Solady](https://github.com/Vectorized/solady) and [OpenZeppelin](https://openzeppelin.com) for
  the libraries underneath.

## License

MIT. Built by [0xDAVZER](https://x.com/davzer_) for [Sweep](https://sweep.family).
