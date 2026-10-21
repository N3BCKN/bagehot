# Bagehot protocol specification

> **Stub — filled at P02 (human gate).** Until then this file is empty of content and nothing may
> be implemented against it. The specification wins over the code: if they disagree, the code is
> wrong until the human approves a change through `/spec-change`.

## 1. Scope and non-goals

## 2. Units and fixed-point conventions

<!-- WAD (1e18), RAY (1e27), bps; which quantity uses which; naming (debtWad, indexRay, priceWad) -->

## 3. Parameters

<!-- Every immutable constructor argument: name, unit, admissible range, source of the value -->

## 4. State

<!-- Per-position and global state, with the exact type and unit of every field -->

## 5. Oracle

<!-- Feeds, staleness, sequencer uptime, the price used by each operation -->

## 6. Positions and borrowing

## 7. Interest accrual

## 8. Redemption

## 9. Liquidation — deployment A (stability pool)

## 10. Liquidation — deployment B (Dutch auction)

## 11. Redistribution and the deficit ledger

## 12. Shutdown

## 13. Rounding table

<!-- One row per division: expression, direction, who it favours, why. A bare `/` is a bug. -->

| # | Expression | Direction | Favours | Rationale |
|---|---|---|---|---|

## 14. Permissions

<!-- Who may call what. No owners, no admin roles; only the one-shot wire(...) of ADR-021. -->

## 15. Events

<!-- Every state change, with exact fields: the indexer rebuilds state from events alone (I14) -->

## 16. Errors

<!-- Custom error names, shared verbatim with the Python model's exception names -->

## 17. Algorithms

<!-- Pseudocode precise enough that the Solidity and the Python model cannot diverge -->
