# ADR-0005: Redeem at par against the lowest-NICR positions

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 05. The peg needs a hard floor that does not depend on anyone's willingness
to trade: if a token can always be exchanged for a dollar of collateral, nobody sells it for less
for long. The question is which positions pay for it and in what order.

Ordering by ICR makes the queue price-dependent: every price move reorders the list, so the order
would have to be recomputed on-chain. Ordering by NICR — collateral per unit of normalised debt
(`docs/spec.md` §2.4) — is price-independent, so the list is stable between operations and a hint
walk is cheap (§6.3).

## Decision

`RedemptionModule.redeem` exchanges stablecoin for collateral at the oracle price, less a fee
(§6.7). `VaultManager.redeemCollateral` walks `SortedPositions` from the tail (lowest NICR) and
redeems against positions in that order, skipping any position below MCR (§6.7.3). The fee stays
in the redeemed position as collateral (D-2). Redemptions are blocked while the system TCR is
below `CRITICAL_TCR` (ADR-0026).

## Alternatives considered

- **No redemption, rely on market arbitrage.** The floor would then be a belief, not a mechanism;
  the research question about the peg floor would be unanswerable.
- **Queue by ICR.** Price-dependent ordering: every price tick invalidates the list, and the hint
  mechanism (§6.3.2) could not bound its walk.

## Consequences

- The riskiest borrowers are redeemed first, which pushes the system's average ICR up exactly when
  it is low — a stabilising feedback the report can measure.
- Borrowers can be redeemed against without being in default; they lose collateral at par and keep
  the fee's share. This is the price of the floor and must be stated in the report.
- A sorted list with hints is a permanent complexity cost (§6.3, I13).
