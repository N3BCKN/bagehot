# ADR-0037: `POOL_HOOK_GAS` may not be set below 175,000

- Status: proposed 2026-10-27 (records CHG-013, approved by the human 2026-10-26)
- Date: 2026-10-27
- Prompt: P19 (security review, finding L-1); spec text applied at P21's close
- Supersedes: —

## Context

ADR-0033 (CHG-006) makes accrual's call into the stability pool non-fatal. It forwards
`POOL_HOOK_GAS` and sets the rule that the value is at least twice the real pool's measured
worst-case `onInterest`. At P19 that worst case measured 86,981 gas (every slot cold and a fresh
`(epoch, scale)` sum; `StabilityPoolGasTest`).

The constructor accepted `[50_000, 1_000_000]`, so values in the range broke ADR-0033's own rule.
Below about 87,000, the first booking in every fresh `(epoch, scale)` runs out of gas. That failure is
redirected rather than reverted, so depositors silently lose all interest, for good or after every
scale or epoch change. `POOL_HOOK_GAS` is an engineering parameter that a sweep may vary.

## Decision

The valid range is `[175_000, 1_000_000]` (`VaultManager.MIN_POOL_HOOK_GAS = 175_000`): at least
2 × 86,981 = 173,962, rounded to an auditable constant. `StabilityPoolGasTest` asserts
`2 × measured ≤ MIN_POOL_HOOK_GAS`, so a pool change that raises the worst case fails a test before it
can be deployed with a cap that is too small.

## Consequences

- The default deployment (200,000) is unaffected. The post-failure floor at the bound is 5,556.
- Re-measure and, if needed, raise the bound through a new ADR whenever `onInterest` changes.
- Spec §3.1 and §3.4; full reasoning in `docs/changes/CHG-013-pool-hook-gas-minimum.md`.
