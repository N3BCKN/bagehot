# ADR-0034: I13's tolerance comes from hidden ideal keys, with allowances fixed at insertion

- Status: accepted 2026-10-26 (human)
- Date: 2026-10-24, rewritten 2026-10-25 (before acceptance) for CHG-009
- Prompt: P17, via `/spec-change` CHG-008 (superseded formula) and CHG-009
- Supersedes: —

## Context

I13 held adjacent list members to a constant tolerance, `k = 4` wei, calibrated on P02's
observations. The P17 campaign exceeded it in deployment A (`k ≈ 8,125`).

CHG-008 replaced it with a per-member bound derived from each member's own rounding. The P17
security review (F3) found that derivation incomplete. A correct VaultManager breaks it on a
protocol-valid sequence (`I13BoundCounterexampleTest`), for two reasons:
- the snapshot ratio of §6.5.4 is short of the members' common ratio by accumulated carry and dust,
  so a newcomer can be off by many stake units relative to its neighbour;
- the list is built by insertions against drifted keys, so no set of exact keys within per-member
  boxes need order it.

Full evidence: `docs/changes/CHG-009-i13-hidden-key-bound.md`.

## Decision

- **Hidden key.** Every member gets the ideal stake `c·DP/(DP + L_p)` on one common ratio. Its
  hidden NICR is `(DP + LColl)/(h_p + LDebt)` with `h_p = n_p(DP + L_p)/c_p − snapLDebt_p`, constant
  while it stays in the list. Ordering by `h` is invariant under every redistribution, whatever the
  real stakes and whatever the rounding.
- **Allowance.** At its insertion between `X` and `Y`, a member gets
  `ι_p = max(0, ι_X + h_X − h_obs,X, ι_Y + h_obs,Y − h_Y)`, where `h_obs` maps an observed key into
  hidden coordinates.
- **Pair condition.** Adjacent pairs must satisfy `h_A − ι_A ≤ h_B + ι_B`. In observed keys this is
  `h_obs,A − h_obs,B ≤ (d_A − d_B) + ι_A + ι_B` with `d = h_obs − h`: a per-pair tolerance on the
  effective-NICR order, derived exactly. Its soundness is proved by induction over insertions. All
  values are exact rationals; `ι` is rounded up once per insertion, and an undrifted neighbour
  contributes 0.
- **Exact companion checks**, with no tolerance:
  - `sortKey` equals the spec formula;
  - every insertion `precedes`-exact against its neighbours;
  - every insertion's stake equals `computeStake`.
- The CHG-005 exact regime is unchanged. The list-only harness `SortedPositionsInvariant` keeps its
  synthetic `k = 4`.
- No change to the spec's algorithms, the contracts, the Python model or any vector.

## Consequences

- I13 is sound under any redistribution sequence, including stake collapse and the P17-1 (e) state
  after a reset. The tolerance has no a-priori limit, and it is vacuous in reachable zero-stake
  states. The campaign observed per-pair tolerances up to 4.4·10⁻³ of the NICR in runs whose stakes
  collapsed below 1,000 wei, and about 10⁻¹⁴ in uncollapsed runs, against up to 0.48 under CHG-008
  on the same pairs.
- Detection of wrong keys, misplaced insertions and wrong stakes no longer depends on slack. The
  review's mutant M7 is now caught deterministically.
- The handler keeps per-member history (`h`, `ι`), as CHG-005's exactness already does. Medusa uses
  the same state.
- P20 re-runs the check with the real `liquidate` (P17-H1).

## Alternatives considered

- **Keep k = 4.** Rejected: exceeded, and no constant is sound.
- **CHG-008's per-member bound.** Rejected: a correct implementation breaks it.
- **Patch CHG-008 with a snapshot-ratio term.** Rejected: it still rests on the exact-key premise,
  and the term depends on history anyway.
- **Label CHG-008 "empirically validated".** Rejected: a counterexample exists, and the human ruled
  out that fallback while a derivation was feasible.
