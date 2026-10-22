# Preregistration — Bagehot

**Status: DRAFT (P05).** Frozen at P30, before the first non-pilot sweep. Approval date and commit
are filled in at the freeze.

- Approval date: `TBD-P30`
- Commit at freeze: `TBD-P30`

> After the freeze this file is never rewritten: changes are dated addenda appended in §11, each
> saying what changed and why. Results that contradict a preregistered hypothesis are reported as
> such. Nothing is re-tuned to make a hypothesis come out right (ADR-0013).

Every number marked **`TBD-P30`** is deliberately unset. Each one has candidate values and the
prompt whose measurement decides it; nothing downstream may read a `TBD-P30` value, and P30 fails
if any remain.

---

## 1. Research questions

**Q1 — Parameters.** For each deployment, what minimum collateral ratio meets the risk appetite
R (§5) under the L2 and L1 gas regimes measured at P09, and how does that MCR decompose into
premium, gap buffer, slippage buffer and model margin (blueprint §10.4)?

**Q2 — Comparison.** Which deployment — A (stability pool) or B (Dutch auction) — has the lower
**total system cost** (§4.1) across scenarios S1–S9 at matched parameters?

**Q3 — Boundary.** Under which environmental conditions does the ranking from Q2 reverse? The
three candidate conditions, each with its own scenario: liquidity depth (S8), oracle degradation
(S6, S7) and depositor flight (S9).

Q1 is a calibration question answered per deployment; Q2 is the comparison; Q3 asks where the
answer to Q2 stops holding. The report answers all three, in that order.

---

## 2. Hypotheses

Each hypothesis is directional, has one primary outcome and one decision rule. "Difference" always
means **median(B) − median(A)** of the stated outcome, over the runs of the stated scenario set,
with a 95% moving-block bootstrap interval (§6). Thresholds inside the hypotheses are part of the
preregistration and are fixed at P30.

| id | Hypothesis | Direction | Primary outcome | Decision rule |
|---|---|---|---|---|
| **H1** | In **short crashes** — a drawdown of at least `D_crash = TBD-P30` (candidates 20%, 30%, 40%) completed within `X = TBD-P30` hours (candidates 6, 12, 24) — deployment A produces less bad debt than deployment B | A < B | `bad_debt_net` per debt-year, in bps (§4.2 M1) | **Confirmed** if the difference is > 0 and the 95% interval excludes 0. **Refuted** if < 0 and the interval excludes 0. Otherwise **no detected difference** |
| **H2** | In **long slides** — a monotone-in-trend decline lasting at least `Y = TBD-P30` days (candidates 3, 7, 14) — deployment B has the lower total system cost | B < A | `total_system_cost` per debt-year, in bps (§4.1) | As H1, with the sign reversed: **confirmed** if the difference is < 0 and the interval excludes 0 |
| **H3** | The Q2 ranking **reverses under thin liquidity**: below a depth-scaling factor `Z = TBD-P30` (candidates 0.5, 0.25, 0.1 of the measured book at the crash blocks), the sign of the H2 difference in S8 is opposite to its sign in S4 | sign(S8) ≠ sign(S4) | `total_system_cost` per debt-year, in bps | **Confirmed** if the two differences have opposite signs **and** both 95% intervals exclude 0. **Refuted** if both intervals exclude 0 with the same sign. Otherwise **no detected difference** |

Scenario membership for H1 and H2 is decided by the price path, not by the scenario label: a path
is classified by the detector in §3.3 before any outcome is computed, and the classification is
part of the run row. S2, S3 and S5 supply short-crash paths; S4 supplies long-slide paths; a path
that satisfies neither definition is used for descriptive results only.

**Multiplicity.** H1, H2 and H3 are three pre-planned tests. The family-wise decision uses Holm's
correction over the three bootstrap p-values, in the order H1, H2, H3. Per-scenario and
per-parameter-cell results are descriptive and carry no confirmation claim.

---

## 3. Design

### 3.1 Deployments compared

Two deployments of the identical core (ADR-0003): **A** with `StabilityPool`, **B** with
`DutchAuctionHouse`. Every shared parameter is equal in a comparison pair, which the sweep runner
asserts before a cell runs (`docs/spec.md` §3.3 constraint 2). `POOL_SHARE_BPS = 0` in B by
construction, so the pool-capital cost term (§4.2 M5) is identically zero there; that is a
property of the mechanism, not a modelling choice, and the comparison is of total system cost,
which includes it.

### 3.2 Scenarios

Blueprint §13.4. Each scenario fixes the price-path source, the environment and the measurement
target. Both deployments run every scenario.

| id | Scenario | Input | What it measures |
|---|---|---|---|
| S1 | Calm market | Bootstrap paths, low volatility | Running cost, pool compensation |
| S2 | One-day crash | Historical path (March 2020 shape), Base infrastructure | Gap, bad debt |
| S3 | Base-native crash | Historical fork: oracle and liquidity from those blocks (August 2024) | Behaviour in a real environment |
| S4 | Long slide | Bootstrap paths with extended declines | Pool exhaustion, auction resets |
| S5 | Shock with rebound | Synthetic paths | Unnecessary liquidations |
| S6 | Frozen oracle | Updates suspended for a controlled interval | Freshness rules, shutdown |
| S7 | Sequencer outage | Outage window plus grace period | Cost of the grace period |
| S8 | Thin liquidity | Slippage from crash blocks, scaled by a depth factor | Where the auction stops working |
| S9 | Depositor flight | High depositor sensitivity | Robustness of deployment A |

### 3.3 Price paths and their classification

- **Bootstrap paths** (S1, S4): moving-block bootstrap of log returns from the P06 series, block
  length `L_block = TBD-P30` (candidates 1 h, 6 h, 24 h of returns), chosen at P28 to preserve the
  autocorrelation and volatility clustering of the source, with the diagnostic reported.
- **Historical paths** (S2, S3): replayed as recorded, with the oracle update times of the source.
- **Synthetic paths** (S5, S6, S7): a drop of depth `d` over `t_fall`, a plateau, then a rebound of
  depth `d_up`, with the grid in §4 of the scenario config.
- **Classification.** A path is a *short crash* if its maximum drawdown is at least `D_crash` and
  the time from the drawdown's start to its trough is at most `X` hours. It is a *long slide* if
  the price declines by at least `D_slide = TBD-P30` over at least `Y` days with no intervening
  recovery exceeding `R_up = TBD-P30` of the decline. Computed from the path alone, before the
  simulation runs.

### 3.4 Environments

| Environment | Oracle | Liquidity | Used for |
|---|---|---|---|
| `model` | Path driven directly | Liquidity model fitted at P25 | All sweeps, all scenarios |
| `fork_replay` | `ReplayAggregator` on a Base fork | Real pools, relative slippage | S2, S4–S9 verification subsets |
| `fork_historical` | Real Chainlink feed at block N | Real pools at block N | S3 |

The sweeps run in `model` (ADR-0012); fork environments verify that the model's outcome on a
matched subset agrees within the pre-stated agreement band of §6.4.

### 3.5 Agents

Borrowers, depositors and liquidators, calibrated at P26–P27. The liquidator's latency comes from
a Kaplan–Meier fit to right-censored Base data (ADR-0025); the depositor's withdrawal sensitivity
is a scenario parameter, raised in S9. Agent parameters are **fixed by calibration before the
sweep** and are not swept except where a scenario names them.

---

## 4. Outcomes

All metrics are computed from one run's output by `experiments/metrics.py`, from the fields in
§4.4. A run is one tuple (scenario, variant, parameter cell, seed, environment) over a horizon
`T_run`. Monetary quantities are in stablecoin units (1e18 = 1 USD of debt) and are converted to
rates by dividing by **debt-years**, `DY = ∫ systemDebt(t) dt / 31_536_000`, reported in basis
points per year. Both the raw total and the rate are stored; the rate is what hypotheses test.

### 4.1 Primary metric

**Total system cost** (blueprint §14.2):

```
total_system_cost = value_given_away + pool_capital_cost + bad_debt_net        [stable wei]
tsc_bps_per_year  = 10_000 * total_system_cost / debt_years
```

It is the sum of three disjoint quantities (§4.2 M4, M5, M1): value that left the borrower side,
interest paid to pool depositors, and debt that nothing covered. Disjointness is asserted per run
by the identity check in §4.3.

### 4.2 Secondary metrics

| id | Metric | Definition over run output | Unit |
|---|---|---|---|
| M1 | **Bad debt** | `bad_debt_gross = Σ DeficitRecorded.amount`; `bad_debt_net = bad_debt_gross − Σ DeficitCovered.amount`. The hypotheses use `bad_debt_net`, which equals `DeficitLedger.deficit` at `T_run` | stable wei; also bps/year |
| M2 | **Bad-debt event frequency** | `n_positions_with_bad_debt / position_years`, where a position counts once if any `DeficitRecorded` or `AuctionFinished(EXHAUSTED)` names it, and `position_years = Σ_p (active seconds of p) / 31_536_000` | events per position-year |
| M3 | **Time under threshold** | `Σ_p Σ_intervals (t_end − t_start)` over maximal intervals in which position `p` satisfies `isLiquidatable(p, price(t))` and is not yet liquidated, evaluated at every oracle update and at every state change of `p` | position-seconds; also mean seconds per liquidatable episode |
| M4 | **Value given away** | `Σ_liquidations (seized_coll × oracle_price_at_event − debt_cancelled) + Σ_auction_buys (slice × oracle_price_at_event − owe)`, i.e. all value that left positions above the debt they extinguished. Decomposed, and the parts sum to the total: `captured_by_depositors` (A) + `captured_by_buyers` (B) + `captured_by_keepers` (gas reserves and tips) + `slippage_dissipated` (from the P25 liquidity model, applied to each taker's assumed sale) | stable wei; also bps/year |
| M5 | **Cost of pool capital** | `Σ InterestAccrued.toPool` over the run (identically 0 in B) | stable wei; also bps/year |
| M6 | **Unnecessary liquidations** | A liquidation of position `p` at `t` is *unnecessary* if, holding `p`'s collateral and debt at their pre-liquidation values, `ICR(p, price(s)) ≥ MCR` for some `s ∈ (t, t + W]` on the realised path, with `W = TBD-P30` (candidates 1 h, 6 h, 24 h). Reported as a count and as a share of all liquidations | count; share |
| M7 | **Loss transfer** | `redistributed_debt / (redistributed_debt + pool_absorbed_debt + bad_debt_gross)`, where `redistributed_debt` is the debt moved through the `LDebt` accumulator and `pool_absorbed_debt` is the debt offset against deposits. B has no redistribution, so its numerator is 0 by construction | share in [0, 1] |
| M8 | **Shutdown outcome** | Whether the run shut down, the trigger reason, `triggerTime`, and the realised claim rate `claimColl / claimSupply` at settlement | enum + ratio |
| M9 | **Peg-floor availability** | Share of run time during which `redeem` would revert `TCRBelowCritical` (ADR-0026), and the number of redemptions actually blocked | share; count |

M8 and M9 are not in blueprint §14.2: M8 because shutdown is a terminal state that changes how
every other metric must be read, M9 because the P02 gate added the gate that makes the peg floor
conditional. Neither carries a hypothesis.

### 4.3 Per-run consistency checks

A run is **invalid** (and excluded, §8) if any of these fail at `T_run`:

1. The protocol invariants I1, I2 and the bucket inequalities (P03) hold at every step.
2. `value_given_away` decomposition sums to its total within 1 wei per event.
3. `total_system_cost` equals the sum of its three terms exactly.
4. The simulation consumed the whole path, or stopped at settlement with a recorded reason.

### 4.4 Required run output

Every metric above is computable from this schema; nothing else is needed, and P29 fails if a
field is missing. Each result row carries, in addition to the metrics: config hash, scenario,
variant, parameter cell, run index, seed, git commit, data-card checksums, environment, path
classification (§3.3), wall time, and `pilot: bool` (experiments skill).

| Group | Fields |
|---|---|
| Event log | every protocol event of `docs/spec.md` §11.1 with its block timestamp, plus the oracle price in force |
| Position series | per position: open and close time, close reason, collateral, debt and ICR at every state change and every oracle update |
| System series | `systemDebt`, `systemColl`, TCR, `index`, pool `totalDeposits`, auction lots, ledger `reserve`/`deficit`, sampled at every oracle update and every state change |
| Environment series | price, gas price (L2 execution + L1 data fee), liquidity depth, sequencer status |
| Agent actions | agent id, action, time, and the intent that produced it (for the liquidator: when it saw the opportunity and when it acted) |

---

## 5. Risk appetite

Risk appetite **R** is stated as a rate of bad-debt events (M2):

> R = at most **`R = TBD-P30`** bad-debt events per position-year, at the 95% upper bootstrap
> bound, in the scenario set `{S1, S2, S4, S5}` at the base parameter cell.

Candidate values, to be fixed at P30: **0.1%**, 0.5%, 1.0% per position-year. The blueprint's
appendix E proposes 0.1%; the pilot runs (§9) will show whether that rate is estimable with the
planned number of replications, and if it is not, P30 either raises R or raises N — never the
other way round after results are seen.

Q1's answer is the smallest MCR on the grid whose 95% upper bound on M2 is at or below R, reported
separately per deployment and per gas regime, with the decomposition of blueprint §10.4.

---

## 6. Analysis plan

### 6.1 Estimator

For each (scenario, variant, cell) the point estimate of a metric is the **median** over runs.
Comparisons are of medians, never of means: the outcome distributions are heavy-tailed, since most
runs produce no bad debt at all.

### 6.2 Uncertainty

95% intervals come from a **moving-block bootstrap** over the price-path blocks that generated the
runs, `B_boot = 10_000` resamples, block length `L_block` as in §3.3, percentile intervals. The
bootstrap resamples paths, not steps: steps inside one run are not independent (ADR-0013). For
paired comparisons (A against B at the same cell and seed) the bootstrap resamples the **pairs**,
so the price path is common to both arms and the comparison is within-path.

### 6.3 Replications

`N = TBD-P30` runs per (scenario, variant, cell), identical across cells, fixed before the sweep.
Candidates: 200, 500, 1000. P30 picks the largest N whose total runtime, extrapolated from the
pilot (§9), fits the compute budget, subject to a minimum of 200. Seeds are
`seed = hash(config_hash, scenario, variant, run_index)`, so A and B see the same paths.

### 6.4 Agreement between environments

A verification subset of `TBD-P30` cells (candidate: 5% of cells, at least one per scenario) is
re-run in `fork_replay`. The model and the fork **agree** on a metric if the fork value lies
inside the model's 95% interval for that cell. Agreement below `TBD-P30` (candidate: 90% of
checked cells) is reported as a limitation of every model-only result, not silently corrected.
This is a different thing from the differential test, which is exact and has no tolerance
(ADR-0022).

### 6.5 How ties are decided

There are three outcomes, not two. If an interval includes 0, the result is **"no detected
difference"** — not a tie in favour of either mechanism, and not evidence of equivalence. The
report states the interval and the smallest difference the design could have detected, estimated
from the pilot. A hypothesis whose interval includes 0 is neither confirmed nor refuted, and the
report says which of the two it leans toward only by showing the interval.

Where a parameter must nonetheless be chosen (Q1), ties are broken by a pre-stated order:
(1) lower 95% upper bound on M2; (2) lower median total system cost; (3) the more conservative
parameter, i.e. the higher MCR.

---

## 7. Parameter grid outline

The grid is outlined here and fixed at P30, when P07–P09 and P24–P25 have supplied the measured
ranges. Cells are the Cartesian product within a scenario, pruned by the constraints of
`docs/spec.md` §3.3; the sweep runner refuses a cell that violates one.

| Parameter | Grid (draft) | Applies to | Fixed by |
|---|---|---|---|
| `MCR` | 110%–200% in 5 pp steps | A, B | Q1 |
| `LIQUIDATION_PENALTY` | 2.5%, 5%, 7.5%, 10% | A, B (equal in a pair) | P27 |
| `MIN_DEBT` | 500, 2 000, 5 000 | A, B | P09/P24 |
| `GAS_RESERVE` | derived per gas regime from P24, 3 levels | A, B | P24 |
| `POOL_SHARE_BPS` | 5 000, 7 500, 10 000 | A only | — |
| `AUCTION_HALF_LIFE` | 300 s, 600 s, 1 200 s | B only | P33 |
| `BUFFER` | 1.10, 1.20, 1.30 | B only | P33 |
| `TAIL`, `CUSP` | 3 600/7 200 s × 0.30/0.40 | B only | P33 |
| `STALENESS`, `GRACE_PERIOD` | 1 800, 3 600, 7 200 s | A, B | P07 (S6, S7) |
| `CRITICAL_TCR` | 1.00, 1.05, 1.10 | A, B | S6 |
| `DEFICIT_LIMIT_BPS` | 250, 500, 1 000 | A, B | S6 |
| `ORACLE_FAILURE_DURATION` | 1, 2, 4 days | A, B | S6 |
| `REPAYMENT_WINDOW` | 3, 7, 14 days | A, B | S6 |
| Depth scaling (S8) | 1.0, 0.5, 0.25, 0.1 | A, B | P25, H3 |
| Depositor sensitivity (S9) | base, high, extreme | A only | P26 |

`ANNUAL_RATE` is held at 5% for the comparison and varied only in a separate robustness cell;
varying it changes borrower behaviour as well as protocol cost, which would confound Q2.

---

## 8. Exclusion rules

Stated in advance; every exclusion is counted and reported, and the counts appear in the report
whether or not they are flattering.

1. **Invalid runs** (§4.3 checks fail): excluded, and the run is a **defect report**, not a data
   point. If more than `1%` of a cell's runs are invalid, the whole cell is reported as invalid and
   no estimate is published for it.
2. **Simulator errors** (exception, timeout, non-termination): excluded and counted; same 1% cell
   rule.
3. **Paths outside the oracle's representable range** (`price ∉ [MIN_PRICE, MAX_PRICE]`): excluded
   at path-generation time, before any run, so they cannot be selected on their outcome.
4. **Pilot runs**: excluded from every inferential result by the `pilot` flag (§9).
5. **Runs that shut down are *not* excluded.** Shutdown is an outcome, recorded in M8; dropping
   those runs would remove exactly the tail the study is about.
6. **No exclusion may reference an outcome value.** A rule that drops runs because their bad debt
   is large is not an exclusion rule, it is a result.

---

## 9. Pilot runs

Before the freeze, only pilot runs on **S1** are permitted, for runtime estimation and schema
shake-out (experiments skill). They are labelled `pilot: true`, stored in the ordinary results
tree, and excluded from every estimate. What the pilot may decide: `N` (§6.3), the compute budget
split across scenarios, and whether R is estimable at the planned N. What the pilot may **not**
decide: any threshold in §2, the metric definitions, or the exclusion rules.

If a pilot reveals that a hypothesis cannot be tested at the planned N — for instance, if bad-debt
events are too rare to estimate M2 at R = 0.1% — the preregistration says so **before** the
freeze, and P30 either raises N, widens R, or states that H1 is underpowered and reports it as
such. It does not quietly change the hypothesis.

---

## 10. What counts as confirmation and refutation

- **Confirmed**: the direction in §2 holds and the 95% interval excludes 0, after Holm correction.
- **Refuted**: the opposite direction holds and the interval excludes 0, after correction.
- **No detected difference**: the interval includes 0. Reported with the interval and the
  detectable effect size; never written as "the mechanisms are equivalent".
- **Underpowered**: the cell has fewer than N valid runs, or the pilot showed the effect is not
  estimable. Reported as such, with no directional claim.

A refuted hypothesis is reported in the same detail as a confirmed one, in the same section of the
report, and the abstract states it (blueprint §14.3: "with failures"). No hypothesis is removed,
reworded or re-tested on different data after results are seen; the only permitted change is a
dated addendum in §11 that says what changed, why, and what it does to the conclusions.

---

## 11. Addenda

Empty at the freeze. Every later entry: date, what changed, why, and the effect on the
conclusions.

| date | change | reason | effect on conclusions |
|---|---|---|---|
