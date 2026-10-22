# ADR-0012: Keep a Python model of the protocol and test it differentially

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 12. A sweep over scenarios, parameters and seeds is thousands of runs of
thousands of steps. Running each step through an EVM is too slow for the design of the study, but
replacing the contracts with an approximation would mean the report describes the approximation.

## Decision

A Python model mirrors the protocol exactly, and a differential test drives both the model and the
contracts on a local anvil with the same operation sequence, comparing state after every step. The
sweeps then run against the model alone (P29), with the differential test as the evidence that the
model is the contracts. The model is written from `docs/spec.md`, not from the Solidity, so a
mismatch is informative rather than a copy of the same bug; the shared vectors in `spec/vectors/`
are the common reference for both (D-19, `spec/vectors/README.md`).

Exactness and tolerance are specified separately in ADR-0022.

## Alternatives considered

- **EVM-only simulation.** Correct by construction, far too slow for the sweep design; it would
  force a drastic reduction in scenarios or seeds.
- **A model with no differential test.** Then nothing connects the report to the contracts.

## Consequences

- Every contract change ships with the matching model change in the same commit, with the
  differential test green (`CLAUDE.md`).
- The model is a second implementation to maintain, which is the price of the sweep.
- A differential mismatch is always a bug in one of the two or in the spec, never a tolerance
  question (ADR-0022).
