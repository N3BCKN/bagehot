# ADR-0013: Preregister the analysis and bootstrap over blocks

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 13. A parameter study with free choice of metrics and cutoffs can be tuned
until it says something. The defence is to fix the hypotheses, the metrics, the scenarios and the
stopping rule before the first sweep, and to say so.

The second problem is dependence: liquidations, prices and gas within one episode are strongly
autocorrelated, so treating steps as independent observations overstates precision.

## Decision

`docs/preregistration.md` is frozen before the first sweep; afterwards it changes only by dated
addendum (`CLAUDE.md`). It fixes the hypotheses, the metrics, the scenarios S1–S9, the parameter
grids and the decision rules. Uncertainty is quantified by a block bootstrap over contiguous
blocks of the price path, not by i.i.d. resampling. Results that contradict a preregistered
hypothesis are reported as such; re-tuning to "fix" them is forbidden.

## Alternatives considered

- **Free exploration, report what is interesting.** Produces a result for any data set.
- **i.i.d. bootstrap.** Understates variance for autocorrelated paths; confidence intervals would
  be too narrow.

## Consequences

- The preregistration is a gate (P30) and a protected file afterwards.
- Some analyses will be impossible because they were not preregistered; they go in a clearly
  labelled exploratory section.
- Every reported interval names its bootstrap block length.
