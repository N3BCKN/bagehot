# ADR-0018: Pin solc 0.8.28 with `evm_version = cancun` and transient reentrancy guards

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §18.1. Two deployments must be comparable across the whole study, and the differential
test (ADR-0012) only means something if the bytecode under test does not move between runs. A
floating pragma or an unpinned toolchain makes a green CI run and a green local run two different
statements.

Base supports Cancun, which gives transient storage (EIP-1153). The reentrancy locks this design
needs are per-transaction, which is exactly what `ReentrancyGuardTransient` provides at a fraction
of the storage-slot cost — and the auction's `inPurchase` flag (`docs/spec.md` §6.8.4) is itself a
transient flag, read by `ShutdownModule.check` and by `redeem`.

## Decision

`solc_version = "0.8.28"` and `evm_version = "cancun"` pinned in `contracts/foundry.toml` (done at
P00); every source file carries `pragma solidity 0.8.28;` without a caret. Reentrancy protection
uses OpenZeppelin's `ReentrancyGuardTransient`. The Foundry version, the OpenZeppelin revision and
every analysis tool are pinned too, with versions recorded in `docs/dependencies.md` and repeated
in the CI workflows.

## Alternatives considered

- **A caret pragma (`^0.8.20`).** Lets the compiler move under the project; gas snapshots and the
  bytecode in `deployments/` would stop being reproducible.
- **Paris or Shanghai EVM.** No transient storage, so the locks cost storage slots and the auction
  callback flag becomes persistent state that must be cleared on every path.
- **A newer solc.** Chosen against at P00 for soak time: 0.8.28 has had longer exposure to the
  analysis tools this project gates on.

## Consequences

- A compiler bump is a deliberate change with a new ADR, a fresh gas snapshot and a re-run of the
  static-analysis triage.
- The contracts cannot be deployed to a chain without EIP-1153.
- `just check` locally and CI compile the same bytecode.
