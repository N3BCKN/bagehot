# ADR-0021: Allow exactly one setter — a one-shot `wire(...)` by the immutable deployer

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

ADR-0009 forbids setters, but the core contracts reference each other in cycles:
`VaultManager` needs the RedemptionModule to authorise `redeemCollateral`, and the RedemptionModule
needs the VaultManager to call it; the DeficitLedger needs the strategy and the strategy needs the
ledger. Constructor-only wiring would require every address to be known before any contract is
deployed, i.e. CREATE2 with predicted addresses for a cycle of nine contracts — fragile, and the
prediction breaks on any constructor-argument change.

## Decision

Each contract has `wire(...)` taking exactly the peer addresses listed as "wired" in
`docs/spec.md` §4. It checks `msg.sender == deployer` (`NotDeployer`), then `!wired`
(`AlreadyWired`), then its arguments in order (`InvalidParameter(index)`), sets `wired = true` and
emits `Wired(address[])`. `deployer` is an immutable set in the constructor. Every state-changing
external function requires `wired` (`NotWired`); views do not. There is no unwire, no rewire and
no other setter anywhere (§9).

At the P02 gate two edges were added: `RedemptionModule.wire` now also takes the `ShutdownModule`
and, in deployment B, the `DutchAuctionHouse`, both used read-only by the critical-TCR gate
(ADR-0026, spec §6.7.2) — `belowCritical(price)` and `inPurchase()`. Neither contract takes or
calls the RedemptionModule in return, and the only contract holding its address, the VaultManager,
stores it solely for the `Unauthorized` check on `redeemCollateral`. The address graph is cyclic;
the run-time call graph through the RedemptionModule is not.

## Alternatives considered

- **CREATE2 with predicted addresses.** Removes the setter but makes deployment a puzzle whose
  pieces move whenever a constructor argument changes; a prediction error is unrecoverable.
- **A registry contract every contract reads.** One more trusted component on every call path, and
  the registry itself needs a setter.
- **An owner who may rewire.** Precisely the admin role ADR-0009 exists to exclude.

## Consequences

- There is exactly one privileged action in the system, it can be taken exactly once, and the
  deployment script takes it immediately after deployment.
- Between deployment and wiring the system is inert: every state-changing function reverts
  `NotWired`, so the window cannot be exploited, only observed.
- A wiring mistake is unfixable: the deployment is discarded and redone. The deployment script
  asserts the cross-contract constraints of spec §3.3 (including constraint 7, the auction-house
  argument) before it broadcasts.
