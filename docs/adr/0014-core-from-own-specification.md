# ADR-0014: Write the core from our own specification rather than forking a reference protocol

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 14. Forking an existing CDP protocol would be faster and safer. It would
also make the project a deployment exercise: the mechanisms under comparison would be inherited,
their parameters would be someone else's, and any surprising result would most likely be a
property of the fork rather than of the mechanism.

The project's output is a report about mechanism behaviour, which requires the freedom to
instrument, to change one rule at a time and to know exactly what every rounding direction does.

## Decision

The core is written from `docs/spec.md`, which is written first and wins over the code. Ideas are
taken from the literature and from Liquity v1's product–sum and sorted-list designs, but no code
is copied; where this design departs from the blueprint or from the reference designs, §12 records
the deviation and the reason. OpenZeppelin is used for ERC-20, `Math.mulDiv`, `SafeERC20` and the
transient reentrancy guard (ADR-0017, ADR-0018) — audited primitives, not protocol logic.

## Alternatives considered

- **Fork Liquity v1 or a similar protocol.** Inherits design decisions and their undocumented
  reasons; instrumenting it would mean editing code nobody here specified.
- **Write with no specification, document afterwards.** The differential test and the shared
  vectors both need a normative source that predates both implementations.

## Consequences

- Every mechanism in the report can be explained from one document.
- More defects than a fork would have. The mitigation is the invariant suite (P03, P17), Medusa
  and Halmos campaigns (P37), the differential test (ADR-0012) and the review agents.
- The spec is a protected artefact: changing it needs `/spec-change` and a new ADR when a decision
  moves.
