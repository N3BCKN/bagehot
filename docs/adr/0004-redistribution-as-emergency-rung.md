# ADR-0004: Redistribute what the strategy cannot absorb, before recording a deficit

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 04, and the human decision at the P02 gate (`docs/spec.md` D-1). A
liquidation can leave a remainder: in A the pool may hold less than the debt being offset, in B an
auction may end with collateral exhausted and debt unpaid. Something must happen to that
remainder, and the choice decides whether the system stays solvent after the pool is drained.

The blueprint left socialisation as an open question (§11.3, Q1) with both variants "implemented
and measured". The P02 gate closed it: two code paths would double the test surface and make the
A/B comparison depend on a third flag.

## Decision

The waterfall is: collateral → penalty → strategy → redistribution → deficit ledger → shutdown
(`docs/spec.md` §1.1, §6.4). In deployment A, what the pool cannot absorb is redistributed to all
other active positions through the `LColl`/`LDebt` accumulators (§6.5), with error carries and the
stake snapshot rule. A deficit is recorded only when no stake remains to redistribute to (§6.4.4,
R27). In deployment B the auction shortfall goes straight to the deficit ledger (§6.9), because
there is no pool to absorb it first.

## Alternatives considered

- **Immediate deficit, no redistribution.** Simpler, but the first liquidation that exceeds the
  pool makes the system undercollateralised in one step, and the deficit trigger (§6.11.1) would
  fire on events the system could have absorbed.
- **A socialisation flag, both behaviours measured.** Rejected at the P02 gate: it is a third
  mechanism, and every invariant and vector would need two versions.

## Consequences

- Solvency survives a drained pool: surviving borrowers inherit both debt and collateral
  (§10.3 bucket inequalities).
- Borrowers carry a risk they did not choose. That cost is part of what the report measures for A.
- The redistribution accumulators are the hardest arithmetic in the system (D-18, D-24); they need
  the stake snapshot rule and carried errors to stay exact.
