# ADR-0006: Charge one fixed, per-second-compounded interest rate

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 06. Borrower-set rates (Liquity v2 style) make the redemption queue a
function of the rate each borrower chose, so the ordering key stops being a pure collateral ratio
and the comparison between A and B acquires a confound: a difference in liquidation outcomes could
come from the rate distribution rather than the mechanism.

A fixed rate also keeps the normalised-debt representation exact: one global index, debt stored as
`normDebt`, and NICR computed from it (`docs/spec.md` §2.4, §6.2).

## Decision

One immutable `RATE_PER_SECOND` (RAY), compounded per second through `rpow` with every product
rounded up (§2.3, R4, R5). Interest is minted on accrual (R6) and routed `POOL_SHARE_BPS` to the
stability pool in A, remainder to the reserve (§6.2, R7). No borrower chooses a rate, no borrowing
fee is charged at opening, and there is no rate controller.

## Alternatives considered

- **User-set rates.** Confounds the comparison, needs a per-position rate in the sort key, and
  makes redistribution arithmetic position-specific.
- **A utilisation or PID controller.** A second feedback loop inside the system under study; the
  sweep would measure the controller.
- **An opening fee instead of interest.** Does not price time, so holding a position through a
  quiet period is free and the liquidation experiment loses its carry cost.

## Consequences

- `index` is global and monotone; every position's debt is `mulDivUp(normDebt, index, RAY)` (R1).
- The rate is a swept parameter (S-scenarios), not a tuning knob: changing it changes borrower
  behaviour in the agents (P26), not the protocol's code.
- Interest accrues during shutdown-window freezes exactly once: accrual stops at the trigger
  (§6.11.1).
