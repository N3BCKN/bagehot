# ADR-0032: I13 asserts exact order only while every list member is exact

- Status: accepted 2026-10-23 (human)
- Date: 2026-10-23
- Prompt: P13 (found by the I13 invariant handler), applied via `/spec-change` CHG-005
- Supersedes: —

## Context

Invariant I13 (`docs/invariants.md`) holds the sorted list to a tolerance check on every adjacent
pair, because lazy redistribution moves effective keys by rounding (spec §6.3.3). It also asserted
exact id order on ties "only for pairs whose keys have not changed since insertion". That is false.
Once any member's key has changed without a reinsert, a later insertion can be placed against the
changed key and land on the wrong side of an exact tie with a member whose key never changed — and
it stays there after the changed member has left. Deterministic counterexample, five operations:
B (id 12) inserted; D inserted 3 wei above B, then its key lowered by 4 wei (within I13's k = 4);
A (id 19), with B's key, is placed ahead of D; D removed. A sits directly ahead of B with equal
keys, neither changed since insertion, and no current member has drifted.

The P13 campaign hit it on 5 of 13 seeds. The first proposed fix — exact order "when no member of
the list has drifted" — fails too (4 of 30 seeds), because the counterexample's final state has no
drifted member. The condition must cover the history of each member's insertion, not only the
current keys. With it, the campaign is green on all 30 seeds (256 runs × 200 calls each), with both
regimes reached in every run. The tolerance check itself never failed. Full evidence:
`docs/changes/CHG-005-i13-tie-clause-under-drift.md`.

## Decision

- A list member is **exact** if its key has not changed since it was last inserted **and** every
  member of the list was exact at the moment of that insertion.
- While every current member is exact, I13 asserts exact §6.3.1 order on every adjacent pair, ties
  by lower id included, with no tolerance.
- Once any current member is not exact, every adjacent pair is held only to the tolerance check,
  ties included. I13's "Scope" paragraph says so instead of claiming the tolerance applies only to
  pairs whose own keys moved.
- The five-operation counterexample is a permanent regression test on both sides
  (`SortedPositionsTest.test_CHG005_tieReversedThroughADriftedNeighbourThatHasSinceLeft`, Python
  `test_chg005_…`); the invariant handler tracks exactness per member and must reach both regimes
  in every run.
- No change to the spec's algorithm, the contracts, the Python model or any vector.

## Consequences

- I13 states only what holds, and keeps an exact check in the regime where exact order is true —
  from deployment until the first redistributing liquidation, and again once every affected
  position has been reinserted while the list is exact.
- P17's invariant handler must track per-member exactness the same way (the P13 handler is the
  reference).
- No downstream reliance found: redemption checks each position's ICR individually and liquidation
  is by id (§6.3.3); hints are validated against the actual list; walk bounds do not depend on
  ties; the differential test compares the two implementations' list order exactly, and both
  implement the same algorithm (the regression test passes identically on both sides). Spec
  §6.3.1's phrase "among equals, highest id first" describes the exact regime; §6.3.3 already says
  near-equal positions can swap.
- Reversing it would mean asserting exact tie order under drift, which a correct implementation
  fails.

## Alternatives considered

- **"No current member has drifted"** as the exact-regime condition. Rejected: false — the
  counterexample's final state satisfies it (4 of 30 seeds fail).
- **Drop the tie clause and keep only the tolerance check.** Rejected: loses the exact check in the
  long stretches where exact order does hold, and with it the strongest detector of a broken
  insertion.
- **Keep the clause as written.** Rejected: a correct implementation fails it, and passing it would
  require weakening the test, which `CLAUDE.md` forbids.
