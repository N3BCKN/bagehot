# ADR-0003: Fix the liquidation strategy at deployment, one per deployment

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 03. The experiment compares a stability pool (A) against a Dutch auction
(B). The obvious implementation — one deployment with a router that can switch strategies — needs
an actor allowed to switch, which is an admin role, and ADR-0009 forbids admin roles.

It also weakens the comparison: a switchable system is a third mechanism, and any result would
describe the router's policy as much as the strategies.

## Decision

Each deployment wires exactly one strategy contract into `VaultManager` (`docs/spec.md` §3.4,
`wire(sorted, strategy, stabilityPool, …)`). `strategy` is set once and never changes. A and B are
two deployments of the same core with identical parameters except the strategy-specific ones
(§1.2, §3.3 constraint 2). `VaultManager` calls the strategy through one interface,
`onLiquidation(positionId, owner, debt, coll, price)` (§5.1.11, §6.4), so the core has no branch
on which strategy it holds beyond the pool-only interest routing (`POOL_SHARE_BPS = 0` in B,
§3.3 constraint 3).

## Alternatives considered

- **A router with a switch.** Needs an owner, a timelock and a migration path for in-flight
  liquidations; the comparison becomes a comparison of switching policies.
- **Both strategies live, chosen per liquidation by the caller.** The liquidator's choice would be
  endogenous to the price path, so neither mechanism would be measured in isolation.

## Consequences

- The A/B comparison is between two chains of deployments that differ in exactly one component.
- Every invariant that mentions the strategy is written twice, once per deployment (P03).
- Changing strategy means a new deployment and a new sweep; there is no migration.
