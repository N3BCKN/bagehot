# ADR-0024: Cap the gas forwarded to feed calls and check the gas left after a failure

- Status: accepted 2026-10-23 (P04 human gate). Superseded by ADR-0030
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Kit correction 4. `OracleAdapter` wraps each feed call in `try/catch` so that a reverting or
missing aggregator degrades into "price unusable" instead of bricking the protocol. Under EIP-150
a call receives at most 63/64 of the remaining gas, which turns that defence into an attack: a
caller who supplies just enough gas can make the inner call run out while the outer frame survives
to catch it. The adapter would then report a failure that did not happen — and a fabricated
failure is a liquidation blocked, or, repeated over `ORACLE_FAILURE_DURATION`, a shutdown
(`docs/spec.md` §6.11.1).

## Decision

Both feed calls are `staticcall`s with an explicit gas cap, `ORACLE_GAS`. After a failed call the
adapter requires `gasleft() >= ORACLE_POST_FAILURE_GAS` and otherwise reverts
`InsufficientGasForOracle()` (`docs/spec.md` §6.10.3). `ORACLE_POST_FAILURE_GAS` is a derived
parameter, at least `ceil(ORACLE_GAS / 63)`, checked by the constructor (§3.3 constraint 4): if
the inner call had been starved, the surviving outer frame cannot hold that much gas, so the only
way to observe a failure is for the feed to have genuinely failed. The failure clock
(`failureStart`, §4.8) therefore only advances on real failures.

## Alternatives considered

- **No gas cap.** A feed that consumes all gas takes the whole transaction down; the `try/catch`
  would protect nothing.
- **A cap with no post-failure check.** The 63/64 rule leaves the forgery open, which is the bug
  this correction names.
- **Requiring a minimum `gasleft()` up front.** Does not distinguish a starved inner call from a
  genuine failure after the fact, and over-constrains honest callers.

## Consequences

- Oracle failure cannot be forged by gas starvation, so the `ORACLE` shutdown trigger cannot be
  induced by a caller.
- `ORACLE_GAS` must be comfortably above a real Chainlink round read; too low a value turns honest
  reads into failures. It is an E parameter, retuned at P12 against measured gas.
- The adapter's branches (`oracle.json`, 20 vectors) include the gas rule; the Foundry tests must
  exercise it with explicit gas limits (P12).
