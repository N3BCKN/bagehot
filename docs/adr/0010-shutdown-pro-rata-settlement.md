# ADR-0010: Settle a shutdown pro rata, in kind

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 10. A system with no admin needs an automatic end state for the cases it
cannot absorb: a long oracle failure, a TCR below critical, or a deficit above a share of supply
(`docs/spec.md` §6.11.1). Once triggered, the remaining collateral has to be distributed to the
remaining token holders, and the rule decides whether that distribution can be gamed.

Settling at "the last good price" invites exactly the race the shutdown exists to stop: whoever
claims first at a stale price takes more than their share, and the oracle may be the reason for
the shutdown in the first place.

## Decision

Shutdown is irreversible and permissionless. After `REPAYMENT_WINDOW` (during which borrowers may
repay, close or add collateral), `settle()` takes every pool of collateral in O(1) — vault
collateral, pending rewards, recovered collateral, and in B the whole auction lot — and snapshots
it against the token supply after the protocol reserve is burned (§6.11.3). Each holder then
claims `mulDivDown(amount, claimColl, claimSupply)` (R26). No price is read at settlement and no
position is special: claims are order-independent (§6.11.4).

## Alternatives considered

- **Redeem at the last good price.** Arbitrage against a stale price, and a run during the window.
- **Per-position settlement at the trigger price.** Needs a usable price exactly when the oracle
  may have failed, and a loop over positions, which cannot be bounded.

## Consequences

- Order independence is testable as an invariant (I10 in the blueprint's numbering; P03).
- Borrowers who do not repay inside the window forfeit their surplus collateral to the claim pool
  (`docs/spec.md` §1.4, `docs/threat-model.md` §4). This is the accepted cost of the rule.
- The protocol reserve is burned before the snapshot, so it protects holders rather than diluting
  them (D-16).
