---
name: gas-pass
description: Controlled gas optimisation pass, allowed only after correctness is established. Only when the user invokes it.
disable-model-invocation: true
---
Rules: correctness, readability of rounding logic, and invariant strength always beat gas.

1. Baseline: `just gas-update` on a clean tree; commit the snapshot if missing.
2. List candidates with estimated savings: caching storage reads in memory, packing storage
   (only fields updated together), `immutable`/`constant`, calldata over memory, custom errors,
   avoiding redundant SLOADs in loops, short-circuiting checks, removing dead code.
3. Forbidden: assembly, `unchecked` without a written proof, changing rounding helpers, merging
   functions in ways that obscure checks–effects–interactions, removing events or checks.
4. One optimisation per commit. After each: `just test`, `just test-nightly`, `just diff-long`,
   `just gas` diff. Revert any change that saves under 1% on its function and adds complexity.
5. Record each change with before/after numbers in `docs/gas.md`.
