# ADR-0023: Cap the liquidation penalty and return the surplus to the position owner

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Kit correction 12. A liquidation that seizes the whole collateral regardless of how far the
position fell below MCR turns a 1% shortfall into a total loss for the borrower, and it hands the
liquidator a payoff that grows with the borrower's bad luck rather than with the work done. It
also creates an incentive to self-liquidate: a borrower whose own position is slightly underwater
could profit by liquidating it themselves.

## Decision

The value a liquidation may take from a position is capped at `debt × (1 + LIQUIDATION_PENALTY)`,
and whatever remains goes back to the owner. In deployment A the pool seizes
`mulDivUp(debt, WAD + penalty, price)` of collateral, capped at what the position holds, and the
surplus is pushed to the owner immediately (`docs/spec.md` §6.6.4, R11, D-13). In deployment B the
auction's tab is `debt × (1 + penalty)` (R21) and the auction stops selling once the tab is paid:
the leftover lot goes to the owner (§6.8.4, D-3). `LIQUIDATION_PENALTY` is identical in A and B of
one comparison (§3.3 constraint 2) and is itself capped at 0.5 WAD by the constructors.

## Alternatives considered

- **Seize everything.** Maximal liquidator incentive, unbounded borrower loss, and self-liquidation
  becomes profitable for an underwater owner.
- **A penalty proportional to the shortfall.** Smoother, but needs the shortfall measured at a
  price that may be stale, and makes the A/B comparison depend on a second curve.

## Consequences

- The borrower's worst case from one liquidation is bounded and stateable in the report.
- Self-liquidation is not profitable: the owner pays the penalty either way (blueprint §17.2,
  threat T-10).
- The surplus is pushed, not held, so no claimable-surplus bucket enters the solvency identities
  (D-13).
