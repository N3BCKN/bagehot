# Fuzzing and invariant campaigns

Baselines for the stateful campaigns over the whole system. P13's list-only campaign and P15/P16's
focused campaigns are recorded in `docs/progress.md`. Re-run these after any contract change and
compare them with the figures below. A drop in calls/s or in reach (regimes, successful actions)
needs an explanation, just as a gas change does.

## Harness

`contracts/test/invariant/handlers/CoreHandler.sol` deploys the full system — deployment A
(stability pool) or B (Dutch auction) — with `CountingOracle`, a pass-through that counts
`fetchPrice` calls, in front of the oracle adapter. It seeds four positions.

**Actions:**
- `open`, `addCollateral`, `withdrawCollateral`, `borrow`, `repay`, `close`;
- `redeem` (exact, stale and dust hints), `redeemAcrossTail`;
- `warp`, `movePrice` (±30 %), `toggleOracle` (healthy, or one of the nine unusable reasons);
- `donate`, `togglePoolDeposits`;
- `redistribute`, a test-only stand-in for liquidation (see "Stand-ins");
- rare `triggerShutdown` / `settle`, and `reclaimGasReserve`.

The handler checks I9 inside the rescue actions. Every protocol call in an action is caught and
classified, and an unexpected revert increments a counter that `noUnexpectedReverts` asserts is
zero. A redemption refusal counts as expected only when the state before the call justifies it:
- `TCRBelowCritical` only if the gate was below critical;
- `NothingRedeemed` only if every node the loop can visit is below MCR, or the first one that is not
  is a legitimately cancelled partial;
- `SystemShutdown` only if shut down.

`CoreInvariants*` run with `fail-on-revert = true` (inline config, default and nightly profiles), so a
revert that escapes an action fails the campaign instead of silently dropping the call.

**Gating** (so every run reaches what CHG-005 and the reach checks require; no state is made
unreachable — another action first reaches the same states):
- the first `redistribute` waits for one exact step after an action;
- in A, `triggerShutdown` waits for the tolerance regime.

**Known limits:**
- The harness emits `HarnessRedistributed` where the real liquidation will emit `Redistributed`;
  I13's `m` is counted from the harness event until P20.
- `donatedToken[VaultManager]` is tracked but unchecked: I1's formula has no stablecoin row for the
  VaultManager.
- A redemption cannot be required in every run, because a price path below the critical TCR refuses
  every one legitimately. Dead or wrongly refused redemptions are caught by the classification
  above (mutants M14 and M15).

**Checked after every call** (`contracts/test/invariant/CoreInvariants.t.sol`, A = `CoreInvariantsTest`,
B = `CoreInvariantsBTest`):

| invariant | function |
|---|---|
| I1 holders (VaultManager, RedemptionModule) | `invariant_I1_holderBalances` |
| I1 supporting sums | `invariant_I1_supportingSums` |
| I2 | `invariant_I2_supplyDriftBound` |
| I5 | `invariant_I5_redemptionLeavesHealthyPositions` |
| I8 | `invariant_I8_noRoundingDeficit` |
| I9 | `invariant_I9_rescuePathsLive` |
| I11 | `invariant_I11_parametersImmutable` |
| I12 | `invariant_I12_noOperationOnUnusablePrice` |
| I13: CHG-005 exact regime; CHG-008 bound (approved text) and CHG-009 hidden-key bound with its exact key, insertion and stake checks (proposed) | `invariant_I13_sortedByNicrWithinTolerance` |
| handler state rebuilt from events matches the state | `invariant_stateReconstructionMatchesEvents` |
| no unexpected revert | `invariant_noUnexpectedReverts` |

`afterInvariant` requires, in every run of 100 calls or more:
- both I13 regimes, the exact one counted only after an action with at least two members (the
  tolerance regime in A only; B never redistributes);
- in A, at least one successful redistribution. It then unwinds the system — repay and close everything, or
reclaim once settled — and checks I8 at the end.

**Medusa:** `contracts/test/invariant/medusa/CoreProperties.sol` runs the same handler (deployment A)
with ten `property_*` wrappers. Medusa has no `recordLogs`, so the counters that Foundry takes from
events are rebuilt from state; Foundry cross-checks that reconstruction against the events.

**Stand-ins to re-validate** (carry-forward P17-H1, P17-H2):
- `VaultManagerHarness.redistribute` stands in for P20's real liquidation;
- the direct `onShutdown` / `onSettlement` calls stand in for the real ShutdownModule.

## Commands

| command | what it runs |
|---|---|
| `just test` | default profile: 256 runs × 200 calls per invariant contract |
| `just test-nightly` | `FOUNDRY_PROFILE=nightly`: 4,096 runs × 500 calls, every `test/invariant/*` |
| `just medusa` | `contracts/medusa.json`: 8 workers, 1,800 s, sequences of 100 calls, corpus in `contracts/medusa-corpus/` (git-ignored) |

`just medusa` first runs `just crytic-compile-check`. It fails unless the crytic-compile on Medusa's
PATH, slither-analyzer's tool environment, is exactly 0.4.2 (`docs/dependencies.md`); CI runs the
same check.

## Baselines (2026-10-25, macOS arm64, Medusa 1.5.1, Foundry as pinned)

All figures below are for the final harness, after the review's fixes. The first baselines, taken
before those fixes (Medusa ≈ 1,270 calls/s), are superseded.

### Foundry, default profile, 8 seeds (`--fuzz-seed 1..8`), deployment A

| | per seed |
|---|---|
| runs × calls | 256 × 200 = 51,200 calls |
| unexpected reverts | 0 |
| result | every invariant passes on every seed (1–8), in A and in B |
| wall time | ~32 s per deployment alone; ~50 s with eight seeds in parallel |

### Foundry, nightly profile

`just test-nightly`, 4,096 runs × 500 calls = 2,048,000 calls per invariant contract, default seed,
all six suites in parallel (42 min wall time), with the CHG-009 checks. Every invariant passed, with
0 reverts.

| suite | wall time |
|---|---|
| `CoreInvariantsTest` (A), 11 invariants | 1,680 s |
| `CoreInvariantsBTest` (B), 11 invariants | 1,714 s |
| `VaultI2InvariantTest` (P15) | 2,538 s |
| `RedemptionInvariantTest` (P16) | 1,488 s |
| `SortedPositionsInvariantTest` (P13, list only) | 659 s |
| `I13CheckTest` | < 1 s |

### Medusa, 30 minutes

| | value |
|---|---|
| elapsed | 29 min 57 s (timeout 1,800 s) |
| calls | 2,511,988 |
| calls/s | **≈ 1,400 average** (≈ 1,040–1,600 instantaneous) |
| sequences | 25,207 |
| branches covered | 4,521 |
| corpus | 82 sequences |
| result | 10/10 properties passed, 0 failures |

Medusa has no `afterInvariant`, so reach is read from its lcov report
(`contracts/medusa-corpus/coverage/lcov.info`, hits on `CoreHandler` lines). A drop to zero on any of
these means the campaign stopped exercising that path:

| path | hits |
|---|---|
| `redistribute` call | 115,476 |
| successful redemption | 88,451 |
| inferred partial (I5) | 86,538 |
| last-visit reason check (CHG-007) | 84 |
| `onShutdown` call | 12,106 |
| `onSettlement` call | 5,013 |
| `reclaimGasReserve` call | 4,400 |

**The last-visit check is rare and varies between campaigns:** 84 here, 9,865 in the previous
baseline. It needs a redemption that leaves stablecoin over, has no partial, and stops before
`maxIterations`. In this run 1,913 calls left stablecoin over, and all but 84 of them had used up
their iterations. The path is also pinned deterministically by
`test_regression_I5_lastVisitReason`.

The handler's measurements for this file (`_measureK`, `_measureSlack`) run in Foundry only. Under
Medusa's 12.5M transaction gas limit their per-pair calls dropped long-list actions: 1,038 calls/s
and 73,028 redemptions before they were gated, 1,400 calls/s and 88,451 after.

### I13 hidden-key tolerance in deployment A (CHG-009)

Measured on 2026-10-25 with the final, exact handler, deployment A, 8 seeds × 256 runs × 200 calls;
every run recorded through a temporary probe, removed afterwards. Each run also logs its own figures
from `afterInvariant` (`forge test -vv`).

| | value |
|---|---|
| violations of the pair condition, the key identity, insertion exactness or the stake rule | 0 |
| insertions that inherited a non-zero allowance ι | 4,764, in 1,055 of 2,056 runs |
| largest single ι at insertion, relative to its key | 1.3·10⁻² |

Per-pair tolerance on the observed keys, relative to the NICR, against CHG-008's on the same pairs,
by the smallest stake the run reached:

| smallest stake in the run | runs | hidden-key | CHG-008 |
|---|---|---|---|
| below 1,000 wei | 27 | 4.4·10⁻³ | 4.8·10⁻¹ |
| 10³ – 10⁵ | 21 | 1.5·10⁻⁶ | 1.3·10⁻³ |
| 10⁵ – 10⁹ | 95 | 2.0·10⁻⁶ | 6.5·10⁻⁶ |
| 10⁹ – 10¹³ | 289 | 3.4·10⁻¹¹ | 6.8·10⁻¹⁰ |
| 10¹³ and more | 1,624 | 1.7·10⁻¹⁴ | 6.4·10⁻¹⁴ |

These are observations, not a bound: no a-priori limit exists, and the tolerance is vacuous in
reachable zero-stake states (CHG-009). The §6.5.4 reset branch is not reachable through this harness.
Model search behind the counterexample: `python3 scripts/analysis/i13_bound_search.py`.

### CHG-008's tolerance (superseded by CHG-009, 2026-10-26)

Measured on 2026-10-24, before the review's harness fixes (which do not change what
`redistribute` does), over 8 seeds × 256 runs × 200 calls, every list member after every step. The derived
bound held throughout. The largest tolerance it granted, relative to the member's own key, by the
member's stake:

| stake (wei) | member-steps | largest relative tolerance |
|---|---|---|
| 0 | 763 | 2.7 |
| 1 – 9 | 365 | 0.99 |
| 10 – 99 | 461 | 6.4·10⁻² |
| 100 – 999 | 346 | 9.1·10⁻³ |
| 10³ – 10⁴ | 281 | 5.7·10⁻⁴ |
| 10⁶ – 10⁷ | 1,481 | 8.8·10⁻⁷ |
| 10¹² – 10¹³ | 5,566 | 9.2·10⁻¹³ |
| 10¹⁷ – 10¹⁸ | 31,690 | 9.0·10⁻¹⁸ |
| ≥ 10¹⁸ | 325,441 | 3.0·10⁻¹⁸ |

The same campaign reached `totalStakes == 0` with a non-empty list in 18 runs, 432 steps (P17-1).

How these were measured: a temporary probe in the handler bucketed `max(kc/c, kn/n)` by stake decade
and appended one line per run to a scratch file; it was removed afterwards. Each run also logs its own
largest tolerance and smallest stake from `afterInvariant` (`forge test -vv`). Re-measure after P20
(P17-H1) and after any P17-1 change.

## Failures found and fixed

Each failure became a regression test in `contracts/test/unit/regressions/CoreHandlerRegressions.t.sol`
that fails before its fix.

| test | seed, invariant | cause | fix |
|---|---|---|---|
| `test_regression_noUnexpectedReverts_threeRedemptions` | 1, `noUnexpectedReverts` | handler: a dust redemption could exceed the redeemer's balance | dust amount capped at the balance |
| `test_regression_eventsAgree_warpThenRedeemAcrossTail` | 1, events | handler: accrual events emitted outside a recorded call were missed | logs recorded from the start of every action |
| `test_regression_I5_lastVisitReason` | 1, I5 | handler: a 1-wei partial at index > RAY changes no stored field | the partial is inferred from the burned amount |
| `test_regression_eventsAgree_reclaimCountsLikeItsEvent` | 2, events | handler: `reclaimGasReserve` emits `OP_CLOSE`, which went uncounted | counted |
| `test_regression_eventsAgree_withdrawAfterWarp` | 1, events | handler: Foundry records events of calls that later revert | recorded logs discarded on every caught revert |
| `test_regression_I13_toleranceAfterRedistributions` | 3, I13 | **spec**: `k = 4` exceeded (needed ≈ 8,125) | CHG-008, a derived per-member bound (ADR-0034) |
| `test_regression_I13_derivedBound_stakeCollapse` | 1, I13 | **spec**: the proposed 10⁻⁹ slack ceiling fails under stake collapse | ceiling withdrawn; weak regime stated; P17-1 opened |
| `I13BoundCounterexampleTest` (unit, deterministic) | — , I13 | **spec**: CHG-008's bound is broken by a correct VaultManager on a protocol-valid sequence (review F3) | CHG-009, the hidden-key bound (proposed) |

No contract bug was found. Every failure was a handler bug or a spec problem routed through `/spec-change`. The counterexample test is not a shrunk campaign failure: the campaign never produced the shape, and an exact-arithmetic model search found it.

Related unit tests:
- `RescuePathsUnusableOracle.t.sol` (I9 ∩ I12): repay, add-collateral and close succeed with no
  oracle read, and price-gated operations revert `PriceUnusable`, under each of the nine
  unusable-oracle reasons, in A and B. The rescue paths are checked again in the shutdown window. A
  mutation that adds an oracle read to `repay` is caught.
- `CoreHandlerPhases.t.sol`: the rare phase actions deterministically reach the window, the settled
  phase and a reclaim, in A and B. Also `test_regression_redeemAfterSettlement_noEscapingRevert`
  (seed 1, B): a handler-side panic in the settled phase, found once `fail-on-revert` was on.

## Review mutants (P17 security review)

Contract or harness lines broken on purpose, one at a time, each against the regression tests and
the default-profile campaign of A and B, then restored:

| mutant | break | caught by |
|---|---|---|
| M11 | `onShutdown` always reverts | `CoreHandlerPhases` (both); `noUnexpectedReverts` and the event reconstruction, A and B |
| M12 | `onSettlement` always reverts | `CoreHandlerPhases` (both); `noUnexpectedReverts`, A and B |
| M13 | harness `redistribute` reverts when the position has pending rewards | both I13 regressions; `noUnexpectedReverts`, A (B never redistributes) |
| M14 | `redeem` always reverts `TCRBelowCritical` | three regressions; `noUnexpectedReverts`, A and B |
| M15 | the redemption loop never redeems | three regressions; `noUnexpectedReverts`, A and B |
| M7 | `_computeStake` ignores the snapshot (stake = collateral) | I13 condition 3 (stake at insertion), seed 1; the counterexample regression's model state |
| — | `sortKey` returns stored instead of effective values | I13 condition 1 (key identity), seed 1; the counterexample regression's model state |

Before the review's fixes, M11–M15 passed the entire P17 suite and Medusa. M7 was caught before only by CHG-008's slack, at the default campaign size; the last two rows are checked against the CHG-009 conditions.

The campaign size matters: the reviewer's mutant M7 (a stake that ignores the snapshot) survives
32 runs × 150 calls and is caught at 256 × 200. PR CI must not run fewer than the default profile.

## P19: stability pool (product–sum)

### Precision study (`model/tools/sp_precision.py`, 2026-10-26)

200 sequences × 300 steps (seed 19; four regimes: mixed sizes, `T ≈ 10^30`, small pools, and the
adversarial "large carry, empty, come back small" case of I3). Each sequence runs the integer model
(bit-for-bit with the contract: 8 of the sequences, 2,400 steps, are replayed against it by
`StabilityPoolPrecisionTest` with every state field and every depositor's views equal) alongside the
exact `Fraction` pro-rata reference of `model/invariants.py`, reset at every snapshot as I3 defines
it. Largest error per depositor over all 60,000 steps:

| quantity | largest error | I3 bound |
|---|---|---|
| compounded deposit, `exact − integer` (never negative) | 514 wei | holds everywhere |
| collateral gain, `|exact − integer|` | 3.9·10^12 wei (at `T ≈ 10^30`; §6.6.7 reports 1.6·10^12) | holds everywhere |
| interest gain, `|exact − integer|` | 2.1·10^13 wei | **broken in 170 steps** — see CHG-010 |

Every interest violation is a gain booked while `currentScale > snapScale + SCALE_SPAN`, which
§6.6.7 deliberately ignores; the unpaid part stays in `interestGainsBalance` as dust, so the totals
stay exact. With the term CHG-010 proposes, 0 violations. I3's integer inequalities and U4 held at
every step.

### Pool invariant campaign (`StabilityPoolInvariantsTest`, default profile)

256 runs × 200 calls over the real pool behind the test VaultManager (deposits at four size caps,
partial and full withdrawals, claims, offsets — random, exactly `T`, `T − 1`, near-emptying —
interest, liquidations through `onLiquidation`, donations): I1 (pool row), I3's inequalities and
`P` range, the withdraw-entitlement and empty-epoch clauses, U4 and no unexpected revert — all
green. Epoch changes, scale changes and dust sweeps (residuals that reached the ledger) are logged at
the end of every run, not asserted per run; the scale-change edge cases are pinned deterministically
by the unit tests and the precision replay. The I8 unwind of the core campaign exits every depositor
(claim, then withdraw everything) and checks the pool keeps only its named residual. In the core campaign
(deployment A) the real pool replaces the mock, with deposit, withdraw and claim actions and the
same checks (`invariant_I3_poolSolvencyAndU4`, Medusa `property_I3_poolSolvency`).

### Pool hook gas (CHG-006)

Caller-gas sweeps of `accrue()` (coarse step 199 over 10k–400k, step 1 for ±600 around the first
limit that books): against the real pool, 3,161 probes, 1,732 booked and 1,429 reverted the whole
transaction; against a pool that burns 150k of the 200k cap, 1,073 booked and 2,088 reverted. Zero
redirections in both. A pool that reverts early when short of gas *is* redirectable
(`test_gasleftBranchingPool_canBeRedirected_theAssumptionMatters`), which is why spec §6.2 states that
`onInterest` never reads `gasleft()`.

