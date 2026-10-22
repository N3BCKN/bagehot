# ADR-0015: Use WAD/RAY fixed-point with an explicit rounding direction everywhere

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 15. Integer division truncates. In a CDP protocol every truncation is a
transfer of value between the protocol and somebody: debt rounded down is a gift to the borrower,
a gain rounded up is a gift to a depositor at the expense of the others. Left to the default, the
direction of each gift is whatever the expression happened to look like.

The second reason is testability: the differential test compares the model and the contracts
exactly (ADR-0022), which is only possible if both round identically at every division.

## Decision

Two fixed-point scales: WAD = 1e18 for amounts, prices and ratios; RAY = 1e27 for the interest
index and per-second rates (`docs/spec.md` §2.1). Every division on amounts, prices, indices or
shares goes through `mulDivDown` or `mulDivUp`, never a bare `/`, and §8 gives the direction and
the party it favours for all 34 of them. Ratio *decisions* (is this position liquidatable, is this
TCR below critical) use exact cross-multiplication instead of computing a ratio at all (§2.2).
`rpow` rounds every intermediate product up (§2.3, R5).

## Alternatives considered

- **Default truncation everywhere.** The direction of each rounding becomes an accident, and the
  accumulated drift has no bound anyone can state.
- **A signed-fixed-point or floating library.** Unnecessary: every quantity here is non-negative,
  and floats would break exactness.

## Consequences

- The drift in the supply identity is bounded and provable (I2, §10.2), not merely small.
- Rounding bugs show up as invariant failures rather than as slow leaks.
- Every new division in future work needs a row in §8; a bare `/` on an amount is a bug by rule
  (`CLAUDE.md`).
