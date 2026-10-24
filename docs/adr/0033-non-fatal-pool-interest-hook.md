# ADR-0033: A failing stability pool cannot stop accrual; its interest share falls back to the reserve

- Status: proposed
- Date: 2026-10-24
- Prompt: P15 (found by the security review, F4), decided 2026-10-24, applied at P19 via
  `/spec-change` CHG-006
- Supersedes: —

## Context

Accrual (§6.2) runs at the start of every normal-mode operation. That includes the rescue paths
`repay`, `addCollateral` and `close`, liquidation, and `ShutdownModule.check`, which accrues before it
calls `onShutdown`. Accrual calls the stability pool's `acceptsInterest` and `onInterest`. A revert in
either blocks every operation **and** the shutdown trigger, so the window where the rescue paths stop
depending on the pool is never reached. The protocol is then permanently dead.

One cause is already accepted by the spec. §6.6.3 lets the pool's `G` accumulator overflow after
≥ 338 adversarial events in one `(epoch, scale)`, or ≥ 10^8 at realistic sizes. That acceptance was
written when an overflow meant a broken pool, not a broken protocol. Any future bug in the pool's
interest path would have the same effect. Full text, evidence and wording:
`docs/changes/CHG-006-non-fatal-pool-interest-hook.md`.

## Decision

- **One guarded call.** Accrual makes a single call to the pool, `onInterest(offered) returns (bool booked)`,
  replacing the `acceptsInterest` + `onInterest` pair.
  - It is a fixed-shape assembly `call` (ADR-0029 pattern) with gas `POOL_HOOK_GAS`.
  - Return data is accepted only if it is exactly 32 bytes holding 0 or 1.
  - The pool returns `false` without changing state when deposits are below `MIN_DEPOSIT`.
- **On failure, the reserve takes the share.** If the call reverts, runs out of gas or returns
  anything malformed, the offered amount goes to the reserve and `PoolInterestRedirected(offered)` is
  emitted. The pool is minted only after it has booked the amount.
- **Gas rule** (the CHG-004 / ADR-0030 argument, applied to this call). After a failed call, accrual
  requires `gasleft() ≥ ceil(2·POOL_HOOK_GAS / 63)` or reverts `InsufficientGasForPoolHook`.
  - A caller who under-supplies gas therefore reverts their own transaction and cannot fake a pool
    failure.
  - `POOL_HOOK_GAS` is a new immutable VaultManager argument in `[50_000, 1_000_000]`.
  - Its value is derived at P19 from a measurement of the real pool's worst-case `onInterest`, at
    least twice that cost. The floor is derived from it, not a second parameter.
- **The ledger hook stays a plain call.** `deficitLedger.onInterest` and `token.mint` remain ordinary
  calls; their revert causes are closed and unreachable by any caller (CHG-006, "The fallback path
  must not be a new single point of failure").
- **P19 acceptance criteria.** The human's three conditions become named criteria of P19:
  - P19-AC-CHG006-1: the fallback path cannot revert;
  - P19-AC-CHG006-2: under-supplying gas cannot fake a failure;
  - P19-AC-CHG006-3: this ADR is accepted before the spec text changes.

## Consequences

- Rescue paths, liquidation and the shutdown trigger no longer depend on the pool being correct, for
  any failure cause, known or unknown.
- A `G` overflow now costs depositors their interest share for the rest of that `(epoch, scale)`. It
  no longer costs the protocol its liveness. §6.6.3's "Accepted" paragraph is reworded to say so.
- **Remaining revert path: the supply cap.** Accrual can still revert only through
  `SupplyCapExceeded`. That needs total debt near `2^128 − 1` wei, which only decades of compounding
  interest can produce. It is a fixed horizon like the index overflow (§2.2), and no caller can bring
  it closer.
- **Accounting is unchanged.** I1 and I2 keep their formulas, since `toPool + toReserve = interest` in
  every branch and nothing is minted to a pool that did not book. One VaultManager constructor
  argument and one event are added.
- **Interest can be redirected only by a pool that genuinely fails.** Depositors lose interest only to
  a genuine pool failure, never to a caller's gas choice.
- **Tests change.** P15's F4 test flips from "a reverting pool blocks `repay`" to "a reverting pool's
  share is redirected and `repay` succeeds". `HostileInterestSink` gains the malformed-return and
  gas-burning modes.

## Alternatives considered

- **Prove the pool non-reverting at P19, with no change to accrual** (option 2). Make `S`/`G`
  overflow impossible instead of accepted, and require a proof that `onInterest` cannot revert in any
  reachable state.
  - Rejected as the sole fix: it covers only the failure causes known today.
  - Liveness of every rescue path would rest on the correctness of a proof about another contract,
    including every future edit to it.
  - The P19 pool should still avoid overflow where it cheaply can. That is good practice, not the
    guarantee.
- **Accept the risk as documented** (option 3). Rejected outright. The probability is very low, but
  the consequence is total, irreversible loss of every rescue path and of the shutdown trigger, and a
  low probability does not justify an unbounded, unrecoverable consequence.
- **Solidity `try/catch` instead of an assembly call.** Rejected for these reasons:
  - `try/catch` reverts the caller when return data does not decode, so a pool returning the wrong
    shape would still brick accrual.
  - Copying unbounded revert data costs memory gas the caller pays.
  - ADR-0029 already chose a fixed-shape assembly call for the oracle for the same reasons.
- **Keep two calls (`acceptsInterest` view, then `onInterest`) and guard both.** Rejected: it creates
  two failure paths and two gas rules for one decision. A starved `acceptsInterest` would redirect
  interest exactly as a starved `onInterest` would.
- **Guard with a pre-call check (`gasleft() ≥ POOL_HOOK_GAS · 64/63 + margin`) instead of a
  post-failure floor.** Rejected for these reasons:
  - It also defeats starvation, but it needs a margin for the gas spent between the check and the
    call, and that margin is compiler-dependent.
  - It charges every accrual the full forwarded amount up front.
  - The post-failure floor reuses the argument ADR-0030 already proved and measured on a real proxy,
    and costs nothing on the success path.
- **Also guard the ledger hook and the mints.** Rejected: there is nowhere to send the interest if
  the reserve also fails, and their revert causes are closed. Skipping the mint would break I2. A
  silent catch would hide a real bug that the supply-cap horizon makes unreachable anyway.
