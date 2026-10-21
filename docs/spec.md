# Bagehot protocol specification

Version 1.0-draft (P02). Status: **awaiting the P02 human gate**. After approval this file and
`spec/vectors/**` are protected; changes go through `/spec-change`.

The specification wins over the code: if the Solidity contracts or the Python model disagree with
this document, they are wrong until a change is approved. Every rule here is written so that two
engineers would produce bit-identical implementations. Where this document gives pseudocode, the
**order of statements is normative** — including the order of `require` checks, because the
differential test compares revert reasons by name.

---

## 1. Scope

### 1.1 What Bagehot is

A collateralised-debt protocol issuing a USD-pegged stablecoin (`StableToken`) against WETH, with:

- a fixed, per-second-compounded interest rate on all debt;
- a minimum debt per position and a WETH gas reserve per position;
- redemption at par against the riskiest positions (the peg floor);
- exactly one liquidation strategy per deployment, chosen at deployment and immutable;
- a loss waterfall: collateral → penalty → strategy → redistribution → deficit ledger → shutdown;
- an automatic, irreversible shutdown with an in-kind pro-rata settlement.

### 1.2 Deployment variants

| | Deployment A — stability pool | Deployment B — Dutch auction |
|---|---|---|
| Strategy contract | `StabilityPool` | `DutchAuctionHouse` |
| Liquidation | Pool burns deposits against the debt, receives collateral worth at most debt × (1 + penalty); surplus returns to the owner | Whole collateral is auctioned on a decaying curve; buyers repay debt then penalty; leftover collateral returns to the owner |
| Remainder the strategy cannot absorb | Redistributed to all other positions; deficit only if no other position exists | Auction shortfall goes to the deficit ledger |
| Interest | `POOL_SHARE_BPS` to pool depositors, the rest to the reserve | All to the reserve |
| Penalty proceeds | To pool depositors (part of the seized collateral) | To the reserve |

Both deployments share every other contract and every other rule in this document. They are deployed
with identical parameters except the strategy-specific ones (§3).

### 1.3 Non-goals (MVP)

- Any collateral other than WETH; any oracle other than one Chainlink price feed plus the L2
  sequencer-uptime feed.
- Partial liquidation / close factor (blueprint §4.5 — deferred, see §12 D-14).
- User-set or variable interest rates, borrowing fees, recovery mode, governance, admin roles,
  parameter setters, pausing, proxies, upgradeability. The only privileged action is the one-shot
  `wire(...)` (§9).
- Transferable positions (positions are bound to their opening address).
- Stepwise auction curves; auction parameters per position.
- Peg dynamics: no secondary-market model of the stablecoin.
- Mainnet deployment of any kind.

---

## 2. Notation and conventions

### 2.1 Units

| Symbol | Value | Used for |
|---|---|---|
| `WAD` | 10^18 | token amounts (WETH, stablecoin), prices (USD per WETH), ratios (MCR, ICR, TCR, fee rates, penalty, buffer, cusp) |
| `RAY` | 10^27 | interest index, per-second rates and decay factors (`RATE_PER_SECOND`, `BASE_RATE_DECAY`, `CUT`) |
| `BPS` | 10_000 | `POOL_SHARE_BPS`, `DEFICIT_LIMIT_BPS` |
| `DECIMAL_PRECISION` | 10^18 | precision of per-unit stability-pool gains and redistribution accumulators |
| `P_PRECISION` | 10^36 | precision of the stability-pool product `P` |
| `SCALE_FACTOR` | 10^9 | stability-pool scale step |
| `P_MIN` | `P_PRECISION / SCALE_FACTOR` = 10^27 | lower bound of `P` after normalisation |
| `SCALE_SPAN` | 2 | number of scales above the snapshot scale counted for gains |
| `NICR_PRECISION` | 10^20 | display precision of the `nicr()` view only |

Time is `block.timestamp` in seconds. All amounts are `uint256`. The oracle's answer (8 decimals on
Base) is converted to WAD in `OracleAdapter` and nowhere else (§6.10).

Names carry units where ambiguous: `debtWad`, `indexRay`, `priceWad`, `feeRateWad`, `shareBps`.

### 2.2 Arithmetic

- **Checked arithmetic.** Every addition, subtraction and multiplication reverts on overflow or
  underflow (Solidity 0.8 semantics: `Panic(0x11)`; the model raises `Overflow` / `Underflow`).
  A division by zero is `Panic(0x12)` / `DivisionByZero`; the preconditions in this spec make every
  divisor non-zero, so reaching one is a bug.
- **Rounding helpers.** Every product-then-divide uses exactly one of:
  - `mulDivDown(x, y, d) = floor(x·y / d)`
  - `mulDivUp(x, y, d) = ceil(x·y / d)`

  computed with a 512-bit intermediate (OZ `Math.mulDiv` with `Rounding.Floor` / `Rounding.Ceil`).
  The result must fit in 256 bits. A bare `/` on amounts, prices, indices, shares or accumulators
  is a bug, except these explicitly listed floor divisions: the divisions with error carry
  (§6.5.2, §6.6.2, §6.6.5), the divisions by `SCALE_FACTOR^k` in §6.6.6 and §6.6.7, and
  `MAX_PRICE / 10^(18 − FEED_DECIMALS)` in §6.10.1. §8 lists the direction of every division in the
  system, these included.
- **Exact comparisons.** Every decision that compares two ratios is made by cross-multiplication
  of integers, never by comparing rounded ratios:

  | Decision | Exact test |
  |---|---|
  | position below MCR | `coll · price < MCR · debt` |
  | position at or above MCR | `coll · price ≥ MCR · debt` |
  | system below critical TCR | `systemColl · price < CRITICAL_TCR · systemDebt` |
  | auction below cusp | `price(t) · WAD < CUSP · top` |
  | deficit above limit | `deficit · BPS > DEFICIT_LIMIT_BPS · totalSupply` |
  | sorted-list order | `cA · nB` vs `cB · nA` (§6.3) |

  `coll`, `debt` and `price` are the values defined at the point of use (effective collateral
  including pending redistribution, debt rounded up, WAD price). The views `icr()`, `nicr()`,
  `tcr()` return rounded-down ratios for display only and are never used in a decision.
- **Supply cap.** `StableToken.totalSupply` never exceeds `2^128 − 1`; a mint that would exceed it
  reverts `SupplyCapExceeded()`. This bounds every stablecoin amount in the system and is relied on
  by the stability-pool bounds in §6.6.6.

### 2.3 Power function `rpow`

`rpow(x, n)` returns `x^n` with `x` in RAY and integer `n ≥ 0`, by square-and-multiply,
least-significant bit first, **rounding every product up**:

```
function rpow(x, n):
    z = RAY
    b = x
    e = n
    while e > 0:
        if e is odd:
            z = mulDivUp(z, b, RAY)
        e = e >> 1
        if e > 0:
            b = mulDivUp(b, b, RAY)
    return z
```

`rpow(x, 0) = RAY`. No assembly. The order of multiplications is part of the spec: implementations
using a different order (e.g. MakerDAO's) produce different low-order digits and fail the vectors.
Rounding every product up biases growth factors up and decay factors up (slower decay); every use
in this spec favours the protocol under that bias (§8).

Consequence: compounding is not exactly frequency-independent at the last digits. One accrual of a
year and 365 daily accruals of the starting rate differ by 104 RAY units (≈ 10^-25 relative) —
vector `interest.json#frequency`. The model and the contracts agree bit-for-bit given the same
sequence of accrual timestamps.

### 2.4 Effective values of a position

Redistribution is lazy (§6.5). Wherever this spec says "effective", it includes pending rewards:

```
pendingColl(p) = mulDivDown(p.stake, LColl − p.snapLColl, DECIMAL_PRECISION)
pendingNorm(p) = mulDivDown(p.stake, LDebt − p.snapLDebt, DECIMAL_PRECISION)
effColl(p)     = p.coll + pendingColl(p)
effNorm(p)     = p.normDebt + pendingNorm(p)
debtOf(n)      = mulDivUp(n, index, RAY)            // stablecoin owed for n normalised debt
effDebt(p)     = debtOf(effNorm(p))
```

### 2.5 Conventions for operations

- `msg.sender` is the immediate caller. "Owner" is `positions[id].owner`.
- `WETH` transfers use OZ `SafeERC20`. A failed WETH transfer reverts with whatever WETH reverts
  with; the model reports `WethTransferFailed` and the differential test maps any revert raised
  inside WETH to that name.
- Stablecoin movements initiated by the core use the privileged `StableToken.burnFrom` /
  `moveFrom` (§5.9). Core contracts only ever pass as `account` their own address, the `msg.sender`
  of the current external call, or — in `VaultManager.redeemCollateral` only — the `redeemer`
  argument, which the RedemptionModule always sets to its own `msg.sender`. Every function that burns or moves the caller's stablecoin
  first checks `token.balanceOf(account) ≥ amount` and reverts `InsufficientBalance()`, so the
  revert name is deterministic.
- Every state-changing external function of every core contract except `wire` starts with
  `require(wired, NotWired)`. Exempt: `OracleAdapter` (has no `wire`) and the standard ERC-20
  surface of `StableToken` (`transfer`, `approve`, `transferFrom`). For every function restricted
  to a calling **contract** (`Unauthorized`, §9), the order is: `wired` first, then the caller
  check, then the function's own checks in the order its pseudocode or table gives them. Owner-only
  functions (`NotOwner`) are different: the owner check sits exactly where their pseudocode puts it —
  after the mode and argument checks and after `PositionNotActive` — so e.g. a non-owner calling
  `withdrawCollateral(id, 0)` gets `ZeroAmount`, not `NotOwner`. Every contract that holds or moves tokens guards all state-changing
  external functions with one transient reentrancy lock (OZ `ReentrancyGuardTransient`); a
  reentrant call reverts `ReentrancyGuardReentrantCall()`. §5.10 lists the permitted cross-contract
  call paths and which entry points are lock-free callbacks.
- Phrases: "**accrue**" inside VaultManager = the internal function `_accrue()` (§6.2; not an
  external self-call, so it does not hit the lock); in any other contract = the external call
  `vaultManager.accrue()`, which runs `_accrue()`; "**apply pending**" = §6.5.3;
  "**update stake**" = §6.5.4; "**fetch price**" = `(price, usable) = OracleAdapter.fetchPrice()`
  followed, where the oracle table (§7) says *required*, by `require(usable, PriceUnusable)`.

---

## 3. Parameters

Every parameter is an immutable constructor argument. **Every starting value below is a hypothesis**
(marked H), to be replaced by values derived in the experiments (P27–P31) and frozen in the
preregistration; values marked E are engineering limits, C are mathematical constants, D are derived
from an H value by the stated formula.

### 3.1 Table

| Parameter | Contract | Unit | Valid range | Start | Kind | Meaning |
|---|---|---|---|---|---|---|
| `MCR` | VaultManager | WAD | `WAD + LIQUIDATION_PENALTY < MCR ≤ 2·WAD` | `1.10e18` | H | Minimum collateral ratio. Blueprint §10.4: premium + gap buffer + slippage buffer + model margin |
| `MIN_DEBT` | VaultManager, DutchAuctionHouse | stable wei | `≥ 1e18` | `2_000e18` | H | Minimum debt of an active position; auction dust threshold |
| `GAS_RESERVE` | VaultManager | WETH wei | `> 0` | `0.0375e18` | H | WETH posted at opening, paid to whoever liquidates (A) or starts the auction (B), else returned |
| `ANNUAL_RATE` | (deployment script) | decimal | `[0, 1]` | `0.05` | H | Annual compounded interest rate |
| `RATE_PER_SECOND` | VaultManager | RAY | `[0, 21_979_553_151_239_153_028]` (= the derived value for `ANNUAL_RATE = 1`) | `1_547_125_957_863_212_449` | D | `round_half_even(((1 + ANNUAL_RATE)^(1/31_536_000) − 1) · RAY)` at ≥ 80 significant digits |
| `POOL_SHARE_BPS` | VaultManager | bps | `[0, 10_000]` | `7_500` (A), `0` (B) | H | Share of accrued interest minted to the pool (A); must be 0 in B |
| `MAX_HINT_STEPS` | SortedPositions | count | `[1, 1_000]` | `30` | E | Maximum nodes visited by a hint walk (§6.3) |
| `LIQUIDATION_PENALTY` | StabilityPool / DutchAuctionHouse | WAD | `[0, 0.5e18]` | `0.05e18` | H | A: cap on seized value is debt × (1 + penalty). B: tab = debt × (1 + penalty). Equal in A and B |
| `MIN_DEPOSIT` | StabilityPool | stable wei | `≥ 1e18` | `1e18` | H | Minimum non-zero deposit; minimum total deposits for the pool to receive interest |
| `REDEMPTION_FEE_FLOOR` | RedemptionModule | WAD | `[0, WAD]` | `0.005e18` | H | Fee floor |
| `BETA` | RedemptionModule | integer | `[1, 100]` | `2` | H | Base-rate sensitivity divisor |
| `BASE_RATE_HALF_LIFE` | (deployment script) | s | `> 0` | `43_200` | H | Half-life of the base rate |
| `BASE_RATE_DECAY` | RedemptionModule | RAY | `(0, RAY)` | `999_983_955_055_097_432_543_272_791` | D | `round_half_even(0.5^(1/BASE_RATE_HALF_LIFE) · RAY)` |
| `STALENESS` | OracleAdapter | s | `> 0` | `3_600` | H | Max age of a price answer (calibrated in P07) |
| `GRACE_PERIOD` | OracleAdapter | s | `≥ 0` | `3_600` | H | Sequencer-restart grace period (blueprint Q6) |
| `MIN_PRICE` | OracleAdapter | WAD | `≥ 2e18` | `10e18` | H | Sanity lower bound of a usable price. The floor of `2e18` keeps seized collateral below the debt it offsets (`c ≤ T`, §6.6.3) for any penalty ≤ 0.5 |
| `MAX_PRICE` | OracleAdapter | WAD | `> MIN_PRICE`, `≤ 1e30` | `1_000_000e18` | H | Sanity upper bound |
| `ORACLE_GAS` | OracleAdapter | gas | `[50_000, 1_000_000]` | `100_000` | E | Gas forwarded to each feed call |
| `ORACLE_POST_FAILURE_GAS` | OracleAdapter | gas | `≥ ceil(ORACLE_GAS / 63)` | `1_588` | D | Minimum `gasleft()` after a failed feed call (§6.10.3) |
| `FEED_DECIMALS` | OracleAdapter | integer | `≤ 18` | read from the feed (8) | — | Decimals of the price feed, read once at construction |
| `BUFFER` | DutchAuctionHouse | WAD | `[WAD, 2·WAD]` | `1.20e18` | H | Start price = oracle price × buffer (blueprint §8.7) |
| `AUCTION_HALF_LIFE` | (deployment script) | s | `> 0` | `600` | H | Time for the auction price to halve |
| `CUT` | DutchAuctionHouse | RAY | `(0, RAY)` | `998_845_421_738_030_152_760_841_918` | D | `round_half_even(0.5^(1/AUCTION_HALF_LIFE) · RAY)`; per-second decay |
| `TAIL` | DutchAuctionHouse | s | `> 0` | `7_200` | H | Age after which an auction needs a reset |
| `CUSP` | DutchAuctionHouse | WAD | `(0, WAD)` | `0.40e18` | H | Price/top ratio below which an auction needs a reset |
| `TIP` | DutchAuctionHouse | stable wei | `≥ 0` | `5e18` | H | Paid to the resetter from the reserve, if the reserve can afford it |
| `ORACLE_FAILURE_DURATION` | ShutdownModule | s | `> STALENESS` | `172_800` | H | Continuous observed oracle failure that triggers shutdown |
| `CRITICAL_TCR` | ShutdownModule | WAD | `[WAD, MCR]` | `1.05e18` | H | TCR below which shutdown triggers |
| `DEFICIT_LIMIT_BPS` | ShutdownModule | bps | `[1, 10_000]` | `500` | H | Uncovered deficit as a share of supply that triggers shutdown |
| `REPAYMENT_WINDOW` | ShutdownModule | s | `> 0` | `604_800` | H | Window between trigger and settlement |

Constants (C): `WAD`, `RAY`, `BPS`, `DECIMAL_PRECISION`, `P_PRECISION`, `SCALE_FACTOR`, `P_MIN`,
`SCALE_SPAN`, `NICR_PRECISION`, `SECONDS_PER_YEAR = 31_536_000`.

### 3.2 Derived values check

Through `rpow` (§2.3) the derived constants realise:

| Quantity | Exact target | Realised |
|---|---|---|
| `rpow(RAY + RATE_PER_SECOND, 31_536_000)` | 1.05 RAY | `1_050_000_000_000_000_000_011_578_354` |
| `rpow(BASE_RATE_DECAY, 43_200)` | 0.5 RAY | `500_000_000_000_000_000_000_001_699` |
| `rpow(CUT, 600)` | 0.5 RAY | `500_000_000_000_000_000_000_000_092` |

Vector `math.json#derived_constants` recomputes these.

### 3.3 Deployment constraints

The deployment script (P18) asserts, and the constructor of each contract checks the parts it can:

1. `WAD + LIQUIDATION_PENALTY < MCR` (a position liquidated just below MCR has a surplus).
2. `LIQUIDATION_PENALTY` and `MIN_DEBT` are identical across all contracts of one deployment and
   across deployments A and B of one comparison.
3. `POOL_SHARE_BPS = 0` in deployment B.
4. `ORACLE_POST_FAILURE_GAS ≥ ceil(ORACLE_GAS / 63)`; `FEED_DECIMALS ≤ 18`.
5. `CRITICAL_TCR ≤ MCR`; `ORACLE_FAILURE_DURATION > STALENESS`.
6. Every range in §3.1, as far as §3.4 assigns it to a constructor or `wire`.

Constraints 1, 2, 5 and the `≤ MCR` half of `CRITICAL_TCR` involve parameters of different
contracts and are enforced **only by the deployment script** (it asserts them before broadcasting).
Constraint 3 is enforced by `VaultManager.wire`. Constraint 4 by the OracleAdapter constructor.

### 3.4 Constructor and `wire` signatures

Rules. A constructor or `wire` checks its arguments **in argument order; the first failure wins** and
reverts `InvalidParameter(uint8 index)` with the 0-based index of that argument. A check involving two
arguments of the same call is made at the later argument. Address arguments must be non-zero unless
the table says otherwise. `wire` first checks `msg.sender == deployer` (`NotDeployer`) and
`!wired` (`AlreadyWired`), then its arguments.

| Contract | Signature (argument index: check) |
|---|---|
| VaultManager | `constructor(address weth, address token, address oracle, uint256 MCR, uint256 MIN_DEBT, uint256 GAS_RESERVE, uint256 RATE_PER_SECOND, uint256 POOL_SHARE_BPS)` — 3: `WAD < MCR ≤ 2·WAD`; 4: `≥ 1e18`; 5: `> 0`; 6: `≤ 21_979_553_151_239_153_028`; 7: `≤ 10_000` |
| | `wire(address sorted, address strategy, address stabilityPool, address redemptionModule, address deficitLedger, address shutdownModule)` — 2: `stabilityPool ∈ {address(0), strategy}`, and `stabilityPool == address(0) ⇒ POOL_SHARE_BPS == 0` |
| SortedPositions | `constructor(uint256 MAX_HINT_STEPS)` — 0: `1 ≤ x ≤ 1_000` · `wire(address vaultManager)` |
| StabilityPool | `constructor(address weth, address token, uint256 LIQUIDATION_PENALTY, uint256 MIN_DEPOSIT)` — 2: `≤ 0.5e18`; 3: `≥ 1e18` · `wire(address vaultManager, address deficitLedger)` |
| DutchAuctionHouse | `constructor(address weth, address token, address oracle, uint256 LIQUIDATION_PENALTY, uint256 MIN_DEBT, uint256 BUFFER, uint256 CUT, uint256 TAIL, uint256 CUSP, uint256 TIP)` — 3: `≤ 0.5e18`; 4: `≥ 1e18`; 5: `WAD ≤ x ≤ 2·WAD`; 6: `0 < x < RAY`; 7: `> 0`; 8: `0 < x < WAD`; 9: any · `wire(address vaultManager, address deficitLedger, address shutdownModule)` |
| RedemptionModule | `constructor(address token, address oracle, uint256 REDEMPTION_FEE_FLOOR, uint256 BETA, uint256 BASE_RATE_DECAY)` — 2: `≤ WAD`; 3: `1 ≤ x ≤ 100`; 4: `0 < x < RAY` · `wire(address vaultManager)` |
| DeficitLedger | `constructor(address weth, address token)` · `wire(address vaultManager, address strategy, address auctionHouse, address stabilityPool, address shutdownModule)` — 2: `auctionHouse ∈ {address(0), strategy}`; 3: `stabilityPool ∈ {address(0), strategy}` and exactly one of `auctionHouse`, `stabilityPool` is non-zero |
| OracleAdapter | `constructor(address priceFeed, address sequencerFeed, uint256 STALENESS, uint256 GRACE_PERIOD, uint256 MIN_PRICE, uint256 MAX_PRICE, uint256 ORACLE_GAS, uint256 ORACLE_POST_FAILURE_GAS)` — 2: `> 0`; 3: any; 4: `≥ 2e18`; 5: `MIN_PRICE < x ≤ 1e30`; 6: `50_000 ≤ x ≤ 1_000_000`; 7: `≥ ceil(ORACLE_GAS / 63)`. After the argument checks it reads `priceFeed.decimals()`; a failing call or a value `> 18` reverts `InvalidFeedDecimals()`. No `wire` |
| ShutdownModule | `constructor(address weth, address token, address oracle, uint256 ORACLE_FAILURE_DURATION, uint256 CRITICAL_TCR, uint256 DEFICIT_LIMIT_BPS, uint256 REPAYMENT_WINDOW)` — 3: `> 0`; 4: `≥ WAD`; 5: `1 ≤ x ≤ 10_000`; 6: `> 0` · `wire(address vaultManager, address deficitLedger, address auctionHouse)` — 2: may be `address(0)` (deployment A) |
| StableToken | `constructor(string name, string symbol)` · `wire(address vaultManager, address strategy, address deficitLedger, address shutdownModule)` — minter = vaultManager; burners = {vaultManager, strategy, deficitLedger, shutdownModule}; mover = strategy |

---

## 4. State

All fields are `uint256` unless typed otherwise. Packing into narrower types is an optimisation the
gas pass (P37) may only introduce together with an ADR stating the bounds; until then every field is
a full word.

### 4.1 Common to every core contract

Applies to every contract in §4.2–§4.10 **except OracleAdapter**, which has neither field (it is
configured entirely by its constructor and has no `wire`).

| Field | Type | Meaning |
|---|---|---|
| `deployer` | `address immutable` | `msg.sender` of the constructor; the only address allowed to call `wire` |
| `wired` | `bool` | set once by `wire`; every state-changing function except `wire` requires it |

### 4.2 VaultManager

| Field | Meaning |
|---|---|
| `positions[id]` | `{owner: address, coll, normDebt, stake, snapLColl, snapLDebt, status: Status}` |
| `Status` | enum `{None, Active, ClosedByOwner, ClosedByRedemption, ClosedByLiquidation, ClosedByShutdown}` |
| `nextId` | next position id; starts at 1 (0 is the null id of the sorted list) |
| `activeCount` | number of positions with status `Active` |
| `index` | interest index, RAY; starts at `RAY` |
| `lastAccrual` | timestamp of the last accrual; set to the construction timestamp |
| `totalNormDebt` | `Σ_active normDebt + pendingNormDebt` (exact) |
| `totalCollateral` | `Σ_active coll` (exact; stored values, excluding pending) |
| `totalStakes` | `Σ_active stake` (exact) |
| `totalStakesSnapshot`, `totalCollateralSnapshot` | stake-ratio snapshot (§6.5.4); start at 0 |
| `LColl`, `LDebt` | redistribution accumulators: WETH wei and normalised debt per unit stake, scaled by `DECIMAL_PRECISION` |
| `lastErrorColl`, `lastErrorDebt` | redistribution error carries (§6.5.2) |
| `pendingColl`, `pendingNormDebt` | redistributed collateral and normalised debt not yet applied to positions, including truncation dust |
| `shutdown` | `bool`; set when the shutdown triggers; freezes accrual |
| `settled` | `bool`; set at settlement |
| immutables | `WETH`, `token`, `oracle`, `MCR`, `MIN_DEBT`, `GAS_RESERVE`, `RATE_PER_SECOND`, `POOL_SHARE_BPS` |
| wired | `sorted`, `strategy`, `stabilityPool` (A: = strategy; B: `address(0)`), `redemptionModule`, `deficitLedger`, `shutdownModule` |

### 4.3 SortedPositions

| Field | Meaning |
|---|---|
| `nodes[id]` | `{exists: bool, prev: uint256, next: uint256}`; `prev` points towards the head (higher NICR) |
| `head`, `tail`, `size` | head = highest NICR, tail = lowest; 0 when empty |
| immutables | `MAX_HINT_STEPS` |
| wired | `vaultManager` (the only caller of mutating functions; source of sort keys) |

### 4.4 StabilityPool (A)

| Field | Meaning |
|---|---|
| `totalDeposits` | `T`: stablecoin backing deposits, `≥ Σ compounded deposits` |
| `P` | product, `P_MIN ≤ P ≤ P_PRECISION`; starts at `P_PRECISION` |
| `currentScale`, `currentEpoch` | start at 0 |
| `epochToScaleToS[e][s]` | cumulative collateral gain per unit deposit × `P`, scaled by `DECIMAL_PRECISION` |
| `epochToScaleToG[e][s]` | same for interest (stablecoin) gains |
| `lastCollError`, `lastInterestError` | error carries of the per-unit gains |
| `collGainsBalance` | WETH received from offsets minus WETH paid to depositors |
| `interestGainsBalance` | stablecoin interest received minus interest paid to depositors |
| `deposits[a]` | `{initial, snapP, snapS, snapG, snapEpoch, snapScale}`; `initial == 0` means no deposit |
| `depositorCount[e]` | number of depositors whose record has `initial > 0` and `snapEpoch == e` |
| immutables | `WETH`, `token`, `LIQUIDATION_PENALTY`, `MIN_DEPOSIT` |
| wired | `vaultManager`, `deficitLedger` |

### 4.5 DutchAuctionHouse (B)

| Field | Meaning |
|---|---|
| `auctions[aid]` | `{positionId, owner: address, debtRemaining, tab, lot, top, tic, active: bool}` |
| `nextAuctionId` | starts at 1 |
| `activeAuctions` | number of active auctions |
| `totalLot` | `Σ_active lot` (exact) before settlement; 0 after |
| `settled` | `bool` |
| `inPurchase` | transient `bool`; true only while a buyer callback runs (§6.8.4) |
| immutables | `WETH`, `token`, `oracle`, `LIQUIDATION_PENALTY`, `MIN_DEBT`, `BUFFER`, `CUT`, `TAIL`, `CUSP`, `TIP` |
| wired | `vaultManager`, `deficitLedger`, `shutdownModule` |

Invariant of every active auction: `tab ≥ debtRemaining`, `tab ≥ MIN_DEBT`, `lot > 0`.

### 4.6 RedemptionModule

| Field | Meaning |
|---|---|
| `baseRate` | WAD, `≤ WAD`; starts at 0 |
| `lastFeeOperationTime` | starts at the construction timestamp |
| immutables | `token`, `oracle`, `REDEMPTION_FEE_FLOOR`, `BETA`, `BASE_RATE_DECAY` |
| wired | `vaultManager` |

### 4.7 DeficitLedger

| Field | Meaning |
|---|---|
| `reserve` | stablecoin held by the ledger (interest share, B penalties, swept pool dust) |
| `auctionDebt` | `A`: debt that left positions into active auctions (exact `Σ_active debtRemaining`) |
| `deficit` | `F`: stablecoin in circulation backed by no position or auction |
| `recoveredColl` | WETH held after a liquidation remainder could not be redistributed (§6.4.4) |
| `settled` | `bool` |
| immutables | `WETH`, `token` |
| wired | `vaultManager`, `strategy`, `auctionHouse` (B; `address(0)` in A), `stabilityPool` (A; `address(0)` in B), `shutdownModule` |

### 4.8 OracleAdapter

| Field | Meaning |
|---|---|
| `lastGoodPrice` | WAD; last usable price; 0 until the first usable read. Never used in any state-changing decision — informational and for views |
| `failureStart` | timestamp of the first observed unusable read since the last usable one; 0 when the last read was usable |
| immutables | `priceFeed`, `sequencerFeed`, `FEED_DECIMALS`, `STALENESS`, `GRACE_PERIOD`, `MIN_PRICE`, `MAX_PRICE`, `ORACLE_GAS`, `ORACLE_POST_FAILURE_GAS` |

### 4.9 ShutdownModule

| Field | Meaning |
|---|---|
| `triggered`, `triggerTime`, `reason` | `reason ∈ {NONE, ORACLE, TCR, DEFICIT}` |
| `settled` | `bool` |
| `claimColl` | WETH transferred to the module at settlement (snapshot, never changes afterwards) |
| `claimSupply` | `token.totalSupply()` at settlement after the reserve burn (snapshot) |
| `claimedColl` | WETH paid out by claims |
| immutables | `WETH`, `token`, `oracle`, `ORACLE_FAILURE_DURATION`, `CRITICAL_TCR`, `DEFICIT_LIMIT_BPS`, `REPAYMENT_WINDOW` |
| wired | `vaultManager`, `deficitLedger`, `auctionHouse` (B; `address(0)` in A) |

### 4.10 StableToken

OZ ERC-20 (`name`, `symbol` constructor arguments; test deployments carry `TEST` in both), plus:

| Field | Meaning |
|---|---|
| wired | `vaultManager`, `strategy`, `deficitLedger`, `shutdownModule` (§3.4); derived roles: minter = vaultManager; burners = {vaultManager, strategy, deficitLedger, shutdownModule}; mover = strategy (StabilityPool in A, DutchAuctionHouse in B) |

---

## 5. Operations

Each operation lists, in normative order: guards, price, accrual, checks, effects, token movements,
events. "Mode" restrictions use the VaultManager flags: **normal** (`!shutdown`), **window**
(`shutdown && !settled`), **settled**.

### 5.1 VaultManager — positions

#### 5.1.1 `openPosition(uint256 coll, uint256 debt, uint256 upperHint, uint256 lowerHint) returns (uint256 id)`

Caller: anyone (becomes owner). Mode: normal. Oracle: required.

```
require(wired, NotWired)
require(!shutdown, SystemShutdown)
require(debt >= MIN_DEBT, DebtBelowMinimum)
require(coll <= 2^128 − 1, CollateralTooLarge)
fetch price (required)
accrue
n = mulDivUp(debt, RAY, index)
require(coll * price >= MCR * debtOf(n), IcrBelowMcr)
id = nextId; nextId += 1
stake = computeStake(coll)                                   // §6.5.4
positions[id] = {msg.sender, coll, n, stake, LColl, LDebt, Active}
totalStakes += stake; totalCollateral += coll; totalNormDebt += n; activeCount += 1
sorted.insert(id, upperHint, lowerHint)                      // may revert StaleHint
WETH.safeTransferFrom(msg.sender, this, coll + GAS_RESERVE)
token.mint(msg.sender, debt)                                 // may revert SupplyCapExceeded
emit PositionOpened(id, msg.sender, debt)
emit PositionUpdated(id, OP_OPEN)
```

#### 5.1.2 `addCollateral(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)`

Caller: anyone (for any position). Mode: normal or window. Oracle: not used.

```
require(wired, NotWired)
require(!settled, SystemSettled)
require(amount > 0, ZeroAmount)
require(positions[id].status == Active, PositionNotActive)
accrue
apply pending (id)
require(p.coll + amount <= 2^128 − 1, CollateralTooLarge)
p.coll += amount; totalCollateral += amount
update stake (id)
sorted.reinsert(id, upperHint, lowerHint)
WETH.safeTransferFrom(msg.sender, this, amount)
emit CollateralAdded(id, msg.sender, amount)
emit PositionUpdated(id, OP_ADD_COLLATERAL)
```

#### 5.1.3 `withdrawCollateral(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)`

Caller: owner. Mode: normal. Oracle: required.

```
require(wired, NotWired)
require(!shutdown, SystemShutdown)
require(amount > 0, ZeroAmount)
require(p.status == Active, PositionNotActive)
require(msg.sender == p.owner, NotOwner)
fetch price (required)
accrue
apply pending (id)
require(amount <= p.coll, InsufficientCollateral)
require((p.coll − amount) * price >= MCR * debtOf(p.normDebt), IcrBelowMcr)
p.coll −= amount; totalCollateral −= amount
update stake (id)
sorted.reinsert(id, upperHint, lowerHint)
WETH.safeTransfer(p.owner, amount)
emit CollateralWithdrawn(id, amount)
emit PositionUpdated(id, OP_WITHDRAW_COLLATERAL)
```

#### 5.1.4 `borrow(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)`

Caller: owner. Mode: normal. Oracle: required.

```
require(wired, NotWired)
require(!shutdown, SystemShutdown)
require(amount > 0, ZeroAmount)
require(p.status == Active, PositionNotActive)
require(msg.sender == p.owner, NotOwner)
fetch price (required)
accrue
apply pending (id)
dn = mulDivUp(amount, RAY, index)
require(p.coll * price >= MCR * debtOf(p.normDebt + dn), IcrBelowMcr)
p.normDebt += dn; totalNormDebt += dn
update stake (id)
sorted.reinsert(id, upperHint, lowerHint)
token.mint(p.owner, amount)
emit Borrowed(id, amount, dn)
emit PositionUpdated(id, OP_BORROW)
```

#### 5.1.5 `repay(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)`

Caller: anyone (pays from own balance, for any position). Mode: normal or window. Oracle: not used.

```
require(wired, NotWired)
require(!settled, SystemSettled)
require(amount > 0, ZeroAmount)
require(p.status == Active, PositionNotActive)
accrue
apply pending (id)
require(amount <= debtOf(p.normDebt) − MIN_DEBT, RepayExceedsMaximum)   // full repayment: close()
                                             // no underflow: an active position's debt is ≥ MIN_DEBT
require(token.balanceOf(msg.sender) >= amount, InsufficientBalance)
dn = mulDivDown(amount, RAY, index)          // may be 0 for amount < index/RAY: rounding favours protocol
p.normDebt −= dn; totalNormDebt −= dn
update stake (id)
sorted.reinsert(id, upperHint, lowerHint)
token.burnFrom(msg.sender, amount)
emit Repaid(id, msg.sender, amount, dn)
emit PositionUpdated(id, OP_REPAY)
```

`amount ≤ debt − MIN_DEBT` guarantees `dn < p.normDebt` and `debtOf(p.normDebt − dn) ≥ MIN_DEBT`
(proof: `debtOf(n − floor(a/x)) ≥ ceil(n·x − a) = debt − a`, with `x = index/RAY`).

#### 5.1.6 `close(uint256 id)`

Caller: owner. Mode: normal or window. Oracle: not used. Closing at any ICR is allowed: repaying the
whole debt never harms the system.

```
require(wired, NotWired)
require(!settled, SystemSettled)
require(p.status == Active, PositionNotActive)
require(msg.sender == p.owner, NotOwner)
accrue
apply pending (id)
debt = debtOf(p.normDebt)
require(token.balanceOf(msg.sender) >= debt, InsufficientBalance)
sorted.remove(id)
totalStakes −= p.stake; totalCollateral −= p.coll; totalNormDebt −= p.normDebt; activeCount −= 1
coll = p.coll
p.coll = p.normDebt = p.stake = 0; p.status = ClosedByOwner
token.burnFrom(msg.sender, debt)
WETH.safeTransfer(msg.sender, coll + GAS_RESERVE)
emit PositionClosed(id, debt, coll, GAS_RESERVE)
emit PositionUpdated(id, OP_CLOSE)
```

#### 5.1.7 `liquidate(uint256 id)`

Caller: anyone. Mode: normal. Oracle: required. Full algorithm in §6.4.

#### 5.1.8 `accrue()`

Caller: anyone. Mode: any (no-op once `shutdown`). Oracle: not used. Algorithm §6.2. Requires
`wired`.

#### 5.1.9 `redeemCollateral(address redeemer, uint256 amount, uint256 feeRate, uint256 price, uint256 maxIterations, uint256 upperHint, uint256 lowerHint) returns (uint256 redeemed, uint256 collSent, uint256 iterations)`

Caller: RedemptionModule only (`Unauthorized`). Algorithm §6.7.3.

#### 5.1.10 `reclaimGasReserve(uint256 id)`

Caller: owner. Mode: settled. Returns the gas reserve of a position that was still active at
settlement.

```
require(wired, NotWired)
require(settled, NotSettled)
require(p.status == Active, PositionNotActive)
require(msg.sender == p.owner, NotOwner)
p.status = ClosedByShutdown; activeCount −= 1
WETH.safeTransfer(p.owner, GAS_RESERVE)
emit GasReserveReclaimed(id, p.owner, GAS_RESERVE)
emit PositionUpdated(id, OP_CLOSE)
```

#### 5.1.11 Hooks called by other core contracts

| Function | Caller | Effect |
|---|---|---|
| `onShutdown()` | ShutdownModule | `require(!shutdown, SystemShutdown)`; `shutdown = true`; `emit VaultShutdown(index)`. The caller has accrued immediately before |
| `onSettlement() returns (uint256 coll)` | ShutdownModule | `require(shutdown, NotTriggered)`; `require(!settled, AlreadySettled)`; `coll = totalCollateral + pendingColl`; `totalCollateral = 0; pendingColl = 0; settled = true`; transfer `coll` WETH to the ShutdownModule; `emit VaultSettled(coll, activeCount)`. Positions keep their stored fields but are void; only `reclaimGasReserve` remains |

Both hooks first check `wired` and the caller (`Unauthorized`), as every restricted function does.

#### 5.1.12 Views

`currentIndex()` (index accrued to `block.timestamp` without writing, frozen after shutdown),
`debtOf(id)` (= `mulDivUp(effNorm, currentIndex(), RAY)`), `effective(id) returns (effColl, effNorm)`,
`sortKey(id) returns (effColl, effNorm)` (the key used by SortedPositions; uses stored `index`, which
does not affect order), `icr(id, price)` (`mulDivDown(effColl, price, debtOf(id))`, `type(uint256).max`
if debt is 0), `nicr(id)` (`mulDivDown(effColl, NICR_PRECISION, effNorm)`), `systemColl()`,
`systemDebt()`, `tcr(price)`, `isLiquidatable(id, price)`. Formulas: `systemColl() =
totalCollateral + pendingColl + deficitLedger.recoveredColl() + (B ? house.totalLot() : 0)`;
`systemDebt() = mulDivUp(totalNormDebt, currentIndex(), RAY) + auctionDebt + deficit`;
`tcr(price) = systemDebt() == 0 ? type(uint256).max : mulDivDown(systemColl(), price, systemDebt())`;
`isLiquidatable(id, price) = status == Active and effColl · price < MCR · debtOf(id)`;
`currentIndex() = shutdown ? index : mulDivUp(index, rpow(RAY + RATE_PER_SECOND, now − lastAccrual), RAY)`.
Views use `currentIndex()`; state-changing operations use the stored `index` after accruing.

### 5.2 SortedPositions

All mutating functions: caller VaultManager only (`Unauthorized`). Algorithms in §6.3.

| Function | Effect | Errors |
|---|---|---|
| `insert(id, upperHint, lowerHint)` | link `id` at the position found by `findInsertPosition`; `emit NodeInserted(id, prev, next)` | `NodeExists`, `StaleHint` |
| `remove(id)` | unlink `id`; `emit NodeRemoved(id)` | `NodeNotFound` |
| `reinsert(id, upperHint, lowerHint)` | `remove(id)` then `insert` with the key read after the caller's state change (emits `NodeRemoved` then `NodeInserted`) | `NodeNotFound`, `StaleHint` |
| `find(keyColl, keyNorm, id, excludeId, upperHint, lowerHint) view returns (bool found, uint256 prev, uint256 next)` | non-reverting probe on the list with `excludeId` treated as absent (0 = none) | — |
| `contains(id)`, `getFirst()`, `getLast()`, `getNext(id)`, `getPrev(id)`, `getSize()` | views | — |

### 5.3 StabilityPool (A)

#### 5.3.1 `deposit(uint256 amount)`

Caller: anyone, for themselves. Mode: any. Oracle: not used.

Two helpers used by all three depositor functions:

```
function leave(a, inCurrentEpoch) returns (swept):     // record becomes empty
    delete deposits[a]
    swept = 0
    if inCurrentEpoch:
        depositorCount[currentEpoch] −= 1
        if depositorCount[currentEpoch] == 0 and totalDeposits > 0 and not deficitLedger.settled():
            swept = totalDeposits; totalDeposits = 0
            token.transfer(deficitLedger, swept); deficitLedger.onPoolDust(swept)

function emitDeposit(a):                               // after the record was written or deleted
    r = deposits[a]
    if r.initial == 0: emit DepositUpdated(a, 0, P, currentEpoch, currentScale, 0, 0)
    else:              emit DepositUpdated(a, r.initial, r.snapP, r.snapEpoch, r.snapScale, r.snapS, r.snapG)
```

After the DeficitLedger has settled, the sweep is skipped: the residual stays in `totalDeposits`
(the ledger accepts nothing after settlement). Residual dust is then inert — no interest reaches the
pool after shutdown (accrual is frozen) and no offset can happen (liquidations are frozen).

```
require(wired, NotWired)
require(amount > 0, ZeroAmount)
vaultManager.accrue()                       // may call back onInterest (§5.10)
rec = deposits[msg.sender]
inCurrentEpoch = rec.initial > 0 and rec.snapEpoch == currentEpoch
(collGain, interestGain) = gains(msg.sender)        // §6.6.7
compounded = compoundedDeposit(msg.sender)          // §6.6.6
newDeposit = compounded + amount
require(newDeposit >= MIN_DEPOSIT, DepositTooSmall)
require(token.balanceOf(msg.sender) >= amount, InsufficientBalance)
pay gains (§6.6.8)
totalDeposits += amount
deposits[msg.sender] = snapshot(newDeposit)          // §6.6.8
if not inCurrentEpoch: depositorCount[currentEpoch] += 1
token.moveFrom(msg.sender, this, amount)
emitDeposit(msg.sender)
emit GainsPaid(msg.sender, collGain, interestGain)
```

#### 5.3.2 `withdraw(uint256 amount)`

Caller: anyone, for themselves. Mode: any. Oracle: not used. `amount = type(uint256).max` withdraws
everything.

```
require(wired, NotWired)
require(amount > 0, ZeroAmount)
vaultManager.accrue()
rec = deposits[msg.sender]
require(rec.initial > 0, NoDeposit)
inCurrentEpoch = rec.snapEpoch == currentEpoch
(collGain, interestGain) = gains(msg.sender)
compounded = compoundedDeposit(msg.sender)
w = min(amount, compounded)
newDeposit = compounded − w
require(newDeposit == 0 or newDeposit >= MIN_DEPOSIT, DepositTooSmall)
pay gains
totalDeposits −= w
swept = 0
if newDeposit == 0: swept = leave(msg.sender, inCurrentEpoch)
else:               deposits[msg.sender] = snapshot(newDeposit)
token.transfer(msg.sender, w)
emitDeposit(msg.sender)
emit GainsPaid(msg.sender, collGain, interestGain)
if swept > 0: emit PoolDustSwept(swept)
```

The sweep keeps "no depositor in the current epoch ⇒ `totalDeposits == 0`" exact, so collateral and
interest never flow to a pool nobody can claim from.

#### 5.3.3 `claimGains()`

Caller: anyone, for themselves. Mode: any. Pays gains and re-snapshots the compounded deposit without
changing it; the `MIN_DEPOSIT` rule is not applied.

```
require(wired, NotWired)
vaultManager.accrue()
rec = deposits[msg.sender]
require(rec.initial > 0, NoDeposit)
inCurrentEpoch = rec.snapEpoch == currentEpoch
(collGain, interestGain) = gains(msg.sender)
compounded = compoundedDeposit(msg.sender)
pay gains
swept = 0
if compounded == 0: swept = leave(msg.sender, inCurrentEpoch)
else:               deposits[msg.sender] = snapshot(compounded)
emitDeposit(msg.sender)
emit GainsPaid(msg.sender, collGain, interestGain)
if swept > 0: emit PoolDustSwept(swept)
```

#### 5.3.4 Strategy and interest hooks

| Function | Caller | Algorithm |
|---|---|---|
| `onLiquidation(positionId, owner, debt, coll, price) returns (debtAbsorbed, collReturned)` | VaultManager | §6.6.4 |
| `onInterest(amount)` | VaultManager | §6.6.5 |
| `acceptsInterest() view returns (bool)` | anyone | `totalDeposits >= MIN_DEPOSIT` |

Views: `compoundedDeposit(a)`, `gains(a)`, `getTotalDeposits()`.

### 5.4 DutchAuctionHouse (B)

| Function | Caller | Mode | Oracle | Algorithm |
|---|---|---|---|---|
| `onLiquidation(positionId, owner, debt, coll, price) returns (debtAbsorbed, collReturned)` | VaultManager | normal | (VM fetched) | §6.8.2 |
| `buy(aid, maxColl, maxPrice, who, data)` | anyone | not settled | not used | §6.8.4 |
| `reset(aid)` | anyone | not settled | required | §6.8.5 |
| `onSettlement() returns (uint256 lot)` | ShutdownModule | window → settled | — | §6.11.3 |
| `price(aid) view`, `needsReset(aid) view`, `getAuction(aid) view`, `inPurchase() view`, `activeAuctions() view`, `totalLot() view`, `settled() view` | anyone | — | — | §6.8.3 |

`price(aid)` and `needsReset(aid)` on an inactive auction return the formula's value for the stored
record; they are views and decide nothing.

### 5.5 RedemptionModule

`redeem(uint256 amount, uint256 maxIterations, uint256 maxFeeRate, uint256 upperHint, uint256 lowerHint)`
— caller anyone (redeems own stablecoin); mode normal; oracle required. Algorithm §6.7.2. Views:
`decayedBaseRate()`, `redemptionFeeRate(amount) = min(REDEMPTION_FEE_FLOOR +
min(decayedBaseRate() + increment(amount, token.totalSupply()), WAD), WAD)` — uses the current
supply without accruing, so it can differ from the rate a `redeem` in the same block charges by the
interest minted at that `redeem`'s accrual.

### 5.6 DeficitLedger

| Function | Caller | Effect |
|---|---|---|
| `onInterest(amount)` | VaultManager | `reserve += amount` (VM minted `amount` to the ledger); `emit ReserveIncreased(amount, INTEREST)` |
| `onPoolDust(amount)` | StabilityPool | `reserve += amount` (pool transferred it); `emit ReserveIncreased(amount, POOL_DUST)` |
| `addAuctionDebt(d)` | DutchAuctionHouse | `auctionDebt += d`; `emit AuctionDebtChanged(+d, auctionDebt)` |
| `onAuctionPayment(burned, toReserve)` | DutchAuctionHouse | `auctionDebt −= burned; reserve += toReserve` (house burned / moved the tokens); `emit AuctionDebtChanged(−burned, auctionDebt)`; if `toReserve > 0`: `emit ReserveIncreased(toReserve, AUCTION_PENALTY)` |
| `onAuctionShortfall(d)` | DutchAuctionHouse | `auctionDebt −= d; deficit += d`; `emit AuctionDebtChanged(−d, auctionDebt)`; `emit DeficitRecorded(d, 0, SOURCE_AUCTION)` |
| `recordDeficit(d, coll)` | VaultManager | `deficit += d; recoveredColl += coll` (VM transferred `coll` WETH first); `emit DeficitRecorded(d, coll, SOURCE_NO_STAKES)` |
| `payTip(to, amount)` | DutchAuctionHouse | `reserve −= amount`; transfer `amount` stablecoin to `to`; `emit ReserveDecreased(amount, TIP)`. Caller guarantees `amount ≤ reserve` |
| `cover() returns (uint256 c)` | anyone, mode any before settlement | §6.9.2 |
| `onSettlement() returns (uint256 coll)` | ShutdownModule | §6.11.3 |

Every hook above except `cover` and `onSettlement` starts, in this order:
`require(wired, NotWired)`, the caller check (`Unauthorized`), `require(!settled, SystemSettled)`,
then the listed effect. Through the core these `SystemSettled` reverts are unreachable (each caller
is itself blocked after settlement, or skips the call — §5.3 `leave`), so they are defence in depth.
`cover` has its own pseudocode (§6.9.2); `onSettlement` reverts `AlreadySettled` instead.

### 5.7 OracleAdapter

`fetchPrice() returns (uint256 price, bool usable)` — callable by anyone; state-changing (updates
`lastGoodPrice`, `failureStart`). Algorithm §6.10. View: `peek() returns (price, usable, reason)`
(same decision without writing state and without the gas check; `price = lastGoodPrice` when not
usable, exactly like `fetchPrice`). The decision table itself (§6.10.1) produces a price only when
usable; `oracle.json` encodes "no price" as `"0"`. The adapter has no `wire` and no
other state-changing function.

### 5.8 ShutdownModule

| Function | Caller | Algorithm |
|---|---|---|
| `check() returns (bool triggeredNow)` | anyone | §6.11.1 — never reverts when no condition holds |
| `settle()` | anyone | §6.11.3 |
| `claim(uint256 amount) returns (uint256 collOut)` | anyone, own stablecoin | §6.11.4 |

### 5.9 StableToken

| Function | Caller | Effect / errors |
|---|---|---|
| ERC-20 standard (`transfer`, `approve`, `transferFrom`, views) | anyone | OZ ERC-20 v5 (errors `ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, …); **do not** require `wired` |
| `mint(to, amount)` | minter | `require(wired, NotWired)`; `require(totalSupply + amount ≤ 2^128 − 1, SupplyCapExceeded)`; mint |
| `burnFrom(account, amount)` | burners | `require(wired, NotWired)`; burn without allowance; OZ balance error if insufficient |
| `moveFrom(account, to, amount)` | mover | `require(wired, NotWired)`; transfer without allowance; OZ balance error if insufficient |
| `wire(vaultManager, strategy, deficitLedger, shutdownModule)` | deployer, once | §3.4, §9 |

The supply cap (`2^128 − 1 ≈ 3.4·10^38` wei) is ~10^11 times any realistic supply; if it were ever
reached, `accrue` would revert and with it every operation that accrues — accepted as unreachable.

### 5.10 Cross-contract call graph and reentrancy

Every contract holding or moving tokens uses one transient lock over its state-changing external
functions, **except** the callbacks marked lock-free below, which are restricted to one caller,
make no external call that can reach back, and are only reached at a point where the callee's state
is consistent:

| Path | Notes |
|---|---|
| `StabilityPool.deposit/withdraw/claimGains → VaultManager.accrue → StabilityPool.onInterest` | `onInterest` is lock-free (onlyVault). It runs before the pool reads any deposit state in the outer call |
| `VaultManager.* → VaultManager.accrue → StabilityPool.onInterest / DeficitLedger.onInterest` | |
| `VaultManager.liquidate → strategy.onLiquidation` | A: pool locked normally (not lock-free); B: house locked |
| `DutchAuctionHouse.buy → who.onAuctionPurchase(...)` | arbitrary external call (§6.8.4); the house lock is held, so the callback cannot re-enter the house, and therefore cannot complete a liquidation in deployment B |
| `RedemptionModule.redeem → OracleAdapter.fetchPrice, VaultManager.accrue, VaultManager.redeemCollateral` | |
| `VaultManager.* → SortedPositions.insert/remove/reinsert/find → VaultManager.sortKey` | `sortKey` is a `view`, so it is callable while the VaultManager lock is held |
| `VaultManager.liquidate → DeficitLedger.recordDeficit` | A, no-stakes path |
| `DutchAuctionHouse.onLiquidation/buy/reset → DeficitLedger.addAuctionDebt/onAuctionPayment/onAuctionShortfall/payTip`; `reset → OracleAdapter.fetchPrice` | ledger hooks are restricted to the house and make only token transfers to non-core recipients (`payTip` to the resetter) |
| `StabilityPool.withdraw/claimGains → DeficitLedger.onPoolDust` | |
| `ShutdownModule.check → VaultManager.accrue, DeficitLedger.cover, OracleAdapter.fetchPrice` + views | |
| `ShutdownModule.settle → VaultManager.onSettlement, DutchAuctionHouse.onSettlement, DeficitLedger.onSettlement` | |
| Every core contract `→ OracleAdapter.fetchPrice` | the adapter holds no lock and calls only the two feeds |

Events are emitted in the order the pseudocode lists them; events of a callee (e.g.
`NodeInserted` from SortedPositions, `PoolOffset` from the pool, ledger events) appear at the point
of the call, i.e. before the caller's own events that are listed after the call.

OracleAdapter calls to the feeds are `staticcall`s with a gas cap.

---

## 6. Algorithms

### 6.1 Arithmetic helpers

§2.2 and §2.3. Vectors: `math.json`.

### 6.2 Interest accrual

```
function accrue():
    if shutdown: return                                   // index frozen at the trigger
    dt = block.timestamp − lastAccrual
    if dt == 0: return
    newIndex = mulDivUp(index, rpow(RAY + RATE_PER_SECOND, dt), RAY)
    interest = mulDivUp(totalNormDebt, newIndex − index, RAY)
    index = newIndex; lastAccrual = block.timestamp
    toPool = 0
    if stabilityPool != address(0) and stabilityPool.acceptsInterest():
        toPool = mulDivDown(interest, POOL_SHARE_BPS, BPS)
    toReserve = interest − toPool
    if toPool > 0:    token.mint(stabilityPool, toPool);   stabilityPool.onInterest(toPool)
    if toReserve > 0: token.mint(deficitLedger, toReserve); deficitLedger.onInterest(toReserve)
    emit InterestAccrued(newIndex, interest, toPool, toReserve, block.timestamp)
```

Notes. The index grows even when `totalNormDebt == 0` (then `interest = 0`). Positions' debts are
never written by accrual: `debtOf(n)` reads the index. Debt in auctions and the deficit do not accrue
interest. Vectors: `interest.json`.

### 6.3 Sorted list

#### 6.3.1 Order

The list is ordered by effective NICR, **descending** from head to tail, with ties broken by **lower
id first**. For keys `kA = (cA, nA, idA)`, `kB = (cB, nB, idB)` (effective collateral, effective
normalised debt, id):

```
precedes(kA, kB) =   cA·nB > cB·nA
                  or (cA·nB == cB·nA and idA < idB)
```

`precedes` is a strict total order on distinct ids. Keys of list members are read from
`VaultManager.sortKey(id)` at the moment of comparison (they include pending redistribution).
Products fit in 256 bits: user operations cap a position's stored collateral at `2^128 − 1`
(`CollateralTooLarge`), redistribution can only add collateral the VaultManager holds, and WETH's
total supply is far below `2^128` (assumption, true for WETH9 on Base); effective normalised debt is
bounded by the supply cap (§2.2). Redemption walks from the tail (lowest NICR
first; among equals, highest id first).

#### 6.3.2 Finding the insert position

`newKey` is the key of the node being placed; the node itself is not in the list when this runs
(for `reinsert` it was removed first; for the redemption probe it is excluded, §6.7.3). **Every**
list quantity in the algorithm — `head`, `tail`, `size`, `contains(x)`, `next(x)`, `prev(x)` — is
evaluated on the list with the excluded node removed, exactly as if it had been unlinked: e.g. when
the excluded node is the only node, `size == 0` and the result is `(0, 0)`; when it is the head, the
walk starts at its successor. A hint equal to the excluded id is not contained and is discarded.
`key(x)` is only ever evaluated for nodes in that reduced list. Each loop iteration that reads one
more node counts as one step.

```
function findInsertPosition(newKey, upper, lower):
    if upper != 0 and (not contains(upper) or not precedes(key(upper), newKey)): upper = 0
    if lower != 0 and (not contains(lower) or not precedes(newKey, key(lower))): lower = 0
    if upper != 0 and lower != 0 and next(upper) == lower: return (upper, lower)
    if upper != 0: return walkDown(newKey, upper)
    if lower != 0: return walkUp(newKey, lower)
    if size == 0: return (0, 0)
    if precedes(newKey, key(head)): return (0, head)
    return walkDown(newKey, head)

function walkDown(newKey, start):          // precondition: precedes(key(start), newKey)
    cur = start
    repeat MAX_HINT_STEPS times:
        nxt = next(cur)
        if nxt == 0 or precedes(newKey, key(nxt)): return (cur, nxt)
        cur = nxt
    revert StaleHint()

function walkUp(newKey, start):            // precondition: precedes(newKey, key(start))
    cur = start
    repeat MAX_HINT_STEPS times:
        prv = prev(cur)
        if prv == 0 or precedes(key(prv), newKey): return (prv, cur)
        cur = prv
    revert StaleHint()
```

`find(...)` (§5.2) runs the same algorithm and returns `found = false` instead of reverting. Callers
compute hints off-chain; with no usable hint the walk starts at the head, so positions far from the
head need hints. Vectors: `sorted_list.json`.

#### 6.3.3 Order stability under redistribution

Insertion places a node exactly. Redistribution (§6.5) changes effective keys lazily. In exact
(real-valued) arithmetic it preserves the order: if every active position has the same ratio
`stake/effColl = ρ`, the post-reward NICR is a strictly increasing function of the pre-reward NICR,
and the snapshot rule keeps a common ratio by induction (a liquidation's snapshot is
`Σ stake / Σ effColl = ρ'`, the common post-reward ratio, and every restake uses it). With integer
arithmetic stakes and rewards are rounded down, so the ratios differ slightly between positions —
in particular for positions staked before the last snapshot — and the property holds only
approximately; two positions with almost equal NICR can swap.
Measured on the reference implementation: no violation in random sequences; under adversarial
near-ties, inversions of relative size up to `7.1·10^-19`, about `1 / min(effColl)` in wei. This
does not affect determinism (insertion and hint validation are exact) nor safety (redemption checks
each position's ICR individually, liquidation is by id). **Input to P03:** I13 must be stated with
a derived relative tolerance, not as exact order.

### 6.4 Liquidation (VaultManager side)

#### 6.4.1 Entry

```
function liquidate(id):
    require(wired, NotWired)
    require(!shutdown, SystemShutdown)
    require(p.status == Active, PositionNotActive)
    fetch price (required)
    accrue
    apply pending (id)
    debt = debtOf(p.normDebt)
    require(p.coll * price < MCR * debt, NotLiquidatable)
    sorted.remove(id)
    totalStakes −= p.stake; totalCollateral −= p.coll; activeCount −= 1
    (n, coll, owner) = (p.normDebt, p.coll, p.owner)
    p.coll = p.normDebt = p.stake = 0; p.status = ClosedByLiquidation
    WETH.safeTransfer(msg.sender, GAS_RESERVE)                       // gas compensation
    WETH.safeTransfer(strategy, coll)
    (debtAbsorbed, collReturned) = strategy.onLiquidation(id, owner, debt, coll, price)
    normAbsorbed = (debtAbsorbed == debt) ? n : mulDivDown(debtAbsorbed, RAY, index)
    normRest = n − normAbsorbed
    totalNormDebt −= normAbsorbed
    path = NONE
    if collReturned > 0 or normRest > 0:
        if totalStakes > 0:
            redistribute(collReturned, normRest)                        // §6.5.2
            path = REDISTRIBUTED
        else:
            debtRest = debtOf(normRest)
            totalNormDebt −= normRest
            WETH.safeTransfer(deficitLedger, collReturned)
            deficitLedger.recordDeficit(debtRest, collReturned)
            path = DEFICIT
    updateSystemSnapshots()                                             // §6.5.4
    emit Liquidated(id, owner, msg.sender, debt, coll, debtAbsorbed, collReturned, normRest, path, GAS_RESERVE)
    emit PositionUpdated(id, OP_LIQUIDATE)
```

The strategy receives `coll` before the call and transfers `collReturned` back to the VaultManager
before returning. `collReturned ≤ coll` and `debtAbsorbed ≤ debt` always (strategy contract).

#### 6.4.2 Deployment A — what `onLiquidation` does

§6.6.4: seize `min(coll, mulDivUp(debt, WAD + LIQUIDATION_PENALTY, price))`, push the surplus to the
owner, offset `min(debt, totalDeposits)` against deposits with the proportional seized collateral,
return the unabsorbed seized collateral. The VaultManager redistributes the unabsorbed remainder.

#### 6.4.3 Deployment B — what `onLiquidation` does

§6.8.2: start an auction for the whole collateral; `debtAbsorbed = debt`, `collReturned = 0`; the
debt moves to `DeficitLedger.auctionDebt`. Redistribution never happens in B.

#### 6.4.4 The no-stakes case

If the liquidated position was the last active one (`totalStakes == 0` after removing its stake), a
remainder cannot be redistributed. Its debt becomes deficit and its collateral is held by the
DeficitLedger as `recoveredColl` until settlement, when it joins the claim pool. Only reachable in A.

Vectors: `liquidation_pool.json`, `auction.json`.

### 6.5 Redistribution and stakes

#### 6.5.1 Units

`LColl` is WETH wei per unit stake × `DECIMAL_PRECISION`; `LDebt` is **normalised debt** per unit
stake × `DECIMAL_PRECISION`. Redistributed debt therefore accrues interest through the index exactly
like the debt of the position that receives it, and `totalNormDebt` (which already contains it)
needs no adjustment.

#### 6.5.2 Distributing

Called with the liquidated position already removed (its stake is not in `totalStakes`).

```
function redistribute(collR, normR):          // precondition totalStakes > 0
    collNumerator = collR * DECIMAL_PRECISION + lastErrorColl
    normNumerator = normR * DECIMAL_PRECISION + lastErrorDebt
    dLColl = collNumerator / totalStakes                     // floor
    dLDebt = normNumerator / totalStakes                     // floor
    lastErrorColl = collNumerator − dLColl * totalStakes
    lastErrorDebt = normNumerator − dLDebt * totalStakes
    LColl += dLColl; LDebt += dLDebt
    pendingColl += collR; pendingNormDebt += normR
    emit Redistributed(collR, normR, LColl, LDebt, lastErrorColl, lastErrorDebt, totalStakes)
```

The carry guarantees `Σ_k dL_k · totalStakes_k ≤ DECIMAL_PRECISION · Σ_k distributed_k`, hence
`Σ_positions pending ≤ pending bucket` for both coll and debt (§10.3).

#### 6.5.3 Applying pending rewards

```
function applyPending(id):
    pc = pendingColl(p); pn = pendingNorm(p)          // §2.4, rounded down
    if pc > 0 or pn > 0:
        p.coll += pc; p.normDebt += pn
        pendingColl −= pc; pendingNormDebt −= pn
        totalCollateral += pc                           // totalNormDebt unchanged
        emit RewardsApplied(id, pc, pn)
    p.snapLColl = LColl; p.snapLDebt = LDebt
```

Applied at the start of every operation on that position (§5.1) and to every position that a
redemption actually redeems from. Not applied to positions a redemption merely visits or skips.
Truncation dust stays in `pendingColl` / `pendingNormDebt` forever.

#### 6.5.4 Stakes and the snapshot rule

```
function computeStake(coll):
    if totalStakesSnapshot == 0 or totalCollateralSnapshot == 0: return coll
    return mulDivDown(coll, totalStakesSnapshot, totalCollateralSnapshot)

function updateStake(id):                               // after applyPending
    newStake = computeStake(p.coll)
    totalStakes = totalStakes − p.stake + newStake
    p.stake = newStake

function updateSystemSnapshots():                       // end of every liquidation, A and B
    if totalStakes == 0:                                // no active position left
        totalStakesSnapshot = 0
        totalCollateralSnapshot = 0
    else:
        totalStakesSnapshot = totalStakes
        totalCollateralSnapshot = totalCollateral + pendingColl
    emit SystemSnapshotsUpdated(totalStakesSnapshot, totalCollateralSnapshot)
```

Why the `totalStakes == 0` branch: truncation dust stays in `pendingColl` forever, so without it a
liquidation of the last active position would store `totalStakesSnapshot = 0` with
`totalCollateralSnapshot = dust > 0`, and every later stake would be `mulDivDown(coll, 0, dust) = 0`
— redistribution would be impossible for the rest of the deployment. After the reset the next
position is staked 1:1 and never receives the old dust (its `snapL*` start at the current `L`).
Vector `redistribution.json#stakes_after_last_liquidation`.

Stakes are recomputed after open, addCollateral, withdrawCollateral, borrow, repay and a partial
redemption. Rationale: after redistributions, existing positions hold pending collateral their stake
does not reflect; a new position with the same collateral must get a proportionally smaller stake,
or it would capture an outsized share of future redistributions. Vectors: `redistribution.json`.

### 6.6 Stability pool — product–sum (deployment A)

#### 6.6.1 Idea

A deposit of `d` made when the product was `P0` (epoch `e0`, scale `s0`) is worth
`d · P / P0 / SCALE_FACTOR^(scale − s0)` now if the epoch is unchanged, else 0. Gains accrue in the
sums `S` (collateral) and `G` (interest), one per `(epoch, scale)`.

#### 6.6.2 Offset

Called inside `onLiquidation` with `0 < d ≤ T = totalDeposits` debt to absorb and `c` collateral.

```
function offset(d, c):
    T = totalDeposits
    // collateral gain per unit deposit, carry independent of P
    num = c * DECIMAL_PRECISION + lastCollError
    perUnit = num / T                                         // floor
    lastCollError = num − perUnit * T
    epochToScaleToS[currentEpoch][currentScale] += perUnit * P        // P before the update
    collGainsBalance += c
    token.burnFrom(this, d)
    totalDeposits = T − d
    if d == T:                                                // pool emptied exactly
        currentEpoch += 1; currentScale = 0; P = P_PRECISION
    else:
        k = 0
        newP = mulDivDown(P, T − d, T)
        while newP < P_MIN:
            k += 1
            newP = mulDivDown(P * SCALE_FACTOR^k, T − d, T)
        P = newP; currentScale += k
    emit PoolOffset(d, c, perUnit, lastCollError, P, currentEpoch, currentScale, totalDeposits)
```

Properties (proved in §6.6.9, checked by vectors and the reference fuzz):
- `P_MIN ≤ P ≤ P_PRECISION` after every offset; `P > 0` always.
- The loop runs at most 5 times (`k ≤ 5`, observed max 4) and `P · SCALE_FACTOR^k < 3.4·10^74`.
- Only `d == T` changes the epoch; a near-emptying offset changes the scale instead.
- `P` is rounded down, so `Σ compoundedDeposit ≤ totalDeposits` (no loss carry needed at 36-digit
  precision; the bias is at most `10^-27` relative per offset, against depositors).

#### 6.6.3 Bounds that keep `S` and `G` from overflowing

Write `perUnit_k = (c_k·DP + err_{k−1}) / T_k` with `DP = DECIMAL_PRECISION` and the carry
`err_{k−1} < T_j` for the divisor `T_j` of the previous event of the same accumulator. Then
`perUnit_k ≤ c_k·DP/T_k + err_{k−1}/T_k`.

- *Fresh part, collateral.* The pool only receives collateral through `onLiquidation`, where
  `c ≤ d·(WAD + LIQUIDATION_PENALTY)/price + 1` with `d ≤ T`, `price ≥ MIN_PRICE ≥ 2e18` and
  penalty ≤ 0.5, so `c ≤ 0.75·d + 1 ≤ T` and the fresh part is `≤ DP + DP/T ≤ 2·DP`, i.e.
  `≤ 2·10^54` after multiplying by `P ≤ 10^36`.
- *Fresh part, interest.* Interest reaches the pool only when `T ≥ MIN_DEPOSIT ≥ 10^18` (§6.2), so the
  fresh part is `≤ interest ≤ 2^128` and `≤ 3.4·10^74` after multiplying by `P`; realistic accruals
  (`interest ≤ 10^26`) give `≤ 10^62`.
- *Carry part.* `err/T_k < T_j / T_k ≤ 2^128` (supply cap, `T_k ≥ 1`), so `≤ 3.4·10^74` after
  multiplying by `P`. The carry is consumed by the event that pays it out (the new carry is
  `< T_k`), so a large carry contribution needs the pool to grow back to a large `T` before the
  next one.

`S` or `G` (checked arithmetic) can therefore only overflow after ≥ 338 adversarial events within one
`(epoch, scale)`, each requiring either an interest accrual near the supply cap or a full-supply
deposit-and-withdraw cycle. Under realistic sizes (`T ≤ 10^33`, interest `≤ 10^26`) every event adds
`≤ 10^69`, and overflow would take `≥ 10^8` events in a single `(epoch, scale)`. Accepted.

#### 6.6.4 `onLiquidation` (pool)

```
function onLiquidation(positionId, owner, debt, coll, price):     // onlyVault; coll WETH already received
    seized = min(coll, mulDivUp(debt, WAD + LIQUIDATION_PENALTY, price))
    surplus = coll − seized
    T = totalDeposits
    dP = min(debt, T)
    collP = (dP == debt) ? seized : mulDivDown(seized, dP, debt)
    collReturned = seized − collP
    if dP > 0: offset(dP, collP)
    if surplus > 0: WETH.safeTransfer(owner, surplus)
    if collReturned > 0: WETH.safeTransfer(vaultManager, collReturned)
    emit PoolLiquidation(positionId, debt, coll, seized, surplus, dP, collP, collReturned)
    return (dP, collReturned)
```

`seized` rounds up (protocol side), so the owner's surplus rounds down. If ICR < 1 + penalty,
`seized == coll` and there is no surplus; if ICR < 1 the pool takes a loss, which is the pool's risk.

#### 6.6.5 Interest

```
function onInterest(amount):            // onlyVault, lock-free; precondition totalDeposits ≥ MIN_DEPOSIT
    num = amount * DECIMAL_PRECISION + lastInterestError
    perUnit = num / totalDeposits
    lastInterestError = num − perUnit * totalDeposits
    epochToScaleToG[currentEpoch][currentScale] += perUnit * P
    interestGainsBalance += amount
    emit PoolInterest(amount, perUnit, lastInterestError)
```

Interest income is a claimable gain; it does not compound into the deposit.

#### 6.6.6 Compounded deposit

```
function compoundedDeposit(a):
    r = deposits[a]
    if r.initial == 0 or r.snapEpoch < currentEpoch: return 0
    ds = currentScale − r.snapScale
    if ds > 5: return 0
    q = mulDivDown(r.initial, P, r.snapP)
    return q / SCALE_FACTOR^ds                   // floor; equals floor(initial·P / (snapP·SCALE_FACTOR^ds))
```

The shortcut `ds > 5 ⇒ 0` is exact: `initial ≤ 2^128` and `P / snapP ≤ 10^9` give
`q < 3.5·10^47 < 10^54`.

#### 6.6.7 Gains

```
function gains(a):
    r = deposits[a]
    if r.initial == 0: return (0, 0)
    return (gain(r, S, r.snapS), gain(r, G, r.snapG))

function gain(r, acc, snap):
    total = acc[r.snapEpoch][r.snapScale] − snap
    for j in 1 .. SCALE_SPAN:
        total += acc[r.snapEpoch][r.snapScale + j] / SCALE_FACTOR^j          // floor
    return mulDivDown(r.initial, total, r.snapP * DECIMAL_PRECISION)
```

Gains of an old epoch are still paid from that epoch's sums. Scales beyond `snapScale + 2` are
ignored; the depositor's remaining fraction there is at most `SCALE_FACTOR^-2 = 10^-18`.

Attribution: the error carries make the **total** paid exact up to dust (`Σ gains ≤ balance`, §10.3),
while an individual depositor's gain may differ from their exact pro-rata share by up to
`T / DECIMAL_PRECISION` wei per offset (a carried remainder is credited to whoever is depositing at
the next offset) — the same characteristic as Liquity v1. Measured maximum on adversarial sequences
with `T ≈ 10^30`: 1.6·10^12 wei.

#### 6.6.8 Paying gains and snapshots

```
pay gains:  if collGain > 0:     collGainsBalance −= collGain;     WETH.safeTransfer(depositor, collGain)
            if interestGain > 0: interestGainsBalance −= interestGain; token.transfer(depositor, interestGain)

snapshot(x) = {initial: x, snapP: P, snapS: S[currentEpoch][currentScale],
               snapG: G[currentEpoch][currentScale], snapEpoch: currentEpoch, snapScale: currentScale}
```

#### 6.6.9 Why the bounds hold

With `P ∈ [P_MIN, P_PRECISION]` and `T ≤ 2^128`, `mulDivDown(P, T − d, T) ≥ P_MIN / T > 0` only
when scaled: the loop finds the least `k` with `P·10^(9k)·(T−d)/T ≥ P_MIN`. Since
`(T−d)/T ≥ 1/T ≥ 2^-128`, `10^(9k) ≥ 3.4·10^38` suffices, so `k ≤ 5`, and at the last iteration
`P·10^(9(k−1))·(T−d)/T < P_MIN` implies `P·10^(9k) < 3.4·10^74`. The new `P` is
`< SCALE_FACTOR · P_MIN = P_PRECISION`. Vectors: `product_sum.json`.

### 6.7 Redemption

#### 6.7.1 Fee

```
decayedBaseRate() = mulDivUp(baseRate, rpow(BASE_RATE_DECAY, block.timestamp − lastFeeOperationTime), RAY)
increment(x, S0)  = mulDivUp(x, WAD, S0 * BETA)
```

`rpow` of a factor below RAY with products rounded up never reaches 0; the decayed base rate floors
at 1 wei (10^-18) once positive. This is intended (fee never rounds down).

#### 6.7.2 `RedemptionModule.redeem`

```
function redeem(amount, maxIterations, maxFeeRate, upperHint, lowerHint):
    require(wired, NotWired)
    require(!vaultManager.shutdown(), SystemShutdown)
    require(amount > 0, ZeroAmount)
    require(maxIterations > 0, ZeroIterations)
    fetch price (required)
    vaultManager.accrue()
    require(token.balanceOf(msg.sender) >= amount, InsufficientBalance)
    S0 = token.totalSupply()
    decayed = decayedBaseRate()
    baseRateForFee = min(decayed + increment(amount, S0), WAD)       // from the requested amount
    feeRate = min(REDEMPTION_FEE_FLOOR + baseRateForFee, WAD)
    require(feeRate <= maxFeeRate, FeeExceedsMaximum)
    (redeemed, collSent, iterations) =
        vaultManager.redeemCollateral(msg.sender, amount, feeRate, price, maxIterations, upperHint, lowerHint)
    require(redeemed > 0, NothingRedeemed)
    baseRate = min(decayed + increment(redeemed, S0), WAD)            // from the amount actually redeemed
    lastFeeOperationTime = block.timestamp
    emit Redeemed(msg.sender, amount, redeemed, collSent, feeRate, iterations, baseRate)
```

The fee is charged at the rate implied by the requested amount; the stored base rate reflects what
was actually redeemed. If less is redeemed than requested, the redeemer paid a slightly higher rate
than strictly necessary — conservative by design.

#### 6.7.3 `VaultManager.redeemCollateral` — the loop

The fee stays in the redeemed positions: a position redeemed for `d` loses `d` of debt and
`mulDivDown(d, WAD − feeRate, price)` of collateral, so it keeps the fee's share of collateral.

```
function redeemCollateral(redeemer, amount, feeRate, price, maxIterations, upperHint, lowerHint):
    require(wired, NotWired); require(msg.sender == redemptionModule, Unauthorized)
    remaining = amount; burned = 0; collOut = 0; it = 0
    cur = sorted.getLast()
    while remaining > 0 and cur != 0 and it < maxIterations:
        it += 1
        prevId = sorted.getPrev(cur)
        (c, n) = effective(cur); debt = debtOf(n)
        if c * price < MCR * debt:                        // below MCR: liquidate, don't redeem
            cur = prevId; continue
        if remaining >= debt:                             // full redemption, closes the position
            applyPending(cur)
            out = mulDivDown(debt, WAD − feeRate, price)
            surplus = p.coll − out
            sorted.remove(cur)
            totalStakes −= p.stake; totalCollateral −= p.coll; totalNormDebt −= p.normDebt; activeCount −= 1
            p.coll = p.normDebt = p.stake = 0; p.status = ClosedByRedemption
            WETH.safeTransfer(p.owner, surplus + GAS_RESERVE)
            burned += debt; collOut += out; remaining −= debt
            emit PositionRedeemed(cur, debt, out, surplus, true); emit PositionUpdated(cur, OP_REDEEM)
            cur = prevId; continue
        d = min(remaining, debt − MIN_DEBT)               // partial: keep at least MIN_DEBT
        if d == 0: break                                  // position at exactly MIN_DEBT
        dn = mulDivDown(d, RAY, index)
        out = mulDivDown(d, WAD − feeRate, price)
        (found, prv, nxt) = sorted.find(c − out, n − dn, cur, cur, upperHint, lowerHint)
        if not found: break                               // stale hint: partial cancelled, no state change
        applyPending(cur)
        p.coll −= out; p.normDebt −= dn; totalCollateral −= out; totalNormDebt −= dn
        updateStake(cur)
        sorted.reinsert(cur, prv, nxt)                    // exact hints: succeeds without walking
        burned += d; collOut += out; remaining −= d
        emit PositionRedeemed(cur, d, out, 0, false); emit PositionUpdated(cur, OP_REDEEM)
        break                                             // a partial is always the last step
    token.burnFrom(redeemer, burned)
    WETH.safeTransfer(redeemer, collOut)
    return (burned, collOut, it)
```

Rules made explicit:
- Every visited node counts as an iteration, including skipped ones and a cancelled partial.
- Positions below MCR are skipped, never redeemed. No hint is needed to skip them; a long run of
  such positions consumes iterations (rational redeemers liquidate them first).
- A partial redemption is capped so the position keeps `≥ MIN_DEBT`
  (`debtOf(n − dn) ≥ debt − d ≥ MIN_DEBT`, proof as in §5.1.5). A position at exactly `MIN_DEBT`
  with `remaining < debt` ends the loop.
- Pending rewards are applied only to positions actually redeemed from.

Vectors: `redemption.json`.

### 6.8 Dutch auction (deployment B)

#### 6.8.1 Auction record

`debtRemaining` is the part of the auction's original debt not yet repaid (it is counted in
`DeficitLedger.auctionDebt`); `tab` is what buyers still have to pay, including the penalty;
`lot` is the WETH left to sell; `top` the start price; `tic` the start (or last reset) time.

#### 6.8.2 Start: `onLiquidation` (house)

```
function onLiquidation(positionId, owner, debt, coll, price):    // onlyVault; coll WETH already received
    aid = nextAuctionId; nextAuctionId += 1
    tab = mulDivUp(debt, WAD + LIQUIDATION_PENALTY, WAD)
    top = mulDivUp(price, BUFFER, WAD)
    auctions[aid] = {positionId, owner, debtRemaining: debt, tab, lot: coll, top, tic: block.timestamp, active: true}
    totalLot += coll; activeAuctions += 1
    deficitLedger.addAuctionDebt(debt)
    emit AuctionStarted(aid, positionId, owner, debt, tab, coll, top, block.timestamp)
    return (debt, 0)
```

The caller of `liquidate` receives the gas reserve, exactly as in A.

#### 6.8.3 Price and reset condition

```
price(a)      = mulDivUp(a.top, rpow(CUT, block.timestamp − a.tic), RAY)
needsReset(a) = (block.timestamp − a.tic > TAIL) or (price(a) * WAD < CUSP * a.top)
```

This is blueprint's `top · e^(−k·t)` with `CUT = e^(−k)`, computed exactly in integers.

#### 6.8.4 `buy(uint256 aid, uint256 maxColl, uint256 maxPrice, address who, bytes data)`

```
require(wired, NotWired)
require(!settled, SystemSettled)
a = auctions[aid]; require(a.active, AuctionNotActive)
require(not needsReset(a), AuctionNeedsReset)
pr = price(a)
require(pr <= maxPrice, PriceExceedsMax)
require(maxColl > 0, ZeroAmount)
require(who != address(0), InvalidCallbackTarget)
if data.length > 0:
    require(who ∉ {token, WETH, oracle, vaultManager, deficitLedger, shutdownModule, this}, InvalidCallbackTarget)
slice = min(a.lot, maxColl)
owe = mulDivUp(slice, pr, WAD)
if owe > a.tab:                                   // buying more than needed: cap at the tab
    owe = a.tab
    slice = mulDivDown(owe, WAD, pr)
else if owe < a.tab and slice < a.lot:            // partial purchase: dust rule
    if a.tab − owe < MIN_DEBT:
        require(a.tab > MIN_DEBT, NoPartialPurchase)
        owe = a.tab − MIN_DEBT
        slice = mulDivDown(owe, WAD, pr)
require(token.balanceOf(msg.sender) >= owe, InsufficientBalance)  // checked again after the callback
a.tab −= owe; a.lot −= slice; totalLot −= slice
toBurn = min(owe, a.debtRemaining)                // debt first …
toReserve = owe − toBurn                          // … then penalty
a.debtRemaining −= toBurn
finish = NONE
if a.tab == 0:                    finish = PAID       (leftover = a.lot)
else if a.lot == 0:               finish = EXHAUSTED  (shortfall = a.debtRemaining)
if finish != NONE: a.active = false; activeAuctions −= 1
if finish == PAID:      leftover = a.lot; totalLot −= leftover; a.lot = 0
if finish == EXHAUSTED: shortfall = a.debtRemaining; a.debtRemaining = 0
// interactions
WETH.safeTransfer(who, slice)
if data.length > 0:
    inPurchase = true                              // transient flag, readable via inPurchase()
    IAuctionBuyer(who).onAuctionPurchase(msg.sender, owe, slice, data)   // return value ignored
    inPurchase = false
require(token.balanceOf(msg.sender) >= owe, InsufficientBalance)
token.burnFrom(msg.sender, toBurn)
token.moveFrom(msg.sender, deficitLedger, toReserve)
deficitLedger.onAuctionPayment(toBurn, toReserve)
if finish == PAID and leftover > 0: WETH.safeTransfer(a.owner, leftover)
if finish == EXHAUSTED:             deficitLedger.onAuctionShortfall(shortfall)
emit AuctionBought(aid, msg.sender, who, slice, owe, pr, toBurn, toReserve, a.tab, a.lot, a.debtRemaining)
if finish != NONE: emit AuctionFinished(aid, finish, finish == PAID ? leftover : shortfall)
```

Notes. `tab ≥ debtRemaining` holds throughout (both fall by `owe` until `debtRemaining` reaches 0).
Penalty proceeds go to the reserve (decision of the P02 gate). The buyer callback is the only
arbitrary external call in the system. The **house's** state is final before it, but the
DeficitLedger and the token supply are not yet updated (payment is collected from `msg.sender`
after the callback), so during the callback `systemColl` already excludes the sold slice while
`systemDebt` still includes the unpaid debt. The callback therefore cannot re-enter the house (lock)
and `ShutdownModule.check` refuses to run while `inPurchase()` is true (§6.11.1); every other
reachable function either does not read auction or ledger state or cannot change it (views may
show the intermediate state).

Callback target. `require(who != address(0), InvalidCallbackTarget)` is checked for every `buy`,
right after the `maxColl` check. If `data.length > 0`, additionally
`require(who ∉ {token, WETH, oracle, vaultManager, deficitLedger, shutdownModule, this}, InvalidCallbackTarget)`
— exactly the addresses the house knows. Any other address is called; if it has no
`onAuctionPurchase` function the call reverts and the whole `buy` reverts with it.

#### 6.8.5 `reset(uint256 aid)`

```
require(wired, NotWired)
require(!settled, SystemSettled)
a = auctions[aid]; require(a.active, AuctionNotActive)
require(needsReset(a), AuctionNoResetNeeded)
fetch price (required)
a.top = mulDivUp(price, BUFFER, WAD); a.tic = block.timestamp
tip = min(TIP, deficitLedger.reserve())
if tip > 0: deficitLedger.payTip(msg.sender, tip)
emit AuctionReset(aid, a.top, a.tic, tip, msg.sender)
```

Resets are rate-limited by `TAIL` and `CUSP`, so the reserve can lose at most one `TIP` per auction
per reset interval. Vectors: `auction.json`.

### 6.9 Deficit ledger

#### 6.9.1 Meaning

`deficit` is stablecoin in circulation that no position or auction owes. It arises from an auction
shortfall (B) or a no-stakes liquidation remainder (A). `reserve` is protocol-owned stablecoin that
can cancel it.

#### 6.9.2 `cover()`

```
require(wired, NotWired)
require(!settled, SystemSettled)
c = min(reserve, deficit)
if c > 0: reserve −= c; deficit −= c; token.burnFrom(this, c)
emit DeficitCovered(c, reserve, deficit)
return c
```

Recording never auto-covers, so the indexer can report deficit recorded and covered separately.
Vectors: `deficit.json`.

### 6.10 Oracle

#### 6.10.1 Decision

A **failed call** is a `staticcall` with gas `ORACLE_GAS` that reverts, runs out of gas, or returns
fewer than 160 bytes. Decision, first matching row wins:

| # | Condition | Usable | Reason |
|---|---|---|---|
| 1 | sequencer feed call failed | no | `SEQUENCER_CALL_FAILED` |
| 2 | sequencer `answer != 0` (1 = down) | no | `SEQUENCER_DOWN` |
| 3 | sequencer `startedAt == 0` or `startedAt > now` | no | `SEQUENCER_INVALID` |
| 4 | `now − startedAt ≤ GRACE_PERIOD` | no | `GRACE_PERIOD` |
| 5 | price feed call failed | no | `PRICE_CALL_FAILED` |
| 6 | `answer ≤ 0` | no | `NON_POSITIVE` |
| 7 | `updatedAt == 0` or `updatedAt > now` | no | `INVALID_TIMESTAMP` |
| 8 | `now − updatedAt > STALENESS` | no | `STALE` |
| 9 | `answer > MAX_PRICE / 10^(18 − FEED_DECIMALS)` (checked before scaling) or `answer · 10^(18 − FEED_DECIMALS) < MIN_PRICE` | no | `OUT_OF_BOUNDS` |
| 10 | otherwise | yes | `OK`; `price = answer · 10^(18 − FEED_DECIMALS)` |

`MAX_PRICE / 10^k` is a floor division of constants, exact for the test, and makes the scaling
overflow-free.

#### 6.10.2 `fetchPrice`

Feeds are read **lazily**, in table order: the sequencer feed is called first; the price feed is
called only if rows 1–4 did not decide. A failed call is followed immediately by the gas rule of
§6.10.3, before anything else is evaluated. So with the sequencer down the price feed is never
called (and cannot raise `InsufficientGasForOracle`).

```
function fetchPrice():
    (usable, p, reason) = decide()     // lazy reads as above, gas rule after each failed call
    if usable:
        if p != lastGoodPrice: lastGoodPrice = p; emit LastGoodPriceUpdated(p)
        if failureStart != 0: failureStart = 0; emit OracleRecovered(block.timestamp)
        return (p, true)
    if failureStart == 0: failureStart = block.timestamp; emit OracleFailure(reason, block.timestamp)
    return (lastGoodPrice, false)
```

#### 6.10.3 Gas rule

After a failed feed call, `require(gasleft() >= ORACLE_POST_FAILURE_GAS, InsufficientGasForOracle)`.
With the 63/64 rule, a call that failed because the caller supplied too little gas leaves less than
`ORACLE_GAS / 63` behind, so the transaction reverts instead of recording a fake failure. Vectors:
`oracle.json` (decision table; the gas rule is tested in Foundry only).

### 6.11 Shutdown

#### 6.11.1 `check()`

```
function check():
    require(wired, NotWired)
    require(!triggered, AlreadyTriggered)
    require(auctionHouse == address(0) or not auctionHouse.inPurchase(), AuctionCallbackActive)
    vaultManager.accrue()
    deficitLedger.cover()
    (price, usable) = oracle.fetchPrice()              // updates the failure clock; never required
    live = vaultManager.activeCount() > 0 or (auctionHouse != address(0) and auctionHouse.activeAuctions() > 0)
    r = NONE
    if not usable and oracle.failureStart() != 0
       and block.timestamp − oracle.failureStart() >= ORACLE_FAILURE_DURATION:        r = ORACLE
    else if usable and live and systemDebt > 0
       and systemColl * price < CRITICAL_TCR * systemDebt:                              r = TCR
    else if deficit * BPS > DEFICIT_LIMIT_BPS * token.totalSupply():                    r = DEFICIT
    if r == NONE: emit ShutdownChecked(usable, price); return false
    triggered = true; triggerTime = block.timestamp; reason = r
    vaultManager.onShutdown()
    emit ShutdownTriggered(r, block.timestamp, price, usable, systemColl, systemDebt, deficit, totalSupply)
    return true
```

with `systemColl = VaultManager.totalCollateral + pendingColl + DeficitLedger.recoveredColl +
(B ? totalLot : 0)` (exactly the collateral that would join the claim pool at settlement) and
`systemDebt = mulDivUp(totalNormDebt, index, RAY) + auctionDebt + deficit`. The TCR trigger is only
evaluated while something is live (`activeCount > 0` or an active auction): with no position and no
auction, `totalNormDebt` and `pendingColl` are pure truncation dust and TCR is meaningless; a
residual deficit in an empty system is a matter for the DEFICIT trigger. `AuctionCallbackActive()`
prevents a buyer from triggering a shutdown from inside its own callback, when the ledger lags the
house (§6.8.4). `check` must not revert
when no condition holds: a revert would undo the oracle failure clock. Reasons are evaluated in the
order ORACLE, TCR, DEFICIT. The oracle clock starts at the first observed failure (§4.8), so a
shutdown for oracle failure needs two observations at least `ORACLE_FAILURE_DURATION` apart. It can
be delayed by nobody observing, never advanced.

#### 6.11.2 The window

Between `triggerTime` and `triggerTime + REPAYMENT_WINDOW`: accrual is frozen; `openPosition`,
`borrow`, `withdrawCollateral`, `liquidate`, `redeem` revert `SystemShutdown`; `repay`, `close`,
`addCollateral` work; the stability pool works fully; existing auctions continue (`buy`, and `reset`
if the price is usable); no new auction can start.

#### 6.11.3 `settle()`

```
function settle():
    require(wired, NotWired)
    require(triggered, NotTriggered)
    require(!settled, AlreadySettled)
    require(block.timestamp >= triggerTime + REPAYMENT_WINDOW, WindowNotOver)
    c = vaultManager.onSettlement()                         // remaining position + pending collateral
    if auctionHouse != address(0): c += auctionHouse.onSettlement()   // all lots; house.settled = true
    c += deficitLedger.onSettlement()                       // recoveredColl
    claimColl = c
    claimSupply = token.totalSupply()                       // after the ledger's reserve burn above
    settled = true
    emit Settled(claimColl, claimSupply, block.timestamp)
```

The hooks (each first checks `wired` and that the caller is the ShutdownModule):

```
function DeficitLedger.onSettlement():
    require(!settled, AlreadySettled)
    burned = reserve
    if burned > 0: token.burnFrom(this, burned)
    reserve = 0
    deficit += auctionDebt; auctionDebt = 0
    coll = recoveredColl; recoveredColl = 0
    settled = true
    if coll > 0: WETH.safeTransfer(shutdownModule, coll)
    emit LedgerSettled(burned, deficit, coll)           // values after the updates
    return coll

function DutchAuctionHouse.onSettlement():
    require(!settled, AlreadySettled)
    lot = totalLot; totalLot = 0
    settled = true                                      // every auction is void; no per-auction loop
    if lot > 0: WETH.safeTransfer(shutdownModule, lot)
    emit HouseSettled(lot, activeAuctions)              // activeAuctions is left unchanged, for the record
    return lot
```

After settlement the house holds no WETH, but individual `auctions[aid]` records keep their last
`lot`, `tab` and `active` values; they are void (`buy` and `reset` revert `SystemSettled`), and
`totalLot = 0` is authoritative.

If `claimSupply == 0` at settlement (every stablecoin burned), `claimColl` can never be claimed and
stays in the module. Unreachable in practice: positions still open at settlement imply outstanding
supply.

Unclosed positions forfeit their collateral to the claim pool; their owners keep the stablecoin they
borrowed (and can claim with it) and may reclaim the gas reserve (§5.1.10).

#### 6.11.4 `claim(uint256 amount)`

```
require(wired, NotWired)
require(settled, NotSettled)
require(amount > 0, ZeroAmount)
require(token.balanceOf(msg.sender) >= amount, InsufficientBalance)
out = mulDivDown(amount, claimColl, claimSupply)
token.burnFrom(msg.sender, amount)
claimedColl += out
WETH.safeTransfer(msg.sender, out)
emit Claimed(msg.sender, amount, out)
```

Order-independent: every claim uses the settlement snapshots, so `Σ out ≤ claimColl` and two holders
with equal balances receive equal amounts whatever the order. Vectors: `shutdown.json`.

---

## 7. Oracle usage table

| Operation | Usable price | Why |
|---|---|---|
| `openPosition`, `borrow`, `withdrawCollateral` | **required** | lower ICR |
| `repay`, `addCollateral`, `close` | not used | the owner must always be able to rescue or exit (I9) |
| `liquidate` (A: pool offset; B: auction start) | **required** | without a price nobody knows the position is at risk; also sets the auction `top` |
| `DutchAuctionHouse.reset` | **required** | new `top` |
| `DutchAuctionHouse.buy` | not used | the curve is price-independent once started |
| `RedemptionModule.redeem` | **required** | redemption at a bad price transfers value |
| `StabilityPool.deposit / withdraw / claimGains` | not used | no price dependence |
| `DeficitLedger.cover`, `accrue` | not used | |
| `ShutdownModule.check` | fetched, not required | unusability is itself a trigger; TCR is only evaluated with a usable price |
| `ShutdownModule.settle / claim`, `reclaimGasReserve` | not used | pro-rata in kind |
| Views (`icr`, `tcr`) | caller supplies the price | |

"Required" means: `fetchPrice()` and `require(usable, PriceUnusable)` at the position given in §5.

---

## 8. Rounding table

"Favours" names the party the rounding protects.

| # | Quantity | Expression | Direction | Favours |
|---|---|---|---|---|
| R1 | position debt from normalised debt | `mulDivUp(n, index, RAY)` | up | protocol (never understates debt) |
| R2 | normalised debt added by open / borrow | `mulDivUp(amount, RAY, index)` | up | protocol |
| R3 | normalised debt removed by repay, partial redemption, partial pool offset | `mulDivDown(amount, RAY, index)` | down | protocol (does not cancel more than paid) |
| R4 | new index | `mulDivUp(index, rpow(RAY + r, dt), RAY)` | up | protocol |
| R5 | `rpow` products | `mulDivUp(·, ·, RAY)` | up | protocol (growth up, decay slower) |
| R6 | interest minted | `mulDivUp(totalNormDebt, ΔI, RAY)` | up | holders (supply never lags debt growth) |
| R7 | interest to pool | `mulDivDown(interest, POOL_SHARE_BPS, BPS)` | down | reserve (remainder) |
| R8 | pending collateral / debt reward | `mulDivDown(stake, ΔL, DECIMAL_PRECISION)` | down | system (Σ claims ≤ bucket) |
| R9 | `ΔLColl`, `ΔLDebt` | floor with error carry | down + carry | system, no long-run loss |
| R10 | stake | `mulDivDown(coll, totalStakesSnapshot, totalCollateralSnapshot)` | down | other stakers |
| R11 | seized collateral (A) | `mulDivUp(debt, WAD + penalty, price)` | up | pool / protocol; surplus to owner rounds down |
| R12 | seized collateral to pool on partial offset | `mulDivDown(seized, dP, debt)` | down | pool depositors keep at most their share; rest redistributed |
| R13 | product `P` | `mulDivDown(P·SCALE_FACTOR^k, T − d, T)` | down | pool (Σ deposits ≤ T) |
| R14 | collateral gain per unit | floor with carry | down + carry | pool |
| R15 | interest gain per unit | floor with carry | down + carry | pool |
| R16 | compounded deposit | `mulDivDown` then floor by `SCALE_FACTOR^ds` | down | pool |
| R17 | depositor gains | per-scale floor, then `mulDivDown(initial, Σ, snapP·DECIMAL_PRECISION)` | down | pool |
| R18 | collateral to redeemer | `mulDivDown(d, WAD − feeRate, price)` | down | redeemed position |
| R19 | decayed base rate | `mulDivUp(baseRate, rpow(DECAY, dt), RAY)` | up | protocol (fee does not drop by rounding) |
| R20 | base-rate increment | `mulDivUp(x, WAD, S0·BETA)` | up | protocol |
| R21 | auction tab | `mulDivUp(debt, WAD + penalty, WAD)` | up | protocol |
| R22 | auction start price | `mulDivUp(price, BUFFER, WAD)` | up | protocol |
| R23 | auction price | `mulDivUp(top, rpow(CUT, t), RAY)` | up | protocol (buyer never pays below the curve) |
| R24 | auction payment | `mulDivUp(slice, price, WAD)` | up | protocol |
| R25 | auction slice after capping | `mulDivDown(owe, WAD, price)` | down | protocol |
| R26 | pro-rata claim | `mulDivDown(amount, claimColl, claimSupply)` | down | remaining claimants |
| R27 | deficit from a no-stakes remainder | `mulDivUp(normRest, index, RAY)` | up | holders (deficit not understated) |
| R28 | system debt for TCR | `mulDivUp(totalNormDebt, index, RAY) + A + F` | up | protocol (TCR not overstated) |
| R29 | oracle scaling | `answer · 10^(18 − d)` | exact | — |
| R30 | views `icr`, `nicr`, `tcr` | `mulDivDown` | down | display only, never used in decisions |
| R31 | gains from scales above the snapshot | `acc[e][s+j] / SCALE_FACTOR^j` | down (floor) | pool |
| R32 | oracle upper bound test | `answer > MAX_PRICE / 10^(18 − d)` | floor of a constant; the test is equivalent to `answer · 10^(18−d) > MAX_PRICE` rounded to whole answers | — |
| R33 | `currentIndex()` view | as R4 with `dt = now − lastAccrual` (or `index` after shutdown) | up | — |
| R34 | redistribution of an unabsorbed debt amount | `normAbsorbed = mulDivDown(debtAbsorbed, RAY, index)`, `normRest = n − normAbsorbed` | down (absorbed), so the remainder rounds up | system (no debt disappears) |

Every ratio *decision* uses the exact cross-multiplications of §2.2, not these views.

---

## 9. Permission matrix

| Function | Who may call |
|---|---|
| `openPosition` | anyone (becomes owner) |
| `borrow`, `withdrawCollateral`, `close`, `reclaimGasReserve` | owner of the position |
| `addCollateral`, `repay` | anyone, for any position |
| `accrue`, `liquidate`, `DutchAuctionHouse.reset`, `DeficitLedger.cover`, `ShutdownModule.check`, `ShutdownModule.settle`, `OracleAdapter.fetchPrice` | anyone |
| `redeem`, `DutchAuctionHouse.buy`, `StabilityPool.deposit / withdraw / claimGains`, `ShutdownModule.claim` | anyone, acting for themselves |
| `VaultManager.redeemCollateral` | RedemptionModule |
| `VaultManager.onShutdown`, `onSettlement` | ShutdownModule |
| `SortedPositions.insert / remove / reinsert` | VaultManager |
| `StabilityPool.onLiquidation`, `onInterest`; `DutchAuctionHouse.onLiquidation` | VaultManager |
| `DutchAuctionHouse.onSettlement`, `DeficitLedger.onSettlement` | ShutdownModule |
| `DeficitLedger.onInterest`, `recordDeficit` | VaultManager |
| `DeficitLedger.onPoolDust` | StabilityPool |
| `DeficitLedger.addAuctionDebt`, `onAuctionPayment`, `onAuctionShortfall`, `payTip` | DutchAuctionHouse |
| `StableToken.mint` | VaultManager |
| `StableToken.burnFrom` | VaultManager, StabilityPool or DutchAuctionHouse, DeficitLedger, ShutdownModule |
| `StableToken.moveFrom` | StabilityPool (A) or DutchAuctionHouse (B) |
| `wire(...)` on every contract except OracleAdapter | `deployer`, exactly once (ADR-021) |
| changing any parameter, strategy, oracle, or address | nobody |

**`wire`.** Each contract's `wire` takes exactly the addresses listed as "wired" in §4, reverts
`NotDeployer()` for any other caller and `AlreadyWired()` on a second call, rejects `address(0)`
except where §4 allows it (`InvalidParameter`), sets `wired = true` and emits
`Wired(address[] addresses)` in the order of the argument list. Every state-changing external
function except `wire` requires `wired` (`NotWired()`). Views do not.

A call by anyone not allowed above reverts `Unauthorized()`, except owner checks, which revert
`NotOwner()`.

---

## 10. Accounting identities

These become I1, I2 and supporting invariants in P03. "Exact" means integer equality.

### 10.1 I1 — per-holder token balances equal internal claims

Before settlement, with "donations" meaning tokens transferred to a contract by any means other
than a protocol function (the protocol never reads `balanceOf` for accounting, so donations are
inert):

| Holder | Identity (exact, net of donations) |
|---|---|
| VaultManager | `WETH.balanceOf = totalCollateral + pendingColl + activeCount · GAS_RESERVE` |
| StabilityPool | `WETH.balanceOf = collGainsBalance`; `token.balanceOf = totalDeposits + interestGainsBalance` |
| DutchAuctionHouse | `WETH.balanceOf = totalLot` |
| DeficitLedger | `token.balanceOf = reserve`; `WETH.balanceOf = recoveredColl` |
| RedemptionModule | holds nothing |
| ShutdownModule | 0 before settlement; `claimColl − claimedColl` after |

After settlement: VaultManager `= activeCount · GAS_RESERVE` (unreclaimed gas reserves); pool
unchanged; house and ledger hold 0.

Supporting exact identities: `totalCollateral = Σ_active coll`; `totalStakes = Σ_active stake`;
`totalNormDebt = Σ_active normDebt + pendingNormDebt`; `totalLot = Σ_active lot`;
`auctionDebt = Σ_active debtRemaining`; `activeCount = sorted.size` (before settlement only:
`reclaimGasReserve` decrements `activeCount` without touching the list).

### 10.2 I2 — stable supply equals system debt, with a derived drift bound

Let `S = token.totalSupply`, `A = auctionDebt`, `F = deficit`, `n = totalNormDebt`, `I = index`.
Define the exact integer

```
E = n · I − (S − A − F) · RAY
```

(`E / RAY` is the real-valued system debt minus the supply it is accounted against). `E = 0` at
deployment. Every operation changes `E` by a bounded amount:

| Operation | ΔE (exact interval) |
|---|---|
| accrual with `dt > 0` | `(−RAY, 0]` — interest is minted rounded up |
| open, borrow (`n += ⌈a·RAY/I⌉`, `S += a`) | `[0, I)` |
| partial repay, partial redemption, partial pool offset (`n −= ⌊a·RAY/I⌋`, `S −= a`) | `[0, I)` |
| close, full redemption, full pool offset (`n −= nᵢ`, `S −= ⌈nᵢ·I/RAY⌉`) | `[0, RAY)` |
| auction start (`n −= nᵢ`, `A += ⌈nᵢ·I/RAY⌉`) | `[0, RAY)` |
| no-stakes deficit (`n −= n_r`, `F += ⌈n_r·I/RAY⌉`) | `[0, RAY)` |
| redistribution, applying rewards, auction purchase, shortfall, cover, reserve and pool transfers, tips | `0` |

Hence, with `N` = number of accruals with `dt > 0`, `X` = number of operations in the second and
third rows, `Y` = number in the fourth to sixth rows, and `I` the current index (the index never
decreases). A composite operation counts **each sub-effect separately**: a liquidation in A with a
partial pool offset followed by a no-stakes deficit adds 1 to `X` and 1 to `Y`; a full offset adds 1
to `Y`; an offset of 0 adds nothing; a redemption adds one count per position it redeems from
(`Y` for each closed one, `X` for the partial one); every accrual with `dt > 0` adds 1 to `N`
(whether or not `interest > 0`).

```
−N · RAY  ≤  E  ≤  X · I + Y · RAY
```

with the left inequality strict when `N ≥ 1` and the right one strict when `X + Y ≥ 1` (each
operation's interval is half-open). In stablecoin wei: `−N ≤ (system debt − (S − A − F)) ≤ X · I/RAY + Y`. The bound is per
operation and cumulative, not constant; P03 states I2 with ghost counters for `N`, `X`, `Y`. The
identity holds through the shutdown window and is not defined after settlement (debts are cancelled;
the post-settlement identity is `Σ claims ≤ claimColl`). The reference fuzz checked this bound on
60 seeds × 300 steps in both deployments with no violation.

### 10.3 Bucket and pool solvency (exact inequalities)

- `Σ_active pendingColl(p) ≤ pendingColl` and `Σ_active pendingNorm(p) ≤ pendingNormDebt` (R8, R9).
- `Σ_depositors compoundedDeposit ≤ totalDeposits` (R13, R16).
- `Σ_depositors collGain ≤ collGainsBalance`; `Σ_depositors interestGain ≤ interestGainsBalance`
  (R14, R15, R17).
- `Σ claims paid ≤ claimColl` (R26).
- `P_MIN ≤ P ≤ P_PRECISION`; every active auction has `tab ≥ debtRemaining`, `tab ≥ MIN_DEBT`,
  `lot > 0`.

---

## 11. Events and errors

### 11.1 Events

Every state change emits enough to rebuild the contract's state from events alone (I14).
Enumerations (numeric values are part of the ABI):

- `op`: `OP_OPEN=1, OP_ADD_COLLATERAL=2, OP_WITHDRAW_COLLATERAL=3, OP_BORROW=4, OP_REPAY=5,
  OP_CLOSE=6, OP_REDEEM=7, OP_LIQUIDATE=8, OP_REWARDS=9` (`OP_REWARDS` is not emitted separately:
  reward application is reported by `RewardsApplied` and folded into the next `PositionUpdated`).
- `Status`: `None=0, Active=1, ClosedByOwner=2, ClosedByRedemption=3, ClosedByLiquidation=4,
  ClosedByShutdown=5`.
- `remainderPath` (liquidation): `NONE=0, REDISTRIBUTED=1, DEFICIT=2`.
- Shutdown `reason`: `NONE=0, ORACLE=1, TCR=2, DEFICIT=3`.
- `PositionUpdated` is also emitted by `liquidate` with `op = OP_LIQUIDATE` and by
  `reclaimGasReserve` with `op = OP_CLOSE`.

| Contract | Event | Fields |
|---|---|---|
| all | `Wired` | `address[] addresses` |
| VaultManager | `PositionOpened` | `uint256 indexed id, address indexed owner, uint256 debtMinted` |
| | `PositionUpdated` | `uint256 indexed id, uint256 coll, uint256 normDebt, uint256 stake, uint256 snapLColl, uint256 snapLDebt, uint8 status, uint8 op` — after every change of a stored position |
| | `RewardsApplied` | `uint256 indexed id, uint256 collReward, uint256 normReward` |
| | `CollateralAdded` | `uint256 indexed id, address indexed from, uint256 amount` |
| | `CollateralWithdrawn` | `uint256 indexed id, uint256 amount` |
| | `Borrowed` | `uint256 indexed id, uint256 amount, uint256 normDelta` |
| | `Repaid` | `uint256 indexed id, address indexed from, uint256 amount, uint256 normDelta` |
| | `PositionClosed` | `uint256 indexed id, uint256 debtBurned, uint256 collReturned, uint256 gasReserveReturned` |
| | `Liquidated` | `uint256 indexed id, address indexed owner, address indexed liquidator, uint256 debt, uint256 coll, uint256 debtAbsorbed, uint256 collRemainder, uint256 normRemainder, uint8 remainderPath, uint256 gasCompensation` |
| | `Redistributed` | `uint256 coll, uint256 normDebt, uint256 LColl, uint256 LDebt, uint256 errorColl, uint256 errorDebt, uint256 totalStakes` |
| | `SystemSnapshotsUpdated` | `uint256 totalStakesSnapshot, uint256 totalCollateralSnapshot` |
| | `InterestAccrued` | `uint256 index, uint256 interest, uint256 toPool, uint256 toReserve, uint256 timestamp` |
| | `PositionRedeemed` | `uint256 indexed id, uint256 debtRedeemed, uint256 collToRedeemer, uint256 surplusToOwner, bool closed` |
| | `GasReserveReclaimed` | `uint256 indexed id, address indexed owner, uint256 amount` |
| | `VaultShutdown` | `uint256 index` |
| | `VaultSettled` | `uint256 collToClaimPool, uint256 activePositions` |
| SortedPositions | `NodeInserted` | `uint256 indexed id, uint256 prev, uint256 next` |
| | `NodeRemoved` | `uint256 indexed id` |
| StabilityPool | `DepositUpdated` | `address indexed depositor, uint256 deposit, uint256 P, uint256 epoch, uint256 scale, uint256 snapS, uint256 snapG` |
| | `GainsPaid` | `address indexed depositor, uint256 collGain, uint256 interestGain` |
| | `PoolOffset` | `uint256 debt, uint256 coll, uint256 perUnitGain, uint256 lastCollError, uint256 P, uint256 epoch, uint256 scale, uint256 totalDeposits` |
| | `PoolLiquidation` | `uint256 indexed positionId, uint256 debt, uint256 coll, uint256 seized, uint256 surplus, uint256 debtOffset, uint256 collToPool, uint256 collReturned` |
| | `PoolInterest` | `uint256 amount, uint256 perUnitGain, uint256 lastInterestError` |
| | `PoolDustSwept` | `uint256 amount` |
| DutchAuctionHouse | `AuctionStarted` | `uint256 indexed auctionId, uint256 indexed positionId, address indexed owner, uint256 debt, uint256 tab, uint256 lot, uint256 top, uint256 tic` |
| | `AuctionBought` | `uint256 indexed auctionId, address indexed sender, address who, uint256 slice, uint256 owe, uint256 price, uint256 burned, uint256 toReserve, uint256 tab, uint256 lot, uint256 debtRemaining` |
| | `AuctionReset` | `uint256 indexed auctionId, uint256 top, uint256 tic, uint256 tip, address indexed caller` |
| | `AuctionFinished` | `uint256 indexed auctionId, uint8 reason (1 PAID, 2 EXHAUSTED), uint256 amount (leftover or shortfall)` |
| | `HouseSettled` | `uint256 lot, uint256 activeAuctions` |
| RedemptionModule | `Redeemed` | `address indexed redeemer, uint256 requested, uint256 redeemed, uint256 collSent, uint256 feeRate, uint256 iterations, uint256 baseRate` |
| DeficitLedger | `ReserveIncreased` | `uint256 amount, uint8 source (1 INTEREST, 2 AUCTION_PENALTY, 3 POOL_DUST)` |
| | `ReserveDecreased` | `uint256 amount, uint8 reason (1 TIP)` |
| | `AuctionDebtChanged` | `int256 delta, uint256 auctionDebt` |
| | `DeficitRecorded` | `uint256 amount, uint256 coll, uint8 source (1 AUCTION, 2 NO_STAKES)` |
| | `DeficitCovered` | `uint256 amount, uint256 reserve, uint256 deficit` |
| | `LedgerSettled` | `uint256 reserveBurned, uint256 deficit, uint256 recoveredColl` |
| OracleAdapter | `LastGoodPriceUpdated` | `uint256 price` |
| | `OracleFailure` | `uint8 reason, uint256 timestamp` |
| | `OracleRecovered` | `uint256 timestamp` |
| ShutdownModule | `ShutdownChecked` | `bool usable, uint256 price` |
| | `ShutdownTriggered` | `uint8 reason, uint256 timestamp, uint256 price, bool usable, uint256 systemColl, uint256 systemDebt, uint256 deficit, uint256 totalSupply` |
| | `Settled` | `uint256 claimColl, uint256 claimSupply, uint256 timestamp` |
| | `Claimed` | `address indexed holder, uint256 amount, uint256 collOut` |
| StableToken | ERC-20 `Transfer`, plus nothing else | mint/burn appear as `Transfer` from/to `address(0)` |

Oracle reason codes: `1 SEQUENCER_CALL_FAILED, 2 SEQUENCER_DOWN, 3 SEQUENCER_INVALID,
4 GRACE_PERIOD, 5 PRICE_CALL_FAILED, 6 NON_POSITIVE, 7 INVALID_TIMESTAMP, 8 STALE, 9 OUT_OF_BOUNDS`.

### 11.2 Errors

Custom errors only; the Python model raises exceptions with identical names. "Where" lists every
function that can raise the error from this spec's own checks.

| Error | Trigger | Where |
|---|---|---|
| `NotWired()` | contract not wired | every state-changing function except `wire` |
| `AlreadyWired()` | second `wire` | `wire` |
| `NotDeployer()` | `wire` caller ≠ deployer | `wire` |
| `InvalidParameter(uint8 index)` | constructor/wire argument out of range or zero address where not allowed | constructors, `wire` |
| `Unauthorized()` | caller not in the permission matrix | every restricted function |
| `NotOwner()` | caller ≠ position owner | `withdrawCollateral`, `borrow`, `close`, `reclaimGasReserve` |
| `ZeroAmount()` | amount argument is 0 | `addCollateral`, `withdrawCollateral`, `borrow`, `repay`, `deposit`, `withdraw`, `redeem`, `buy` (`maxColl`), `claim` |
| `SystemShutdown()` | operation forbidden after the trigger | `openPosition`, `withdrawCollateral`, `borrow`, `liquidate`, `redeem` |
| `SystemSettled()` | operation forbidden after settlement | `addCollateral`, `repay`, `close`, `buy`, `reset`, `cover`, every DeficitLedger hook except `onSettlement` (§5.6; unreachable through the core) |
| `NotSettled()` | settlement required | `reclaimGasReserve`, `claim` |
| `PriceUnusable()` | required price not usable | per §7 |
| `InsufficientGasForOracle()` | `gasleft() < ORACLE_POST_FAILURE_GAS` after a failed feed call | `fetchPrice` (and everything that calls it) |
| `PositionNotActive()` | status ≠ Active | position functions, `liquidate`, `reclaimGasReserve` |
| `DebtBelowMinimum()` | `debt < MIN_DEBT` at opening | `openPosition` |
| `IcrBelowMcr()` | resulting ICR below MCR | `openPosition`, `withdrawCollateral`, `borrow` |
| `InsufficientCollateral()` | `amount > coll` | `withdrawCollateral` |
| `RepayExceedsMaximum()` | `amount > debt − MIN_DEBT` | `repay` |
| `CollateralTooLarge()` | resulting stored collateral would exceed `2^128 − 1` | `openPosition`, `addCollateral` |
| `InvalidFeedDecimals()` | `priceFeed.decimals()` fails or exceeds 18 | OracleAdapter constructor |
| `AuctionCallbackActive()` | `check` called while the house is inside a buyer callback | `ShutdownModule.check` |
| `InsufficientBalance()` | caller's stablecoin balance below the amount to burn or move | `repay`, `close`, `deposit`, `redeem`, `buy`, `claim` |
| `NotLiquidatable()` | ICR ≥ MCR | `liquidate` |
| `SupplyCapExceeded()` | total supply would exceed `2^128 − 1` | `StableToken.mint` |
| `StaleHint()` | hint walk exceeded `MAX_HINT_STEPS` | `insert`, `reinsert` (all position operations) |
| `NodeExists()` / `NodeNotFound()` | list misuse (unreachable through the VaultManager) | SortedPositions |
| `DepositTooSmall()` | resulting deposit non-zero and below `MIN_DEPOSIT` | `deposit`, `withdraw` |
| `NoDeposit()` | no deposit record | `withdraw`, `claimGains` |
| `ZeroIterations()` | `maxIterations == 0` | `redeem` |
| `FeeExceedsMaximum()` | `feeRate > maxFeeRate` | `redeem` |
| `NothingRedeemed()` | loop redeemed nothing | `redeem` |
| `AuctionNotActive()` | unknown or finished auction | `buy`, `reset` |
| `AuctionNeedsReset()` | `needsReset` true | `buy` |
| `AuctionNoResetNeeded()` | `needsReset` false | `reset` |
| `PriceExceedsMax()` | `price > maxPrice` | `buy` |
| `NoPartialPurchase()` | partial buy (`owe < tab` and `slice < lot`) with `tab − owe < MIN_DEBT` and `tab ≤ MIN_DEBT` | `buy` |
| `InvalidCallbackTarget()` | `who == address(0)`; or `data` non-empty and `who ∈ {token, WETH, oracle, vaultManager, deficitLedger, shutdownModule, house}` | `buy` |
| `AlreadyTriggered()` | `check` after trigger | `check` |
| `NotTriggered()` / `AlreadySettled()` / `WindowNotOver()` | settlement preconditions | `settle`; `NotTriggered`/`AlreadySettled` also `VaultManager.onSettlement` |
| `SystemShutdown()` (hook) | `VaultManager.onShutdown` called when already shut down | `onShutdown` |
| `ReentrancyGuardReentrantCall()` | reentrant call (OZ) | lock-guarded functions |
| OZ ERC-20 errors, `SafeERC20FailedOperation`, `Panic` | token-level failures; arithmetic bugs | — |

---

## 12. Deviations from the blueprint

The kit's "Corrections to the blueprint" list referenced by the P02 prompt is not in the repository;
this list is built from the blueprint itself and supersedes it where they differ. Decisions D-1 to
D-3 were taken by the human at the P02 gate.

| ID | Blueprint | This spec | Reason |
|---|---|---|---|
| D-1 | §11.3, Q1: socialisation default open; both variants "implemented and measured" | Deployment A redistributes the pool remainder; deficit only when no stakes remain. No socialisation flag | Human decision; follows the §4.6 waterfall; one code path |
| D-2 | §8.4: redemption fee unspecified destination | Fee stays in the redeemed positions (collateral not drawn) | Human decision; no new token flow; identical in A and B |
| D-3 | §8.7: penalty in B unspecified | `tab = debt × (1 + penalty)`; debt repaid first, penalty to the reserve; whole collateral auctioned, leftover to owner | Human decision; comparable borrower cost across A and B |
| D-4 | §8.7, App. A: `top · e^(−k·t)` | `top · CUT^t` via `rpow` | Exact integer computation; identical curve with `CUT = e^−k`. Stepwise variant dropped |
| D-5 | App. B: `openPosition` is `payable` | Not payable; gas reserve is WETH pulled with the collateral | §4.2 says the reserve is WETH; one asset |
| D-6 | §8.2: per-position `gasReserve` field | Removed; every position's reserve is the immutable `GAS_RESERVE` | Redundant state |
| D-7 | §8.3 pseudocode: interest minted to the pool without notifying it; bare `/` | Pool notified (`onInterest`, updates `G`); split rounded down; pool share only when `totalDeposits ≥ MIN_DEPOSIT`, else to the reserve | Otherwise I1 breaks and interest can be stranded; `G` overflow bound (§6.6.3) |
| D-8 | §8.5: v1 product–sum, `P` at 18 digits | Epochs kept; `P` at 36 digits with a bounded rescaling loop; carries independent of `P`; `SCALE_SPAN = 2`; `MIN_DEPOSIT`; dust sweep | v1 `P` can reach 0 and DoS liquidations; a `P`-dependent carry over-credits (found by the reference fuzz) |
| D-9 | §8.8 pseudocode | Unusable on `updatedAt > now`, `startedAt == 0`; scaling overflow checked; gas cap and post-failure gas check; failure clock | The pseudocode reverts on a future timestamp and lets a caller fake an oracle failure with low gas |
| D-10 | §4.7, §8.9: "oracle unusable longer than X" | Failure clock starts at the first observed failure, resets on success; `check()` never reverts when nothing triggers | A clock based on the last successful read would trigger instantly after a quiet period |
| D-11 | §8.4: redemption skips ICR < MCR; interface has no hint | Skipped nodes count as iterations; hints only for the final partial; stale partial hint cancels the partial; partial capped at `debt − MIN_DEBT`; `maxFeeRate` in WAD instead of bps | Bounded loops; deterministic; WAD consistency |
| D-12 | §8.7: tip "from the position's gas reserve" for start and reset | Starter gets the whole gas reserve (as in A); reset tip from the reserve, capped by its balance | One reserve per position cannot fund repeated resets; symmetric starter incentive across A and B |
| D-13 | §8.4: surplus and gas reserve "wait to be collected" | Pushed immediately (WETH transfers cannot fail for ordinary recipients) | Removes a claimable-surplus bucket from I1 |
| D-14 | §4.5, Q4: partial liquidation as a deployment parameter | Full liquidation only | Not in the P02 parameter list; prompt outranks blueprint; open question |
| D-15 | §8.9 step 2: in-flight auctions "finish by their rules or close into deficit" | Auctions continue during the window; at settlement all lots join the claim pool in O(1) and auction debt is folded into the deficit | Bounded, no per-auction loop |
| D-16 | App. A: pro-rata "amount × pool / unpaid supply" | Snapshots at settlement; reserve burned before the supply snapshot; unclosed gas reserves reclaimable | Order-independent claims; protocol reserve protects holders |
| D-17 | §8.11: `close` owner-only, no oracle mentioned | `close` needs no price and works at any ICR and during the window | Exit by full repayment never harms the system |
| D-18 | §8.6: L accumulators "WAD" | `LDebt` in normalised-debt units; error carries; stake snapshot rule | Redistributed debt accrues interest consistently (prompt) |
| D-19 | §8.1 rounding table (8 rows) | Extended to every division (§8) and to exact ratio comparisons (§2.2) | Completeness |
| D-20 | §8.11 | `wire` added; per-contract permission lists | ADR-021 |
| D-21 | §8.8 table | Extended to every operation (§7); `buy` needs no price; `check` fetches but does not require | Completeness |
| D-22 | §8.10 events | Extended so every state change is rebuildable (§11.1) | I14 |
| D-23 | §4.4: — | Supply cap `2^128 − 1` | Bounds pool arithmetic |
| D-24 | §8.6: stake snapshot rule (Liquity v1) | Snapshots reset to 0 when no active position remains; `computeStake` returns `coll` when either snapshot is 0 | Truncation dust would otherwise freeze all future stakes at 0 (spec-audit finding B1) |
| D-25 | — | `CollateralTooLarge` cap on stored collateral; `AuctionCallbackActive` guard on `check`; TCR trigger only while something is live and counting `recoveredColl` | Overflow-free comparisons; no shutdown forced from inside a buyer callback or by dust in an empty system |
| D-26 | — | Exact constructor and `wire` signatures with ordered argument checks (§3.4) | Deterministic `InvalidParameter` indices |

---

## Appendix A — Vector index

Vectors live in `spec/vectors/` (format and replay rules: `spec/vectors/README.md`). Expected values
were computed with exact integer arithmetic by a throwaway reference implementation, not by hand.
System-level vectors are complete logs of public operations from deployment; unit-level vectors
drive one algorithm from an explicit state.

| File | Covers |
|---|---|
| `math.json` | `mulDivDown/Up`, `rpow` with its multiplication trace, derived constants |
| `interest.json` | accrual with pool share / below `MIN_DEPOSIT` / deployment B, frequency effect, conversions |
| `oracle.json` | every row of the decision table, boundaries, overflow-safe scaling, lazy reads |
| `sorted_list.json` | order with ties, hint validation, walks, `StaleHint`, `excludeId` (head, hint, only node) |
| `redistribution.json` | redistribution and snapshot stakes; stakes after the last liquidation (D-24); error carry |
| `liquidation_pool.json` | A: with / without surplus, underwater, partial absorption, empty pool, no-stakes deficit |
| `product_sum.json` | deposits, offsets, interest, scale change, epoch change, gains across scales and epochs, dust sweep |
| `redemption.json` | skip / full / partial, `MIN_DEBT` stop, stale-hint cancel, base-rate decay and fee, single-node partial |
| `auction.json` | price curve with the cusp crossing at t = 793/794; partial, dust rule, `NoPartialPurchase`, paid tab; reset tip and shortfall |
| `deficit.json` | shortfall then cover from interest |
| `shutdown.json` | pro-rata claims, order independence |
| `drift.json` | I2 drift `E` and its counter bound after every operation, deployments A and B |

## Appendix B — Inputs to P03

1. **I13** (sorted order) needs a derived relative tolerance (§6.3.3); exact order fails under
   adversarial near-ties (observed up to 7.1·10^-19 relative).
2. **I2** uses the counter bound of §10.2 with ghost counters `N`, `X`, `Y`.
3. **I1** equalities are exact in the absence of donations; decide whether handlers donate.
4. Pool per-depositor attribution is bounded by `T / DECIMAL_PRECISION` per offset, total exact
   (§6.6.7).
5. Blueprint §16.2 states I2 as "supply = debts + auction debt + pool liabilities − covered deficit";
   this spec's identity (§10.2) supersedes it. Blueprint §16.5 compares model and chain with a
   rounding tolerance; the python-model skill requires zero tolerance, which P03 adopts.
