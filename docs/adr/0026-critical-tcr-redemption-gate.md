# ADR-0026: Block redemptions below the critical TCR

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Decision taken by the human at the P02 gate; recorded in `docs/spec.md` as D-27. The original
design allowed redemption at any TCR, on the reasoning that redemption is value-neutral: the
redeemer hands over a dollar of debt and takes a dollar of collateral.

That holds only while collateral is worth at least as much as debt. Once
`systemColl · price < systemDebt`, equal value leaving both sides *lowers* the ratio, so each
redemption makes the next one worse. Redemption then becomes a run: the first redeemer gets a full
dollar of collateral per token, the last ones get whatever is left. Shutdown covers the end state,
but only once somebody calls `check()`, and nothing guarantees that happens before the collateral
is gone.

## Decision

`RedemptionModule.redeem` reverts `TCRBelowCritical()` when `ShutdownModule.belowCritical(price)`
is true: `live and systemDebt > 0 and systemColl · price < CRITICAL_TCR · systemDebt`
(`docs/spec.md` §5.8, §6.7.2). The threshold, the `live` guard and both quantities are the TCR
branch of the shutdown trigger, so the gate closes wherever `check()` would trigger. Between
`CRITICAL_TCR` and `MCR` redemptions stay allowed, because there collateral still exceeds debt and
a redemption raises the ratio.

`redeem` does **not** call `check()`: the revert that follows would roll the shutdown back,
losing both the trigger and the oracle failure clock. It also carries the `AuctionCallbackActive`
guard, so the ratio cannot be read from inside a buyer's callback, where it lags (§6.8.4).

## Alternatives considered

- **Allow redemption at any TCR** (the original choice). Leaves the run unaddressed and makes the
  peg floor a first-mover advantage.
- **Block below MCR, as Liquity v1 does.** Blocks a band where redemption is still stabilising,
  and uses a per-position threshold for a system-wide decision.
- **Call `check()` inside `redeem`.** Would shut the system down at the right moment and then
  revert the shutdown along with the redemption.

## Consequences

- The gate is measured before any `cover()`, `check()` after its own, so the gate is never looser
  than the trigger and can be slightly tighter (spec §6.7.2).
- `RedemptionModule` gains two read-only wiring edges, to `ShutdownModule` and (in B) the
  `DutchAuctionHouse` (ADR-0021).
- A new invariant for P03, placeholder `I15`: no successful redemption while
  `TCR < CRITICAL_TCR` (spec Appendix B). Vector: `redemption.json#tcr_guard`.
- The peg floor is conditional: holders cannot rely on redemption in exactly the state where they
  would most want it. The report must say so when it discusses the floor.
