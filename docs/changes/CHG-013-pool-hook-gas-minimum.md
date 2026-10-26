# CHG-013: `POOL_HOOK_GAS`'s lower bound must satisfy CHG-006's own rule

- Status: **approved by the human 2026-10-26** ("aproved, files unlocked, please proceed"; proposed the same day, P19 security review, finding L-1). Code, model and tests applied; the spec/invariant text awaits the protected-paths unlock.
- Affects: `docs/spec.md` §3.1 (`POOL_HOOK_GAS` range) and §3.4 (VaultManager index 8); the
  VaultManager constant `MIN_POOL_HOOK_GAS`; the constructor-range test; `StabilityPoolGasTest`
  (asserts the minimum too). No model or vector change.

## Problem

CHG-006 / ADR-0033 set the rule: `POOL_HOOK_GAS` is **at least twice the real pool's measured
worst-case `onInterest`**. The measured worst case is **86,981 gas**
(`StabilityPoolGasTest.test_gas_onInterest_worstCase_freshEpoch` and `…_freshScale`: every slot cold
via `vm.cool`, a fresh `(epoch, scale)` sum `G`, the carry `lastInterestError` and
`interestGainsBalance` all written from zero; the figure includes the 2,600 of the cold account
access, so it is conservative). Twice that is **173,962**.

The constructor accepts `[50_000, 1_000_000]` (the range copied from `ORACLE_GAS`). The default,
200,000, satisfies the rule; any value in `[50,000, 173,961]` does not, and values below ~87,000 make
the first booking in every fresh `(epoch, scale)` run out of gas at the full cap. That failure leaves
far more than the 6,350 floor, so it is *redirected*, not reverted; the pool's state rolls back, the
next accrual meets the same zero slots, and depositors silently lose all interest — forever, or
after every scale or epoch change.

## Options

1. **Raise the lower bound to 175,000** (recommended): `≥ 173,962` with a little margin, and still a
   round, auditable constant. Range `[175_000, 1_000_000]`; floor at the bound `ceil(2·175,000/63) =
   5,556`.
2. **Derive the bound in the constructor from a measurement.** Not possible on-chain without
   executing the pool's worst case; rejected.
3. **Keep 50,000 and document the misconfiguration risk.** The parameter is an "E" (engineering)
   parameter a sweep may vary; a silent total loss of depositor interest inside the valid range is
   not acceptable — rejected.

## Exact wording (option 1)

### `docs/spec.md` §3.1, the `POOL_HOOK_GAS` row — the "Valid range" cell

`[175_000, 1_000_000]` (was `[50_000, 1_000_000]`); and append to the "Meaning" cell: "The lower
bound is CHG-006's rule applied to that measurement (≥ 2 × 86,981 = 173,962, CHG-013); re-measure if
`onInterest` changes."

### `docs/spec.md` §3.4, the VaultManager constructor row

`8: 175_000 ≤ x ≤ 1_000_000` (was `8: 50_000 ≤ x ≤ 1_000_000`).

### Code and tests

- `VaultManager.MIN_POOL_HOOK_GAS = 175_000`.
- `VaultManagerPoolHookTest.test_constructor_poolHookGasRange`: `174_999` reverts `InvalidParameter(8)`,
  `175_000` passes (floor 5,556), `1_000_000` passes, `1_000_001` reverts.
- `StabilityPoolGasTest`: assert `2 × measured ≤ VaultManager.MIN_POOL_HOOK_GAS()` as well as the
  default, so a pool change that raises the worst case fails a test before it can be deployed with a
  too-small cap.
- Triage row SA-155 (`MIN_POOL_HOOK_GAS` literal): text updated to 175,000.

## Impact

Spec §3.1, §3.4; VaultManager constant; two tests; one triage row. Default deployments (200,000) are
unaffected. Experiments: none have run.
