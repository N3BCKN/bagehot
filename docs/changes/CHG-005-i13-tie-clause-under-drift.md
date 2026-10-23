# CHG-005: I13's tie clause is false once any key in the list has drifted

- Status: **approved 2026-10-23 (option 1, corrected wording) and applied** to I13's "Ties", "Scope"
  and "Checked in" paragraphs — ADR-0032. Campaign after applying: 30 seeds × 256 runs × 200 calls,
  0 failures, both regimes reached in every run.
- Raised: 2026-10-23, P13 (the I13 invariant handler)
- Affects: `docs/invariants.md` I13 ("Ties" paragraph). No spec, vector, contract or model change.

## Problem

I13 states, besides the tolerance check: *"`idA < idB` when `cA·nB == cB·nA` is asserted only for
pairs whose keys have not changed since insertion."* The restriction to unchanged keys is not enough.
Once **any** member of the list has drifted (lazy redistribution lowered its effective key without a
reinsert), a later insertion can be placed against that drifted neighbour and land on the wrong side
of an exact tie — between two nodes whose own keys never changed.

## Evidence

Deterministic, five operations, `SortedPositions` with a mock key source, `MAX_HINT_STEPS` = 30:

1. B (id 12) inserted with key K = (2e18, 1e18).
2. D (id 5) inserted with key (K + 3 wei, 1e18) — just above B, so D is ahead of B.
3. D drifts: its collateral is lowered by 4 wei (within I13's own model, δ ≤ k = 4) to just *below*
   K. D stays where it is (no reinsert), still ahead of B.
4. A (id 19) inserted with key K, no hints. The walk from the head stops at the first node A precedes
   — D, whose observed key is now below K — so A is linked **ahead of D**, hence ahead of B.
5. D is removed. A (id 19) is now directly ahead of B (id 12) with **exactly equal keys**, neither of
   which changed since insertion.

The P13 invariant campaign (`SortedPositionsInvariantTest`, 256 runs × 200 calls per seed) hit the
same reversal on 5 of 13 seeds (19 before 12, 26 before 22, 17 before 16, 36 before 30, 34 before 24).
With the tie clause switched off for diagnosis, **the tolerance check and list integrity held on all
30 seeds tried (1.5 million calls)**. Exact order, ties included, with no drift anywhere is proven
separately by `SortedPositionsFuzzTest` against a sorted-array reference (2 × 1,024 sequences).

The real protocol can produce the same sequence: insertion compares effective keys, which include
pending redistribution (§6.3.1), so a position inserted next to one with pending rewards behaves like
A in step 4.

Impact: none on safety or determinism. The reversal is between two positions with *identical* NICR;
redemption checks each position's ICR individually and liquidation is by id (§6.3.3). It matters
only because I13 asserts something false, so a correct implementation fails it.

## Options

1. **Scope the tie clause to an exact list** (recommended). *Corrected after approval:* the first
   wording here — "when no member of the list has drifted since it was last inserted" — is false;
   the counterexample's final state has no drifted member (D has left) and is still not exactly
   ordered, and the campaign fails it on 4 of 30 seeds. The condition must cover the history of
   each insertion. A member is *exact* if its key has not changed since it was last inserted **and**
   every member was exact at that insertion; while every current member is exact, the list is
   exactly ordered, ties included (0 of 30 seeds fail, both regimes reached in every run). The exact
   replacement text for I13's "Ties", "Scope" and "Checked in" paragraphs is staged in the apply
   script and quoted in full in the approval message of 2026-10-23. Consequences: I13 keeps a sharp
   exact assertion where it is true; P17's handler must track per-member exactness.
2. **Drop the tie clause.** The tolerance check stays; exact ordering is left to the insertion tests.
   Consequences: simpler, but the invariant campaign no longer checks exact order in the regime where
   it does hold (the long drift-free stretches between redistributions).
3. **Keep it as is.** Rejected: a correct implementation fails it; keeping it would mean weakening the
   test instead, which CLAUDE.md forbids.

## Recommendation

Option 1. It states exactly what holds and keeps the strongest check available in each regime.

## Impact

| Area | Impact |
|---|---|
| `docs/invariants.md` | I13 "Ties" paragraph replaced; "Checked in" unchanged (protected file) |
| `docs/spec.md` | none (§6.3.3 already says near-ties can swap) |
| `spec/vectors/` | none |
| Solidity, Python model | none |
| Tests | `SortedPositionsInvariantTest`: the tie assertion is applied while no current member has drifted, and exact order is asserted in that regime; P17's handler likewise |
| Differential, experiments, preregistration | none |
| ADR | a short ADR after approval, referencing this file |
