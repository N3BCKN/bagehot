# Shared test vectors

Worked numeric examples for every algorithm in `docs/spec.md`. The same files are consumed by
Foundry (`contracts/test/vectors/`, via `vm.readFile` + `vm.parseJson`) and by pytest (from P22).
A vector that fails on either side means the implementation, not the vector, is wrong — unless a
`/spec-change` says otherwise. Protected after the P02 gate.

## Provenance

Expected values were computed at P02 with exact Python integer arithmetic by a throwaway reference
implementation that transcribes the spec's pseudocode (every division through floor/ceil helpers or
an explicit carry). Nothing was computed by hand. Before generation the reference was fuzzed against
the spec's accounting identities (§10), and the spec-auditor independently recomputed a sample of
values from the spec formulas.

## Two levels

| `level` | Meaning | How to replay |
|---|---|---|
| `system` | A complete log of **public operations from deployment** — every position, deposit, transfer, warp and price is in `steps`. Reachable on a real deployment | Deploy with `inputs.params` at `inputs.t0`, fund each actor in `inputs.actors` with `inputs.actorWeth` WETH (and WETH allowances), replay `steps` in order, compare `expected` |
| `unit` | One algorithm or one contract driven directly, from the explicit initial state in `inputs` | Use a harness: e.g. SortedPositions with a mock key source, StabilityPool with a test VaultManager calling its hooks, OracleAdapter's decision with mock feeds, pure math |

## Format (version 2)

```json
{
  "file": "auction.json", "spec": "docs/spec.md §6.8", "version": 2, "description": "…",
  "vectors": [
    {
      "name": "partial_dust_and_paid",
      "level": "system",
      "note": "what the vector demonstrates and which spec section it exercises",
      "inputs":   { "variant": "B", "t0": "1000000", "params": { … }, "actors": [ … ], "actorWeth": "…" },
      "steps":    [ { "op": "buy", "phase": "act", "t": "1000060", "caller": "erin", …, "result": { … } } ],
      "expected": { "vault": { … }, "positions": { … }, "ledger": { … }, "token": { … }, "weth": { … }, … }
    }
  ]
}
```

- **Every integer is a decimal string** (uint256 values do not survive JSON numbers); signed values
  (e.g. `E` in `drift.json`, oracle answers) may be negative strings. Foundry:
  `vm.parseJsonUint` / `vm.parseJsonInt` / `vm.parseJsonString`; Python: `int(s)`.
- Every step has `"op"`. A step that reverts has `"revert": "<ErrorName>"` and no `result`; the
  state is unchanged by it. Otherwise `result` is what the operation returns or what its events
  carry.
- `t` is the **absolute** `block.timestamp` at which the step executes. `warp` steps carry `dt`
  (seconds added). System steps also carry `phase`: `setup` (building the scenario) or `act` (what
  the vector is about).
- System ops: `open`, `addCollateral`, `borrow`, `repay`, `close`, `liquidate`, `redeem`,
  `deposit`, `withdraw`, `buy`, `reset`, `cover`, `accrue`, `transfer` (ERC-20 stablecoin), `warp`,
  and `view.*` (read-only, records what a view returns). `caller` is `msg.sender`. Ops that use the
  oracle carry the `price` the oracle must report (usable) at that step. Hints are the exact values
  an off-chain helper would compute; a vector passing different hints says so in its note.
- Unit ops: `mulDiv`, `rpow`, `convert`, `accrue`, `insert`, `find`, `redistribute`,
  `hook.offset` (StabilityPool `offset` with the collateral already received), `hook.onInterest`
  (amount minted to the pool, then `onInterest`), `claim`, plus the system ops a harness exposes.
- `expected` in system vectors is a full snapshot after the last step. `weth` lists actor balances
  as deltas relative to `actorWeth`, and contract balances as absolute values. `S` / `G`
  accumulators are keyed `"epoch:scale"`.
- `trace` arrays are human-readable descriptions of loop decisions (redemption visits, hint walks).
  Implementations assert the outcome fields, not the trace text.
- **Oracle in system vectors.** `inputs.params` carries every constructor parameter of §3.1,
  including the oracle and shutdown ones (the deploy-script inputs `ANNUAL_RATE`,
  `BASE_RATE_HALF_LIFE`, `AUCTION_HALF_LIFE` appear only through their derived values). The price feed is a mock with `FEED_DECIMALS = 8`; before each step that
  carries a `price`, it is set to `answer = price / 10^10` (every such price is a multiple of
  `10^10`) with `updatedAt = t` of that step. The sequencer feed is a mock reporting
  `answer = 0` and `startedAt = t0 − GRACE_PERIOD − 1` for the whole vector, so every price read is
  usable. Steps without a `price` do not read the oracle.
- In `oracle.json` a `price` of `"0"` means "no price" (the decision is unusable); `fetchPrice`
  would return `lastGoodPrice` in that case.
- `drift.json` steps carry `drift`: the I2 counters `N`, `X`, `Y`, the exact `E`, and its bounds.

## Files

| File | Spec | Vectors |
|---|---|---|
| `math.json` | §2.2, §2.3, §3.1–3.2 | mulDiv, rpow with multiplication trace, derived constants (unit) |
| `interest.json` | §6.2, §8 | accrual with pool share / below `MIN_DEPOSIT` / deployment B, frequency effect, conversions (unit) |
| `oracle.json` | §6.10.1 | every row of the decision table, boundaries, overflow-safe scaling, lazy reads (unit) |
| `sorted_list.json` | §6.3 | order with ties, hint validation, walks, `StaleHint`, `excludeId` semantics (unit) |
| `redistribution.json` | §6.4, §6.5 | liquidation into redistribution with snapshot stake; stakes after the last liquidation (system); error carry (unit) |
| `liquidation_pool.json` | §6.4, §6.6.4 | with / without surplus, underwater, partial absorption, empty pool, no-stakes deficit (system) |
| `product_sum.json` | §6.6, §5.3 | deposits, offsets, interest, scale change, epoch change, gains, dust sweep (unit, pool with a test vault); a deposit after a long idle period gets none of the idle interest (system) |
| `redemption.json` | §6.7 | skip / full / partial, `MIN_DEBT` stop, stale-hint cancel, base-rate decay and fee, single-node partial, the critical-TCR gate, a partial cancelled because it would leave the position below MCR (system) |
| `auction.json` | §6.8 | start and price curve with the cusp at t = 793/794; partial + dust rule + `NoPartialPurchase` + paid tab; reset tip and shortfall (system) |
| `deficit.json` | §6.9 | shortfall then cover from interest (system) |
| `shutdown.json` | §6.11 | pro-rata claims, order independence (unit) |
| `drift.json` | §10.2 | I2 drift after every operation in A and B (system) |

## Adding a vector

Only through `/spec-change`: the new vector must pass on both sides (Foundry and pytest) in the
same commit, and its values must come from a script, never from hand arithmetic.
