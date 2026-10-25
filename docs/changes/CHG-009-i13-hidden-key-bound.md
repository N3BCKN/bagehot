# CHG-009: CHG-008's I13 bound is unsound; replace it with an exact per-pair tolerance derived from hidden ideal keys

- Status: **proposed**, 2026-10-25. Replaces CHG-008's formula if approved. `docs/invariants.md`,
  ADR-0034 and the optional §6.3.3 sentence below wait for this decision.
- Raised: P17 security review F3 (open issue P17-2). The human asked for a re-derivation, not a
  relabel. An independent `spec-auditor` pass checked the derivation and implementation; its
  findings are folded in below.
- Affects: `docs/invariants.md` I13 (Statement, Formula, Derivation, Weak regime, Overflow,
  Validation, Checked in), its Summary row and its Open-items row; ADR-0034 (proposed, rewritten);
  optionally one sentence of spec §6.3.3. No contract, model or vector change.

## Problem

CHG-008 bounds each member's error by its own rounding since its last insertion
(`kc(p) = 1 + ⌈(ΔLColl + m + stake·m)/DP⌉`, and likewise `kn`). It then assumes the list is exactly
ordered by "exact keys" lying within those boxes. Both steps fail.

1. **The snapshot-ratio error (review F3).** The ratio `totalStakesSnapshot / totalCollateralSnapshot`
   (§6.5.4) is short of the members' common stake-per-collateral ratio. The shortfall is the
   accumulated carry remainders of §6.5.2 and the undistributed dust in `pendingColl`, relative to
   total collateral. A newcomer's stake inherits it in full. Relative to an older neighbour it can
   therefore be off by many stake units, which CHG-008 does not allow for. (§6.3.3's argument that
   "a liquidation's snapshot is Σ stake / Σ effColl" overlooks the same term.)
2. **The exact-key premise.** Insertions are decided against neighbours' *observed* keys, which have
   drifted. So the list need not be ordered by any exact keys taken from per-member error boxes. A
   sound bound has to carry what each insertion inherited from its neighbours.

## Evidence

**A correct VaultManager breaks CHG-008's bound**
(`I13BoundCounterexampleTest.test_chg008BoundBrokenByACorrectVaultManager_hiddenKeyBoundHolds`).

The sequence (every open at or above MCR and MIN_DEBT at an ETH price of 100,000):
1. member A and six other members;
2. ten small liquidations, each followed by every member except A re-applying (the dust);
3. one more liquidation, whose snapshot carries the dust;
4. B opens directly behind A;
5. one liquidation-sized remainder.

Each victim is checked to be a genuine deployment-A liquidation with an empty pool: at 50,000,
inside the oracle's bounds, its ICR is below MCR and below 1 + LIQUIDATION_PENALTY, so the pool
seizes, and the VaultManager redistributes, its whole collateral. Redistributed amounts do not depend
on the price.

CHG-008 grants `kc(A) = 4` and `kn(B) = 35,003`, but `(cA + 4)(nB + 35,003) < cB·nA`. The hidden-key
bound holds. The integer state asserted (`LColl`, `LDebt`, both keys and B's stake) is the one the
independent exact-integer model `scripts/analysis/i13_bound_search.py` predicts.

**Search** (`python3 scripts/analysis/i13_bound_search.py`, about one minute). The model asserts that
every open is valid and that every remainder in the grid is a full-collateral liquidation.

| family | scenarios | CHG-008 broken | hidden-key broken | largest share of CHG-008's tolerance used |
|---|---|---|---|---|
| random | 2,000 | 0 | 0 | 0.49 |
| dominant newcomer, debt-heavy remainders | 600 | 0 | 0 | 0.44 |
| protocol-valid deterministic grid (dust, then a newcomer, then remainders) | 64 | **34** | 0 | **61.8** |

The P17 campaign never produced the shape, which is why "not yet observed" was no evidence of
soundness.

## Derivation

**Hidden ideal keys.**
- Give every member an *ideal* stake on one common ratio: `s*_p = c_p·DP/(DP + L_p)`, with `c_p` its
  collateral and `L_p = snapLColl_p` at its last insertion. This is a choice of coordinates, not a
  claim about the real stakes. Any common ratio works, and this one equals the real ratio until the
  first liquidation.
- With the real accumulators, which every member shares, its hidden keys are
  `C*_p = c_p + s*_p (LColl − L_p)/DP` and `N*_p = n_p + s*_p (LDebt − D_p)/DP`, with
  `D_p = snapLDebt_p`.
- Then `C*_p / s*_p = (DP + LColl)/DP`, the same for every member, and
  `N*_p / s*_p = (h_p + LDebt)/DP` with

  ```
  h_p = n_p · (DP + L_p) / c_p − D_p          (fixed at p's insertion)
  hidden NICR_p = (DP + LColl) / (h_p + LDebt)
  ```

- So the hidden order is ascending `h`. It is invariant under every redistribution of any size, and
  it involves neither the real stakes nor any rounding of §6.5, nor the reset branch of §6.5.4.

**Observed keys in the same coordinates.** An observed key `(C, N)` corresponds to
`h_obs = N·(DP + LColl)/C − LDebt`. For a fixed `LColl, LDebt`, `h_obs` is an increasing function of
`N/C`, so ordering observed keys by NICR is ordering them by `h_obs`. Each member's current deviation
is `d_p = h_obs,p − h_p`, exactly computable.

**Insertion.** Insertion is exact against the keys it reads (§6.3.1; `SortedPositions` validates
`prev precedes p precedes next`). So when `p` is inserted between `X` (ahead) and `Y` (behind),
`h_obs,X ≤ h_p ≤ h_obs,Y` at that moment (`p` is fresh, so `h_obs,p = h_p`).

**Hidden order values exist.** By induction over insertions, there are values `Z` such that:
- the list is exactly ordered by `Z` at all times;
- `|Z_p − h_p| ≤ ι_p`, where

  ```
  ι_p = max(0,  ι_X + ⌈h_X − h_obs,X⌉,  ι_Y + ⌈h_obs,Y − h_Y⌉)        (fixed at p's insertion)
  ```

Proof: take `Z_p = clamp(h_p, Z_X, Z_Y)`; both sides cannot clamp at once, since `Z_X ≤ Z_Y`.
- If `h_p < Z_X`, the distance is at most `Z_X − h_obs,X ≤ ι_X + (h_X − h_obs,X)`.
- The case behind `Y` is symmetric.
- `Z` and `ι` never change afterwards, and removals keep the order. Neighbours removed later do not
  matter.

**The check, in observed keys.** For every adjacent pair `(A, B)`, with `A` nearer the head:

```
h_obs,A − h_obs,B   ≤   (d_A − d_B) + ι_A + ι_B
```

This is the same inequality as `h_A − ι_A ≤ h_B + ι_B`. A correct implementation never fails it,
since `Z_A ≤ Z_B`. The right-hand side is the pair's tolerance: exactly how far the two observed keys
can legitimately have crossed, given each one's drift since its insertion and what each inherited at
insertion. It is a derived per-pair tolerance on the effective-NICR order, as §6.3.3 asks, not a
constant.

**Exactness.**
- Every quantity is an exact rational, compared with 512-bit arithmetic.
- `ι` is rounded up to an integer once per insertion, and a neighbour whose observed key has not
  moved from its hidden one contributes exactly 0.
- No other slack exists.

**Exact companion conditions.** The pair condition holds whatever the stakes are, so three conditions
check the stakes and keys directly, with no tolerance:
1. **Key identity:** `sortKey` equals stored values plus floored pending (§6.5.3).
2. **Insertion order:** every insertion `precedes`-exact against both neighbours (§6.3.1).
3. **Stake:** every insertion's stake equals §6.5.4's `computeStake` against the current snapshots.

The CHG-005 exact regime is unchanged.

**What each part detects.**
- **Pair condition:** catches list-structure errors — a removal that relinks wrongly, or a reordering
  not made by an insertion. Drift between insertions cannot fail it. That is what makes it sound
  under stake collapse.
- **Condition 1:** catches a `sortKey` that does not follow §6.5.3 from the stored state. It does not
  check that the stored state itself is right: a wrong amount applied by `_applyPending`, for
  example, or snapshots not reset. Those are checked by I1's sums and the event reconstruction.
- **Condition 2:** checks that each insertion is locally exact. It does not check that the slot is the
  one §6.3.2's walk would choose among equally valid ones.
- **Condition 3:** catches a wrong stake at insertion, the review's mutant M7. CHG-008 caught M7 only
  at the default campaign size; this catches it deterministically.

**Measured over the full campaign** (deployment A, 8 seeds × 256 runs × 200 calls, every run
recorded):
- zero violations of the pair condition or of conditions 1–3;
- 4,764 insertions inherited a non-zero `ι`, in 1,055 of 2,056 runs;
- per-pair tolerance on the observed keys, against CHG-008's on the same pairs, as the largest
  relative value seen, by the smallest stake the run reached:

| smallest stake in the run | runs | hidden-key tolerance | CHG-008 tolerance |
|---|---|---|---|
| below 1,000 wei | 27 | 4.4·10⁻³ | 4.8·10⁻¹ |
| 10³ – 10⁵ wei | 21 | 1.5·10⁻⁶ | 1.3·10⁻³ |
| 10⁵ – 10⁹ wei | 95 | 2.0·10⁻⁶ | 6.5·10⁻⁶ |
| 10⁹ – 10¹³ wei | 289 | 3.4·10⁻¹¹ | 6.8·10⁻¹⁰ |
| 10¹³ wei and more | 1,624 | 1.7·10⁻¹⁴ | 6.4·10⁻¹⁴ |

Relative means: divided by `h_obs,B + LDebt` for the hidden-key bound, and `kc_A/c_A + kn_B/n_B` for
CHG-008, both of which are relative tolerances on the NICR. The largest single `ι` seen at insertion,
relative to its own key, was 1.3·10⁻².

**These are campaign observations, not a bound.** No a-priori limit on `ι` exists. A member whose
observed key stops following its hidden one inherits that gap onto the members later inserted next to
it. A zero-stake member is the clearest case: its key never moves while `LColl` and `LDebt` grow. The
gap can then reach the order of the key itself, at which point the tolerance for that pair is vacuous.

Worked example: a member at `n/c = 1000`, redistributions at `n/c = 3000`, `LColl` growing from 0 to
10²⁰. A newcomer inserted behind it inherits `ι` of about 200 % of its own key.

The §6.5.4 reset branch, where P17-1 (e) lives, is not reachable through the P17 harness. It is
measured only once P20's deficit path exists.

## Options

1. **The hidden-key per-pair tolerance with the three exact conditions** (recommended). It needs
   per-member history (`h`, `ι` recorded at insertion), as CHG-005's exactness already does.
2. **Patch CHG-008** with a snapshot-ratio term. Rejected: it still rests on the exact-key premise,
   and the term depends on history anyway (the accumulated dust).
3. **"Empirically validated" CHG-008.** Rejected: there is a counterexample.

## Exact wording to apply to `docs/invariants.md` (after approval and unlock)

The I13 Statement's first sentence, "Ties and the exact regime (CHG-005)", "Scope" and "Breaks if"
are unchanged.

### Summary table: replaces the I13 row

| I13 | The list is ordered by effective NICR within a per-pair tolerance derived exactly from each member's drift since insertion and what it inherited at insertion (hidden-key bound) | derived per pair (CHG-009) | both, all phases | §6.3 |

### I13, Statement: replaces the second sentence

Lazy redistribution moves effective keys between insertions. Each adjacent pair is held to the
tolerance that its two members' drift since insertion, and what each inherited at insertion, allow,
computed exactly against a hidden order that no redistribution can change.

### I13, Formula: replaces the paragraph and its code block

Every member `p` carries `h_p` and `ι_p`, fixed at its last insertion. At that moment its pending
rewards are applied, its stake is recomputed, and `c_p`, `n_p`, `L_p = snapLColl_p` and
`D_p = snapLDebt_p` are recorded. For every adjacent pair `(A, B)` in the list — `A` nearer the
head — with keys `(C, N)` from `sortKey`:

```
h_obs,A − h_obs,B   ≤   (d_A − d_B) + ι_A + ι_B          (equivalently  h_A − ι_A ≤ h_B + ι_B)

h_p      = n_p · (DECIMAL_PRECISION + L_p) / c_p − D_p
h_obs,q  = N_q · (DECIMAL_PRECISION + LColl) / C_q − LDebt          d_q = h_obs,q − h_q
ι_p      = max(0,  ι_X + ⌈h_X − h_obs,X⌉,  ι_Y + ⌈h_obs,Y − h_Y⌉)   X, Y: p's neighbours at its insertion
```

All values are exact rationals; a side with no neighbour contributes nothing. In addition, exactly:
1. `sortKey(q) = (c_q + ⌊s_q (LColl − L_q)/DP⌋, n_q + ⌊s_q (LDebt − D_q)/DP⌋)` for every member;
2. at every insertion, the predecessor `precedes` `p` and `p` `precedes` the successor (§6.3.1), by the
   keys read at that moment;
3. at every insertion, `s_p = computeStake(c_p)` against the current snapshots (§6.5.4).

### I13, Derivation of the form: replaces the paragraph

Give every member the ideal stake `s*_p = c_p·DP/(DP + L_p)` on one common ratio. This is a choice of
coordinates: any common ratio works, and this one equals the real ratio until the first liquidation.

With the real accumulators, which every member shares, its hidden keys are
`C* = c_p + s*_p(LColl − L_p)/DP` and `N* = n_p + s*_p(LDebt − D_p)/DP`. Then `C*/s* = (DP + LColl)/DP`
for every member and `N*/s* = (h_p + LDebt)/DP`, so the hidden NICR is `(DP + LColl)/(h_p + LDebt)`.
The hidden order — ascending `h` — is invariant under every redistribution, independent of the real
stakes, of every rounding in §6.5 and of the §6.5.4 reset.

An observed key maps to `h_obs`, which orders observed keys exactly as their NICR does. Insertion is
exact against observed keys, so `h_obs,X ≤ h_p ≤ h_obs,Y` for the new member's neighbours. Taking
`Z_p = clamp(h_p, Z_X, Z_Y)` by induction gives values that order the list exactly at all times, with
`|Z_p − h_p| ≤ ι_p`. Hence the pair condition, which a correct implementation never fails.

The bound does not depend on the stakes, so conditions 1–3 check them and the keys directly.
Condition 1 checks `sortKey` against the stored state, not the stored state itself (I1 and the event
reconstruction cover that). Condition 2 checks local exactness, not which of several valid slots was
chosen.

### I13, Weak regime: replaces CHG-008's paragraph and table

The tolerance grows with the drift between members' observed and hidden keys, carried into `ι` at
insertion. It is small while every member's stake follows the common ratio, and large once stakes
collapse (P17-1). There is no a-priori limit. A member whose key stops following the common ratio —
most clearly a zero-stake member, whose key never moves while the accumulators grow — can pass a gap
of the order of a key onto members later inserted next to it, and the tolerance for those pairs is
then vacuous.

Observed in the P17 campaign (deployment A, 8 seeds × 256 runs × 200 calls), the largest per-pair
tolerance relative to the NICR, by the smallest stake the run reached:

| smallest stake in the run | largest tolerance |
|---|---|
| below 1,000 wei | 4.4·10⁻³ |
| 10³ – 10⁹ wei | 2.0·10⁻⁶ |
| 10⁹ – 10¹³ wei | 3.4·10⁻¹¹ |
| 10¹³ wei and more | 1.7·10⁻¹⁴ |

On the same pairs CHG-008 granted up to 0.48. The §6.5.4 reset branch is not reachable through the
P17 harness and is measured from P20 on. Conditions 1–3 have no tolerance in any regime. Any change
to the collapse itself belongs to P17-1.

### I13, Overflow: replaces the paragraph

`h` and `h_obs` are exact rationals `x·y/den − off`, with `x·y` formed by full-width `mulDiv` and
`mulmod` (512-bit intermediate), so `n·(DP + L)` never overflows. Differences are taken exactly:
integer parts in `int256`, and fractional parts compared on 512-bit cross products. `h ≤ n·(DP + L)/c`
is bounded by the supply cap times `(DP + LColl)` over one wei of collateral, far below `2²⁵⁵` for
any realistic accumulator.

### I13, Validation: replaces CHG-008's paragraph

The constant `k = 4` used until P17 was exceeded in deployment A (`k ≈ 8,125`;
`CoreHandlerRegressionsTest.test_regression_I13_toleranceAfterRedistributions`).

CHG-008's per-member bound replaced it. The P17 review then found that its derivation omitted the
snapshot-ratio error, and a correct VaultManager breaks it on a protocol-valid sequence
(`I13BoundCounterexampleTest`; search in `scripts/analysis/i13_bound_search.py`).

The hidden-key bound (CHG-009) holds on both sequences, on
`test_regression_I13_derivedBound_stakeCollapse`, and on every pair after every step of the campaign.

The list-only harness `SortedPositionsInvariant` (mock keys, P13) and the Python list-model test
model drift directly — at most 4 wei per key change — and keep that constant.

### I13, Checked in: replaces the Foundry clause, which ends at "Medusa `property_I13_sortedOrder`;"

Foundry `invariant_I13_sortedByNicrWithinTolerance` over the core handler: `h` and `ι` recorded at
every insertion; conditions 1–3 and the pair condition checked in one walk (O(size)); every run of
deployment A must reach both the exact and the tolerance-only regime; the largest tolerance reported.
Also: the CHG-005 regression test above, the CHG-008 and CHG-009 regression tests, P13's list-only
campaign `SortedPositionsInvariant` with its synthetic drift, and Medusa `property_I13_sortedOrder`.

The text after that clause — the Python and differential mentions — is unchanged. The Python
`model.invariants.check_I13` it names does not exist yet; it arrives with the model's I13 work.

### Open items: replaces the "I13 weak regime" row

| I13 weak regime | CHG-009's per-pair tolerance is exact and sound but has no a-priori limit: drift carried into `ι` at insertion grows with stake collapse (observed up to 4.4·10⁻³ of the NICR; vacuous in reachable zero-stake states). Measure again with P20's real liquidation and after any P17-1 change. | this file, I13; `docs/progress.md` P17-1, P17-H1 |

## Optional spec text (§6.3.3, protected; for the human to decide)

After "…and the property holds only approximately; two positions with almost equal NICR can swap.",
add:

> The snapshot itself is only approximately the common ratio: `totalCollateralSnapshot` includes the
> carry remainders and undistributed dust in `pendingColl`, so a position staked after a snapshot can
> differ from older ones by more than one unit of stake. Under stake collapse the swaps are no longer
> limited to near-equal NICRs; I13 (CHG-009) derives the tolerance per pair.

## Impact

- **`docs/invariants.md`:** I13, its Summary row and its Open-items row, as above.
- **Spec §6.3.3:** optional sentence above.
- **ADR-0034 (proposed):** rewritten to this decision; it supersedes nothing that was accepted.
- **CHG-008:** its formula is superseded; its problem statement (`k = 4` exceeded) stands.
- **Tests:**
  - `CoreHandler` already checks the pair condition and conditions 1–3, alongside CHG-008's check;
    CHG-008's check is removed once this is approved.
  - New `test/utils/I13HiddenKeys.sol`, the counterexample regression, and
    `scripts/analysis/i13_bound_search.py`.
- **No contract, model, vector or experiment change.**
- **P20:** the real liquidation re-runs this check, including the §6.5.4 reset branch (P17-H1).
