# ADR-0034: I13's tolerance is a per-member bound derived from each member's rounding

- Status: proposed
- Date: 2026-10-24
- Prompt: P17 (found by the core invariant campaign, deployment A), applied via `/spec-change` CHG-008
- Supersedes: —

## Context

I13 held adjacent list members to `cA·nB + k(cA + nB) + k² ≥ cB·nA` with a constant `k = 4` wei,
calibrated on P02's observations and explicitly "not proven". I13 itself warned that the drift has
no constant bound when a large liquidation meets a small `totalStakes`.

The P17 campaign, redistributing through the test-only `VaultManagerHarness.redistribute` (§6.4.1
with an absorbing-nothing strategy, §6.5.2, §6.5.4), exceeded it on 3 of 8 seeds: one adjacent pair
needed `k ≈ 8,125` wei. The cause is rounding amplified by a falling stake snapshot ratio: a stake
floored by one unit loses `ΔL / DP` of every later reward. No constant covers that. Full evidence:
`docs/changes/CHG-008-i13-derived-drift-bound.md`.

## Decision

- For each member `p`, since its last insertion, `kc(p) = 1 + ⌈(ΔLColl + m + stake·m) / DP⌉` and
  `kn(p)` likewise with `ΔLDebt`. They bound the three rounding errors it can have accumulated:
  the pending floor, the stake floor and the redistribution floors. `m` is the number of
  `Redistributed` events since its last `PositionUpdated`.
- Adjacent pairs satisfy `(cA + kc(A)) · (nB + kn(B)) ≥ cB · nA`. The exact regime of ADR-0032 is
  unchanged.
- No ceiling on the tolerance. A 10⁻⁹ relative ceiling was proposed and withdrawn: it fails on every
  seed. I13 instead states its weak regime with measured numbers. The tolerance relative to a
  member's own key is up to about `1/stake`: above 0.1 % below 1,000 wei, up to 99 % below 10 wei.
- The list-only harness `SortedPositionsInvariant` keeps `k = 4`, which bounds its synthetic drift
  by construction.
- No change to the spec's algorithms, the contracts, the Python model or any vector.

## Consequences

- The bound is **empirically validated**, not yet proven: zero violations on every pair after every
  step, 8 seeds × 256 runs × 200 calls, plus two regression tests. The P17 review (F3, open issue
  P17-2) found the derivation omits the error in the snapshot ratio itself (floored stakes summed into
  `totalStakesSnapshot`, dust in `totalCollateralSnapshot`). If that term matters, I13 would fail
  falsely, most likely under P20's debt-heavy redistributions — a loud failure, never a masked bug.
- Where stakes have collapsed, I13 is weak, and its text says so with numbers. Stake collapse
  itself — including a reachable `totalStakes == 0` with open positions, which §6.4.1 routes to the
  DEFICIT path — is open issue P17-1, awaiting a human decision before P20. After a DEFICIT-path reset,
  zero-stake survivors next to 1:1-staked newcomers would produce inversions of any size (P17-1 (e)),
  which no rounding bound covers. A protocol fix there would change this derivation and requires a
  new ADR.
- P20 must re-run the I13 campaign with the real `liquidate` (carry-forward P17-H1).

## Alternatives considered

- **Raise the constant.** Rejected: I13 forbids it, and no constant is sound, since the drift scales
  with `ΔL / DP`.
- **Exclude deployment A's redistribution regime from I13.** Rejected: it is the regime I13 exists
  to cover.
- **Derived bound plus a relative slack ceiling.** Rejected: the ceiling does not hold, at 10⁻⁹,
  10⁻⁶ or 10⁻³, once stakes collapse. Keeping it would mean either a permanently failing invariant
  or a ceiling tuned to the data, which would hide the weak regime instead of stating it.
