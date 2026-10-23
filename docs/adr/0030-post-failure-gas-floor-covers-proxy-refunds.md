# ADR-0030: Set the post-failure gas floor to ceil(2·ORACLE_GAS/63), capped at ORACLE_GAS

- Status: accepted 2026-10-23 (human)
- Date: 2026-10-23
- Prompt: P12, applied via `/spec-change` CHG-004 (approved by the human, conditional on two checks
  that passed)
- Supersedes: ADR-0024 — its bound only; the mechanism (a gas cap on each feed call and a
  `gasleft()` check after a failed one) is restated here unchanged

## Context

ADR-0024 set `ORACLE_POST_FAILURE_GAS ≥ ceil(ORACLE_GAS / 63)` on the argument that a feed call
starved by its caller leaves the outer frame less than `ORACLE_GAS / 63`. That holds for a feed that
is a single contract. Chainlink feeds are proxies: `EACAggregatorProxy` makes a high-level call into
the aggregator, which forwards all but 1/64 of the proxy's gas. When the inner call starves, the
proxy reverts and **returns the 1/64 it kept**, so the adapter holds its own reserve (< F/63) plus
the proxy's (< F/64), where F ≤ `ORACLE_GAS` is what it forwarded. A chain of k nested bubbling
calls returns at most F/64 + F/64² + … < F/63, so after a starved read the adapter holds
**less than 2·ORACLE_GAS/63**, at any proxy depth.

Measured at P12 on Base's real ETH/USD proxy (fork at block 45,198,666; the proxy's deployed
bytecode kept, only the aggregator behind it replaced by an honest but expensive one with `vm.etch`):

| ORACLE_GAS | gas left after a starved read (max) | old floor ceil(C/63) | new floor ceil(2C/63) |
|---|---|---|---|
| 100,000 | 2,816 | 1,588 — crossed | 3,175 — holds |
| 1,000,000 | 28,734 | 15,874 — crossed | 31,747 — holds |

Adversarial sweep on the same real proxy, feed needing 900k at `ORACLE_GAS` = 1M: 789 of 825 caller
gas limits forged a recorded failure at 15,874; 0 at 31,747. At the start parameters (100k), none at
either floor, because writing `failureStart` (~22k) is out of reach. Also: the floor had no upper
bound, so a misconfigured value could make every genuine failure revert and the ORACLE shutdown
unreachable. Full evidence: `docs/changes/CHG-004-oracle-post-failure-gas-bound.md`.

## Decision

- `ceil(2 · ORACLE_GAS / 63) ≤ ORACLE_POST_FAILURE_GAS ≤ ORACLE_GAS`, enforced by the OracleAdapter
  constructor at argument index 7 (`InvalidParameter(7)`). Start value **3,175** (`ORACLE_GAS` =
  100,000).
- The mechanism is unchanged: each feed call is a `staticcall` capped at `ORACLE_GAS`; after a
  failed call, `gasleft() < ORACLE_POST_FAILURE_GAS` reverts `InsufficientGasForOracle()`.
- Spec §6.10.3 states the gas model with the proxy refund term, not only the number.

## Consequences

- A caller cannot forge an oracle failure by starvation for any feed structure, at any
  `ORACLE_GAS` in its range — the regression sweeps (`OracleAdapterGasTest`, mock proxy, every
  `just test`; `OracleGasRuleForkTest`, real proxy, `just test-fork`) must stay at zero forgeries.
- Honest callers: measured unaffected in the normal case — one `fetchPrice` per transaction, or a
  feed that fails by reverting — because fetchPrice's own work after a failed read (two cold
  storage reads, ~4.2k) exceeds the floor anyway. The floor binds only on a second `fetchPrice` in
  the same transaction, with the failure clock already running and a feed that burns its whole cap:
  there the caller needs 1,587 more gas, and in that band gets `InsufficientGasForOracle`, a
  retryable revert — never a wrong answer (`test_gasRule_newFloor_*`).
- The cap (`≤ ORACLE_GAS`) rules out a floor no caller can meet.
- Every system vector's `inputs.params.ORACLE_POST_FAILURE_GAS` changes from "1588" to "3175"; no
  expected value changes (gas is not modelled).
- Reversing it means restoring the single-contract assumption, which the fork measurement shows is
  false for the feeds the protocol actually reads.

## Alternatives considered

- **Keep ceil(ORACLE_GAS/63)** and rely on the ~22k `failureStart` write to keep forgeries out of
  reach. Rejected: true only for small `ORACLE_GAS`; the real proxy forges at 1M, inside the range;
  and with the clock already running no write is needed, so ShutdownModule.check could be handed a
  starved `usable = false` that passes the old floor.
- **Require the full cap up front** (`gasleft() ≥ ceil(ORACLE_GAS·64/63)` + overhead before each
  feed call), making starvation impossible. Rejected: ~2 × 102k gas of headroom on every priced
  operation, for a configuration the start parameters never reach.
- **Deploy-script assertion only** (feeds' cold read ≤ ORACLE_GAS/2). Rejected as the sole defence:
  leaves the spec's argument false and protects only the deployments that remember to run it.
