# Architecture decision records

One file per decision, named `NNNN-short-kebab-title.md`, numbered from `0001` and never reused.

**An accepted ADR is never edited.** Changing a decision means writing a new ADR that supersedes
it: the new record says `Supersedes ADR-NNNN`, and the old one gets a single line added to its
Status field (`Superseded by ADR-MMMM`) — nothing else about it changes. Use `/spec-change` when a
decision looks wrong.

Status is one of `proposed` · `accepted` · `superseded by ADR-MMMM` · `rejected`.
An ADR is accepted only by the human; Claude writes them as `proposed`.

Once accepted, add the file to `.claude/protected-paths.txt` so it cannot be edited by accident.

## Template

```markdown
# ADR-NNNN: <decision in a single imperative phrase>

- Status: proposed
- Date: YYYY-MM-DD
- Prompt: PNN
- Supersedes: — (or ADR-MMMM)

## Context

What forces this decision: the constraint, the measurement, the part of the spec that depends on
it. Facts and numbers, not preferences. Link the spec section, invariant or data card involved.

## Decision

What we will do, stated so that code can be checked against it. Name the exact values, units and
rounding directions where they apply.

## Consequences

What becomes easier, what becomes harder, what this forecloses. Include the cost of reversing it.
Name the invariants, tests or report claims that now depend on this decision.

## Alternatives considered

Each with the reason it was not chosen. An alternative with no stated reason is not an
alternative, it is a note.
```

## Index

| ADR | Title | Status | Prompt |
|---|---|---|---|
| 0018 | Solidity version | not yet written | P04 |
| 0021 | One-shot `wire(...)` by the immutable deployer | not yet written | P04 |

ADR-018 records the choice of `solc_version = "0.8.28"` with `evm_version = "cancun"`, already
pinned in `contracts/foundry.toml` at P00.

ADR-021 records the one-shot `wire(...)`: circular references between the core contracts make
address prediction impractical, so each contract takes its peers once, from its immutable
deployer, and never again (spec §3.4, §9). When it is written at P04 it must also record the two
edges added at the P02 gate: **`RedemptionModule.wire` takes the `ShutdownModule` and (in B) the
`DutchAuctionHouse`**, which the original architecture did not have. Both are read-only edges used
by the critical-TCR gate (spec §6.7.2): `ShutdownModule.belowCritical(price)` and
`DutchAuctionHouse.inPurchase()`, two views. Neither new edge has a reverse: `ShutdownModule.wire`
and `DutchAuctionHouse.wire` do not take the RedemptionModule, and neither contract calls it. The
one contract that does hold the RedemptionModule's address, the VaultManager, stores it only for
the `Unauthorized` check on `redeemCollateral` and never calls it, and nothing else in §5 defines
a hook on the RedemptionModule — so no call cycle passes through it at run time. (The *address* graph was already cyclic and is why `wire` exists
at all — `VaultManager.wire` takes the RedemptionModule, which in turn takes the VaultManager.
Every address is known before any `wire` runs, so wiring order does not change: deploy all
contracts, then `wire` each one.)

The remaining ADR numbers are assigned as decisions arise; the number is not a sequence position
in the plan.
