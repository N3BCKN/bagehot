# ADR-0025: Calibrate liquidator latency with survival analysis, not with observed means

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Kit correction 6. The liquidator agent (P27) needs a distribution of the delay between "a position
becomes liquidatable" and "somebody liquidates it". The obvious estimator — average the observed
delays from Base history (P08) — is biased, because the sample only contains positions that were
eventually liquidated inside the observation window.

The data are **right-censored**: windows that closed because the price recovered, and windows
still open at the end of the extract, have no event time. Dropping them throws away exactly the
observations that carry information about long delays, and the mean of what remains understates
latency precisely in the regime the study cares about — the stressed one, where liquidations are
slow or do not come at all.

## Decision

Latency is estimated with survival analysis: a Kaplan–Meier estimator of the survival function of
the liquidatable window, with censored observations kept and marked. P08 extracts, for every
liquidatable window, the start, the event time if any, and the censoring reason. P27 fits the
agent's latency distribution to that estimate and reports it with confidence bands. The agent
draws its delay from the fitted distribution, conditioned on the covariates the preregistration
names (position size, gas regime, depth of the shortfall).

## Alternatives considered

- **Mean of observed delays.** Biased low by construction; the bias is largest in the stress
  regime that dominates the results.
- **Treat censored windows as "liquidated at the end of the window".** Biased in the other
  direction, and invents events.
- **A fixed latency parameter swept over a grid.** Keeps the sweep honest but discards the data;
  retained as a robustness check alongside the fitted distribution, not as the primary model.

## Consequences

- P08's extraction must record censoring, which constrains its schema before any fitting happens.
- The preregistration (P05/P30) fixes the estimator and the covariates before the first sweep.
- A latency claim in the report always comes with the censoring share it was estimated from.
