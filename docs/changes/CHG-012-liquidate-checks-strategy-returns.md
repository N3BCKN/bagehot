# CHG-012: `liquidate` reverts if the strategy reports more than it can have absorbed or returned

- Status: **approved by the human 2026-10-26** (P20 plan, decision d) and applied at P20.
- Affects: `docs/spec.md` §6.4.1 (two checks after `onLiquidation`), §11.2 (two errors). The Python
  model mirrors them. No vector changes: no conforming strategy can trigger them.

## Problem

§6.4.1 relies on the strategy contract for `debtAbsorbed ≤ debt` and `collReturned ≤ coll`. If a
future strategy (or an unforeseen path in one) broke either, `normAbsorbed` could exceed the
position's normalised debt (underflow of `normRest`, or a silent over-reduction of `totalNormDebt`
when `debtAbsorbed == debt` is not hit exactly), or more collateral than the position had could be
booked as redistributed or recovered — silent corruption of the books instead of a revert.

**Scope (corrected after the P20 security review, P20-L1).** These are range checks only. They do
not verify that `collReturned` WETH actually arrived: a strategy that reports `collReturned ≤ coll`
but transfers nothing passes both, and the books would then carry `pendingColl` (or `recoveredColl`)
with no WETH behind it. A receipt check is proposed separately as CHG-014.

## Decision

After `onLiquidation` returns, `liquidate` checks `debtAbsorbed ≤ debt` (`DebtAbsorbedExceedsDebt`)
and `collReturned ≤ coll` (`CollReturnedExceedsColl`). Two comparisons; the same defence-in-depth
reasoning as ADR-0029 (the oracle's guarded call) and CHG-006 (the failure-tolerant pool hook). A
conforming strategy never triggers them, so they change no outcome of the spec's algorithms.

## Tests

One test per bound with a strategy that violates it by one unit, and one at each bound exactly
(accepted): `VaultManagerLiquidationTest`. The model raises the same error names.
