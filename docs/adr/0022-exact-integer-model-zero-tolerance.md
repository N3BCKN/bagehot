# ADR-0022: Write the Python model with exact integers and test differentially at zero tolerance

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Kit correction 5, and ADR-0012, which establishes the model and the differential test. This
decision fixes what "agreement" means. A tolerance of even one wei would hide exactly the class of
bug the project cares about: a rounding direction applied the wrong way, an error carry dropped,
an index advanced twice. Those show up as differences of a few wei that then accumulate.

Floating point would make a tolerance unavoidable: no float can represent 1e27-scaled interest
indices exactly.

## Decision

The model holds protocol state in Python `int` only — no floats, no `Decimal`, no NumPy dtypes in
protocol code (`CLAUDE.md`; floats are allowed in agents, statistics and plots, which are not
protocol state). It implements the same `mulDivDown`/`mulDivUp` helpers and the same `rpow` as the
contracts (ADR-0017), and follows the order of operations of `docs/spec.md`, including the order
of checks, because the differential test compares revert reasons by name.

The differential harness (Hypothesis state machine, P23) drives both sides with the same operation
sequence against a local anvil and asserts **exact equality** of every compared quantity after
every step. There is no tolerance parameter. A mismatch is a bug in the model, in the contracts or
in the spec, and is triaged with `/diff-mismatch`.

## Alternatives considered

- **A small absolute tolerance.** Hides systematic rounding errors until they are large, by which
  time the cause is many steps back.
- **Compare only final states.** Loses the step that caused the divergence.

## Consequences

- Every contract change ships with the model change in the same commit, differential green.
- The shared vectors (`spec/vectors/`) are the third party both sides agree with, which catches
  the case where model and contracts are wrong in the same way.
- Model performance is bounded by Python integers; the sweep design (P29) accounts for it.
