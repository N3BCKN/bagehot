# CHG-008: I13's constant k = 4 is exceeded after repeated redistributions; replace it with a derived per-member bound

- Status: **approved 2026-10-24 (option 1, without the slack ceiling first proposed); applied to
  `docs/invariants.md` I13 on 2026-10-24. Its formula is unsound — a correct VaultManager breaks it
  (`I13BoundCounterexampleTest`) — and CHG-009 replaced it on 2026-10-26.** The problem statement below
  (`k = 4` exceeded) stands.
- Raised: 2026-10-24, P17 (the core invariant campaign, deployment A)
- Affects: `docs/invariants.md` I13 ("Formula", "Derivation of the form", "The constant k = 4 is
  calibrated, not proven", "Checked in"); possibly one sentence of spec §6.3.3. No contract, vector or
  model change.

## Problem

I13 holds adjacent list members to `cA·nB + k(cA + nB) + k² ≥ cB·nA` with a constant `k = 4` wei,
"calibrated, not proven". I13 itself says the constant has no bound "when a large liquidation meets
a small `totalStakes`", and instructs P17 to re-validate it against the campaign and to escalate
through `/spec-change` if the campaign exceeds it — never to raise `k`.

The P17 campaign (deployment A, the test-only `redistribute` harness approved for P17, which
implements §6.5.2 exactly) exceeds it on 3 of 8 seeds.

## Evidence

Regression `CoreHandlerRegressionsTest.test_regression_I13_toleranceAfterRedistributions` (seed 3,
18 calls): repeated whole-position redistributions, then opens staked against the snapshots, then
one more redistribution. State at the failure:

| | value |
|---|---|
| `totalStakesSnapshot` / `totalCollateralSnapshot` | 5.44·10¹⁴ / 1.47·10²⁰ (stake per unit of collateral ≈ 3.7·10⁻⁶) |
| `LColl` | 2.70·10²³ per unit stake (× DP) |
| pair (14 ahead of 15) | `cA = 5.073·10¹⁸, nA = 3.282·10²¹, cB = 7.103·10¹⁹, nB = 4.595·10²²` |
| inversion `cB·nA − cA·nB` | 3.73·10²⁶ (relative 1.6·10⁻¹⁵) |
| smallest `k` that would pass | **≈ 8,125 wei** |

The contract follows the spec. In exact arithmetic snapshot-corrected stakes preserve the order
(every member receives the same reward per unit of effective collateral). The inversion is
rounding, amplified exactly as I13 warns: a stake floored by 1 (R10) loses `ΔL / DP` of every later
reward, and `ΔL / DP` reaches 2.7·10⁵ wei here.

## Derivation of a sound per-member bound

For a member `p`, since its last insertion (the moment its pending rewards were applied, its stake
recomputed and its key recorded — every reinsert does all three), let `ΔLColl = LColl − snapLColl(p)`,
`ΔLDebt = LDebt − snapLDebt(p)`, and `m` = the number of redistributions since then. Its observed
key falls short of the exact one by:

- the pending floor: `pending = ⌊stake · ΔL / DP⌋` loses less than 1 wei;
- the stake floor (R10): `stake ≥ stake* − 1`, which loses less than `ΔL* / DP`, with
  `ΔL* < ΔL + m` the unfloored accumulator;
- the redistribution floors: each `dL = ⌊num / totalStakes⌋` loses less than 1 L-unit, which is
  less than `stake · m / DP` over `m` redistributions (the carry can only reduce this).

So

```
δc(p) < kc(p) = 1 + ⌈(ΔLColl + m + stake·m) / DP⌉
δn(p) < kn(p) = 1 + ⌈(ΔLDebt + m + stake·m) / DP⌉
```

and the pair condition, by the same argument as today (an exact order must survive adding each
member's admissible error), becomes

```
(cA + kc(A)) · (nB + kn(B))  ≥  cB · nA
```

**Validation:** measured in the handler on every adjacent pair after every step:
- 8 seeds × 256 runs × 200 calls, deployment A: **zero violations**, including the three seeds where
  `k = 4` fails;
- the regression sequence above passes it.

**Strictness:** for a member with no redistribution since its insertion, `kc = kn = 1`, which is
stricter than today's 4. Such a member is exact anyway. The bound grows only with the drift a member
can actually have, so a gross inversion between undrifted members is still rejected. While stakes are
large the terms are wei to thousands of wei against keys of 10¹⁸–10²². **Once stakes collapse the
bound is weak** — a relative tolerance of up to about `1/stake` — see the appendix and P17-1.

## Options

1. **Derived per-member bound** (recommended), as above.
   - `m` is counted from events: `Redistributed` events since the member's last `PositionUpdated`.
   - `ΔL` and `stake` are read from state.
   - The exact regime (CHG-005) is unchanged.
2. **Raise the constant** to cover the campaign. Rejected: I13 forbids it, and no constant is sound,
   since the drift scales with `ΔL/DP`.
3. **Exclude deployment A's redistribution regime from I13.** Rejected: it is the regime I13 exists
   to cover.

## Impact

- **`docs/invariants.md` I13:**
  - "Formula": the per-member `kc`, `kn`.
  - "Derivation of the form": the three error terms above.
  - Replace "The constant k = 4 is calibrated, not proven" with this derivation and its validation.
  - "Checked in": add the regression test.
- **Spec §6.3.3:** a sentence may be needed to name the stake-floor term. I will show the exact text
  if so.
- **Tests:**
  - `CoreInvariants` asserts the derived bound; the counter-only measurement becomes the check.
  - P13's `SortedPositionsInvariant` (mock keys, synthetic drift of at most 4 per key change) keeps
    its constant: its drift is bounded by construction, which the reworded text states.
- **No contract, model or vector change; no experiments have run.**
- **P20:** the real liquidation must re-run this check (already a carry-forward: the harness's
  redistribution must match P20's on the same inputs).

## Human's question at approval: can `m` be inflated to mask an ordering violation?

**Through `m` itself, no. Through stake collapse, yes — the bound becomes weak, and that is raised as
P17-1.** An earlier answer claimed a measured largest slack of 1.7·10⁻¹⁷ and proposed a 10⁻⁹ slack
ceiling. Both were wrong. The figure came from the final run of each seed only, and the ceiling fails
on every seed (`test_regression_I13_derivedBound_stakeCollapse`). Both are withdrawn.

1. **`m` cannot be forged.** It counts the VaultManager's own `Redistributed` events since the
   member's last `PositionUpdated`. Only the VaultManager emits them, and the handler filters by
   emitter. The handler's count is cross-checked against the events in Foundry.
2. **`m` cannot be targeted.** Every redistribution affects every member, and `m` resets at the
   member's next insertion. Its own term adds `(stake + 1)/DP` wei per redistribution, at most
   ~10⁻¹⁸ of the key.
3. **The `ΔL/DP` term is where the bound widens.** A member's collateral includes its own share of
   the rewards, `c ≥ stake·ΔLColl/DP − 1`, so `kc/c` is bounded by roughly `1/stake`; the same
   holds for debt. Repeated redistributions drive new stakes toward zero (§6.5.4), and with them the
   tolerance relative to the member's own key rises toward 1.
4. **Measured over the full campaign** (8 seeds × 256 runs × 200 calls, deployment A, every member
   after every step, about 436,000 member-steps): the derived bound held throughout. The largest tolerance
   it granted, `max(kc/c, kn/n)`, by the member's stake:

   | stake (wei) | member-steps | largest relative tolerance |
   |---|---|---|
   | 0 | 763 | 2.7 (270 %) |
   | 1 – 9 | 365 | 0.99 |
   | 10 – 99 | 461 | 6.4·10⁻² |
   | 100 – 999 | 346 | 9.1·10⁻³ |
   | 10³ – 10⁴ | 281 | 5.7·10⁻⁴ |
   | 10⁶ – 10⁷ | 1,481 | 8.8·10⁻⁷ |
   | 10¹² – 10¹³ | 5,566 | 9.2·10⁻¹³ |
   | 10¹⁷ – 10¹⁸ | 31,690 | 9.0·10⁻¹⁸ |
   | ≥ 10¹⁸ | 325,441 | 3.0·10⁻¹⁸ |

   In every decade below 10¹⁸ the largest value is 0.57–0.99 divided by the decade's lowest stake,
   so `1/stake` describes the data.

**So the griefing angle is the collapse, not `m`.** An actor who forces repeated redistributions
weakens I13 for every member at once. The rough cost and the protocol consequences — including a
reachable `totalStakes == 0` with open positions — are tracked as P17-1. I13 states its weak regime
explicitly rather than hiding it behind a ceiling that does not hold.

## Exact wording to apply (after the unlock)

### I13, "Statement": replaces the second sentence

Lazy redistribution perturbs effective keys by rounding, so the order holds within a per-member
tolerance derived from the rounding each member can actually have accumulated since it was last
inserted, rather than exactly. The tolerance is tight while stakes are large and weak once they
collapse (see "Weak regime").

### I13, "Formula": replaces the paragraph and its code block

For every adjacent pair `(A, B)` in the list — `A` nearer the head — with keys `(cA, nA)`, `(cB, nB)`
from `sortKey` (§5.1.12):

```
(cA + kc(A)) · (nB + kn(B))   ≥   cB · nA

kc(p) = 1 + ⌈(ΔLColl(p) + m(p) + stake(p)·m(p)) / DECIMAL_PRECISION⌉
kn(p) = 1 + ⌈(ΔLDebt(p) + m(p) + stake(p)·m(p)) / DECIMAL_PRECISION⌉
```

where, since `p` was last inserted into the list (every reinsert applies pending rewards, recomputes
the stake and records the key): `ΔLColl(p) = LColl − snapLColl(p)`, `ΔLDebt(p) = LDebt − snapLDebt(p)`,
and `m(p)` is the number of `Redistributed` events since `p`'s last `PositionUpdated`.

### I13, "Derivation of the form": replaces the paragraph

Each effective value is an exact value minus a non-negative error: `c = c* − δc`, `n = n* − δn`, where
the exact value is the one with unfloored stakes and rewards. For a member `p`, since its last
insertion:

- the pending floor (`pending = ⌊stake · ΔL / DP⌋`, R8) loses less than 1 wei;
- the stake floor (R10, `stake ≥ stake* − 1`) loses less than `ΔL* / DP`, with `ΔL* < ΔL + m` the
  unfloored accumulator;
- the redistribution floors (`dL = ⌊num / totalStakes⌋`, §6.5.2) lose less than 1 L-unit each, i.e.
  less than `stake · m / DP` over `m` redistributions; the error carry can only reduce this.

So `δc(p) < kc(p)` and `δn(p) < kn(p)`. In exact arithmetic snapshot-corrected stakes preserve the
order (every member receives the same reward per unit of effective collateral, §6.5.4). An observed
pair is therefore consistent with a correct exact order exactly when some admissible errors make it
so: `(cA + δcA)(nB + δnB) ≥ (cB + δcB)(nA + δnA) ≥ cB · nA`, and maximising the left side gives the
check above. Only `A`'s collateral and `B`'s debt carry tolerance terms; adding them to both sides
would be strictly weaker. A member with no redistribution since its insertion has `kc = kn = 1`, and
such a member is exact anyway.

### I13, new paragraph after "Derivation of the form": "Weak regime"

**Weak regime (P17-1).** A member's own rewards are part of its key (`c ≥ stake · ΔLColl / DP − 1`,
likewise for debt), so its tolerance relative to its own key is bounded by roughly `1/stake`.
Repeated redistributions drive the stake snapshot ratio of §6.5.4, and with it the stakes of newly
inserted positions, toward zero.

Measured over the P17 campaign (deployment A, 8 seeds × 256 runs × 200 calls, every member after
every step):

| member's stake | largest tolerance granted, relative to its own key |
|---|---|
| below 1,000 wei | above 0.1 % (up to 0.91 %) |
| below 100 wei | above 1 % (up to 6.4 %) |
| below 10 wei | up to 99 % |
| 0 | up to 270 % |
| 10¹⁸ wei and more | at most 3·10⁻¹⁸ |

**For members staked below 1,000 wei, I13 therefore detects only inversions larger than about 0.1 %
of their keys; for members staked below 10 wei it checks essentially nothing.** The campaign reports
the largest tolerance granted and the smallest stake seen in `docs/fuzzing.md`. This is a property of
the snapshot design, not slack to be tuned: any change belongs to P17-1, through `/spec-change`.

### I13, "Overflow": replaces the paragraph

Each redistribution adds `dL ≤ x · DP + lastError` to an accumulator, with `x` the amount
redistributed and `lastError < totalStakes`, since `totalStakes ≥ 1`. So `ΔLColl / DP` is at most the
collateral ever redistributed plus `m · totalStakes / DP`, and `ΔLDebt / DP` likewise for normalised
debt. With `stake ≤ coll`, `kc` is bounded by WETH's supply (~1.2·10²⁶ ≪ 2¹²⁷) and `kn` by the supply
cap, for any realistic `m` (< 2⁶⁴). Both sides of the check therefore fit in `uint256` under §6.3.1's
bounds, exactly as the base comparison does.

### I13: replaces the paragraph "The constant `k = 4` is calibrated, not proven." with

**Validation (CHG-008).** This invariant used a constant `k = 4` until P17. It was calibrated on
P02's observations (inversions up to `7.1·10⁻¹⁹` relative), and the P17 campaign exceeded it in
deployment A: after repeated redistributions the stake snapshot ratio fell to `3.7·10⁻⁶`, `LColl`
reached `2.7·10²³`, and an adjacent pair needed `k ≈ 8,125` wei (regression
`CoreHandlerRegressionsTest.test_regression_I13_toleranceAfterRedistributions`).

The derived bound holds on that sequence, on the stake-collapse sequence
`test_regression_I13_derivedBound_stakeCollapse`, and on every pair after every step of the campaign.

The list-only harness `SortedPositionsInvariant` (mock keys, P13) models drift directly — at most 4
wei per key change — and checks with that constant, which is its `kc = kn`.

### I13, "Checked in": replaces the first sentence

Foundry `invariant_I13_sortedByNicrWithinTolerance` over the core handler, with `m` counted from
`Redistributed` events (one walk, O(size); every run of deployment A must reach both the exact and the
tolerance-only regime; the largest tolerance granted and the smallest stake are reported), the CHG-005
regression test above and the two CHG-008 regression tests; P13's list-only campaign
`SortedPositionsInvariant` with its synthetic drift; Medusa `property_I13_sortedOrder`.

## Post-application review (P17 security review, 2026-10-25)

- **F3 → P17-2:** the derivation counts each member's own floor errors but not the error in the
  snapshot ratio (`totalStakesSnapshot` sums floored stakes; `totalCollateralSnapshot` carries
  pending dust). A member inserted later can be under-staked by several units relative to older
  members, so its drift can exceed `kc`/`kn`. Not yet observed; the human decides between
  re-deriving and relabelling the bound "empirically validated".
- **F4 → P17-1 (d), (e):** a collapsed ratio survives a full exit, and a DEFICIT-path reset leaves
  zero-stake survivors beside 1:1-staked newcomers — order inversions of any size, outside any
  rounding bound.
- **F5 → P17-H1:** the harness redistributes collateral-rich remainders; real A liquidations
  redistribute debt-heavy ones. P20 must run I13 under the real kind of input.
