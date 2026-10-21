---
name: invariant-testing
description: How Bagehot writes Foundry invariant tests, handlers, ghost variables, Medusa properties and Halmos checks. Use whenever creating or editing files in contracts/test/, especially invariant, symbolic or fuzz tests.
user-invocable: false
paths: "contracts/test/**"
---
## Handler pattern
- One `Handler` per deployment variant in `test/invariant/handlers/`. Actors: a fixed set of
  addresses created in `setUp`, each funded with WETH via `deal`.
- Each action: choose actor with `bound(seed, 0, actors.length-1)`, bound inputs to the protocol's
  meaningful domain (min debt, collateral limits, price moves of at most ±30% per step, time
  warps 1 s to 7 days), call inside `try/catch`, and update ghost variables only on success.
- Count expected vs unexpected reverts in ghost counters keyed by error selector. Unexpected
  reverts fail a dedicated invariant `invariant_noUnexpectedReverts`.
- Ghost variables track what contracts do not store: total minted, total burned, total WETH in,
  total WETH out, per-actor deposits. Invariants compare contract state with ghosts.
- Liveness checks (I9) live in handler actions: assert that repay/addCollateral succeed whenever
  the system is not settled.

## Invariant functions
- Name `invariant_I<n>_<shortName>`; one property per function; message strings that print the
  values compared.
- Exact equality unless `docs/invariants.md` defines a tolerance with a derived bound.
- Use `afterInvariant()` for expensive global checks if needed.

## Configuration
- PR profile: runs 256, depth 200; nightly: runs 4096, depth 500 (`FOUNDRY_PROFILE=nightly`).
- `fail_on_revert = false`; reverts are policed by the counter invariant above.
- Medusa: same handler compiled via crytic-compile; properties as `property_*` functions that
  call the same check helpers; corpus directory committed under `test/invariant/medusa/corpus`
  only if small.

## Halmos
- `test/symbolic/*Symbolic.t.sol`, functions `check_*`. Target pure/arithmetics properties:
  rounding bounds, single-operation conservation, pro-rata sum ≤ total. Keep loops out; bound
  inputs with `vm.assume` only to the domain the spec defines.

## Shared vectors
- `spec/vectors/*.json` are loaded with `vm.readFile` + `vm.parseJson`; the same files feed pytest.
  Adding a vector requires it to pass on both sides.

## When something fails
- Use `/debug-invariant`. Never weaken bounds or tolerances to get green.
