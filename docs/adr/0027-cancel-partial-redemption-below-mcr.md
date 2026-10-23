# ADR-0027: Cancel a partial redemption that would leave the position below MCR

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-23
- Prompt: P03 (found), applied via `/spec-change` CHG-002
- Supersedes: —

## Context

Spec §6.7.3 caps a partial redemption so the position keeps at least `MIN_DEBT`, but never
re-checks its ICR afterwards. In exact arithmetic no check is needed: the redeemer takes collateral
worth `d·(1 − feeRate)` for `d` of debt, a bundle whose ratio is below 1, so the position's ICR
rises (D-2: the fee stays in the position).

With integer arithmetic it can fall. The debt relief `dn = mulDivDown(d, RAY, index)` rounds down,
and the remaining debt `mulDivUp(n − dn, index, RAY)` rounds up, so the value of debt cancelled can
be less than the value of collateral taken. A position with zero head-room above MCR then ends
below it. Found while writing invariant I5 at P03 and reproduced at the **start** parameters
(`MIN_PRICE = 10e18`): after 4.25 years of interest (index 1.2304), an 11-wei redemption against a
position exactly at MCR cancels 8 wei of normalised debt for 1 wei of collateral and leaves it
`1e17` (in `coll·price − MCR·debt` units) below MCR. The window is
`price/WAD ≲ d ≲ 10.5·(index/RAY + 1)`, so it widens as interest accrues and no fixed price floor
closes it. Full analysis and the corrected reachability evidence: `docs/changes/CHG-002-*.md`.

## Decision

In `VaultManager.redeemCollateral`, after computing `dn` and `out` for a partial and before the
hint search, require

```
(c − out) · price  ≥  MCR · debtOf(n − dn)
```

with `c`, `n` the position's effective values. If it fails, the partial is **cancelled exactly as a
stale hint cancels it**: no state change, no event, the loop ends. No new error and no new event —
if nothing else was redeemed, `redeem` reverts `NothingRedeemed` as it already does.

## Alternatives considered

- **Raise the `MIN_PRICE` floor.** Rejected: the counterexample sits *at* the proposed floor of
  `10e18`, and the window scales with the index, so any fixed floor fails eventually.
- **A minimum redemption amount.** Rejected: adds a parameter and a revert, and a threshold chosen
  today stops being sufficient as the index grows.
- **State invariant I5 with a tolerance.** Rejected: a tolerance on "a position must stay above
  MCR" is the hidden weakening `CLAUDE.md` forbids. The property is binary.
- **Skip the position and continue the loop.** Rejected: a partial is by definition the last step
  (`remaining < debt`); continuing would redeem a partial from a different position and change the
  loop's semantics far more than ending it does.

## Consequences

- Invariant I5 holds in every configuration and at every index. Its targeted test (P16) consumes
  `redemption.json#partial_cancelled_below_mcr`.
- Cost: one cross-multiplication per redemption, no division, no storage.
- Only partials inside the rounding window are cancelled — a few wei to a few dozen wei against a
  position at the MCR boundary. An ordinary partial against the same position still goes through
  and raises its ICR (the same vector shows a 1,000-stable redemption succeeding).
- A redeemer whose only candidate is such a partial gets `NothingRedeemed` and pays nothing; the
  base rate is unchanged.
- The six existing redemption vectors and every other vector file regenerate byte-for-byte
  identical: the guard changes no prior behaviour.
