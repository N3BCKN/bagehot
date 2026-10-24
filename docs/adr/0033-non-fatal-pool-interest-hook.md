# ADR-0033: A failing stability pool cannot stop accrual; its interest share falls back to the reserve

- Status: accepted 2026-10-24 (human)
- Date: 2026-10-24
- Prompt: P15 (found by the security review, F4), decided by the human 2026-10-24 (open issue P15-1,
  option 1), applied at P19 via `/spec-change` CHG-006
- Supersedes: —

## Context

Accrual (§6.2) runs at the start of every normal-mode operation. That includes:
- the rescue paths `repay`, `addCollateral` and `close`;
- liquidation;
- `ShutdownModule.check`, which accrues before it calls `onShutdown`.

Accrual calls the stability pool twice, `acceptsInterest()` and then `onInterest(toPool)`. A revert in either blocks every one of those operations **and** the shutdown trigger. The shutdown window, where the rescue paths stop depending on the pool, can then never be reached, and the protocol is permanently dead.

One cause is already accepted by the spec. §6.6.3 lets the pool's `G` accumulator overflow after ≥ 338 adversarial events in one `(epoch, scale)`, or ≥ 10^8 at realistic sizes. That acceptance was written when an overflow meant a broken pool, not a broken protocol. Any future bug in the pool's interest path, known or not, would have the same effect.

`VaultManagerInterestHooksTest.test_F4_revertingPool_blocksNormalMode_notTheWindow` pins today's behaviour. Full evidence and the proposed spec text are in `docs/changes/CHG-006-non-fatal-pool-interest-hook.md`.

## Decision

### 1. One guarded call to the pool

Accrual makes a single call, `stabilityPool.onInterest(offered) returns (bool booked)`, replacing the `acceptsInterest()` + `onInterest()` pair:
- `offered = mulDivDown(interest, POOL_SHARE_BPS, BPS)` (R7).
- The pool returns `false` without changing state when `totalDeposits < MIN_DEPOSIT` (what `acceptsInterest() == false` meant). Otherwise it books the amount and returns `true`. `acceptsInterest` stays as a view for off-chain readers; accrual no longer calls it.
- The call is a fixed-shape assembly `call`, the pattern ADR-0029 approved for the oracle:
  - gas forwarded: `POOL_HOOK_GAS`;
  - return data copied only if it is exactly 32 bytes;
  - decoded only if that word is 0 or 1.
- `ok = false` when the call reverts, runs out of gas, returns any other size, or returns any other word.

| Outcome | Interest | Event |
|---|---|---|
| booked (`ok` and `booked`) | the pool is minted `offered` **after** it booked it | — |
| declined (`ok` and not `booked`) | `offered` goes to the reserve | none (normal operation) |
| failed (`not ok`, after the gas rule below) | `offered` goes to the reserve | `PoolInterestRedirected(offered)` |

Minting only after booking keeps the pool's I1: a failed call is rolled back, so `G` is unchanged, and nothing was minted to it. Between booking and minting no external call runs; `onInterest` stays call-free (§5.10).

### 2. A reasoned gas cap on the call, so a caller cannot fake a pool failure

**The attack.** A caller of any accruing operation picks a gas limit so that `onInterest` runs out of gas inside. The failure path then sends the pool's share to the reserve, and the rest of the transaction still completes. The attacker gains nothing directly, but can strip depositors of their interest at will. This is the pattern CHG-004 found in the OracleAdapter.

**The rule.** After a failed call, accrual requires `gasleft() ≥ ceil(2 · POOL_HOOK_GAS / 63)` or reverts `InsufficientGasForPoolHook()`.

**Why this bound** (the ADR-0030 argument, applied to this call). The call forwards `F = min(POOL_HOOK_GAS, ⌊63/64 · available⌋)` (EIP-150). After a call that failed because the caller supplied too little gas (a starved call), the VaultManager holds:
- its own reserve, `available − F`, which is below `F/63` exactly when the call was starved;
- whatever the callee hands back. The pool makes no nested call, but the bound does not rely on that: a chain of k bubbling calls returns at most `F/64 + F/64² + … < F/63`.

So after a starved call `gasleft() < 2F/63 ≤ 2 · POOL_HOOK_GAS/63`, and the check turns every starved call into a revert of the whole transaction instead of a redirection.

A genuine failure leaves at least the floor:
- an early revert (overflow, panic, a bug) hands back almost all of `F`;
- burning the whole cap happens with the caller having supplied more than `POOL_HOOK_GAS · 64/63 + ceil(2 · POOL_HOOK_GAS/63)`, so the floor remains.

Both pass the check and are redirected.

**The cap is an explicit parameter, not a default.** `POOL_HOOK_GAS` is a new immutable VaultManager constructor argument:
- range `[50_000, 1_000_000]`, as `ORACLE_GAS`;
- its value is derived at P19 from a measurement of the real pool's worst-case `onInterest`: cold storage, a new `(epoch, scale)` slot and a non-zero carry. It is at least twice that cost, and the measurement and derivation are written next to the value in §3.1;
- the floor `ceil(2 · POOL_HOOK_GAS / 63)` is derived, not a second parameter, because nothing about this call needs it tuned separately;
- in deployment B (`stabilityPool == address(0)`) the parameter is range-checked but unused.

### 3. The fallback path cannot itself revert

With the pool guarded, accrual's remaining calls are `token.mint(deficitLedger, ·)`, `deficitLedger.onInterest(·)` and, after a successful booking, `token.mint(stabilityPool, ·)`. Each is protocol code with a closed set of revert causes, none of which depends on the pool:

| Call | Revert causes | Why no caller can reach them |
|---|---|---|
| `deficitLedger.onInterest(a)` | `onlyVault`; checked `reserve += a` | the caller is always the VaultManager. `reserve ≤ token.balanceOf(ledger) ≤ totalSupply ≤ 2^128 − 1`, so the add cannot overflow. It must stay call-free and lock-free (§5.10) |
| `token.mint(·, a)` | `NotWired`, `Unauthorized`, `SupplyCapExceeded` | accrual runs only when wired, and the VaultManager is the minter. `SupplyCapExceeded` needs total supply, i.e. total debt (I2), near `2^128 − 1 ≈ 3.4·10^38` wei. Borrowing cannot get there: debt is at most collateral value / MCR, and all ETH in existence at `MAX_PRICE` is worth ~1.2·10^38 wei. Only compounding interest can, after ~38 years at 100 %/yr from a 1B-token supply and centuries at 5 %: a fixed horizon like the index overflow (§2.2), which no caller can bring closer |

This is not left to the table: the tests in §4 must prove it.

### 4. Required tests: P19 acceptance criteria

The human's three conditions are named criteria of P19's own prompt (recorded in `docs/progress.md` Carry-forward until the prompt kit is committed).

**P19-AC-CHG006-1: the fallback path cannot revert.**
- The ledger's `onInterest` is call-free and lock-free. A fuzz test drives `reserve` from 0 up to the supply cap through `onInterest`, with the token minted to match, and never reverts.
- With a pool that reverts, panics (`G` overflow forced by a harness), burns all its gas, returns the wrong size or returns a word other than 0/1, `accrue()` succeeds, and so does every operation that accrues: `repay`, `addCollateral`, `close`, `borrow`, `withdrawCollateral`, `open`, liquidation and `ShutdownModule.check`.
- In each of those cases the whole offered amount reaches the reserve, `PoolInterestRedirected` is emitted, and I1 (pool) and I2 hold.
- A test pins `SupplyCapExceeded` as accrual's only remaining revert path, reachable only by compounding interest (a harness state near the cap).

**P19-AC-CHG006-2: under-supplying gas cannot fake a pool failure.**
- `POOL_HOOK_GAS` is set from a recorded worst-case measurement of the real pool, with the derivation written next to the value in §3.1.
- A sweep over caller gas limits, against the real pool and against a pool that needs a large share of the cap, records **zero** redirections. Every probe either books to the pool or reverts the whole transaction (`InsufficientGasForPoolHook` or out-of-gas). This is the griefing test.
- A pool that genuinely burns more than the cap is redirected when the caller supplies enough gas.
- The floor is tested one unit above and one unit below.

**P19-AC-CHG006-3: this ADR is accepted by the human before the spec text is applied.**

## Consequences

- Rescue paths, liquidation and the shutdown trigger no longer depend on the pool being correct, for any failure cause, known or unknown.
- A `G` overflow now costs depositors their interest share for the rest of that `(epoch, scale)`, not the protocol its liveness. §6.6.3's "Accepted" paragraph is reworded to say so.
- Accrual's only remaining revert path is `SupplyCapExceeded`, a fixed horizon of decades that no caller can bring closer.
- I1 and I2 keep their formulas: `toPool + toReserve = interest` in every branch, and nothing is minted to a pool that did not book.
- Depositors lose interest only to a genuine pool failure, never to a caller's gas choice.
- One VaultManager constructor argument, one error and one event are added.
- P15's F4 test flips from "a reverting pool blocks `repay`" to "a reverting pool's share is redirected and `repay` succeeds". That is the point of the change, not a loosened test. `HostileInterestSink` gains malformed-return and gas-burning modes.

## Alternatives considered

- **Option 2: prove the pool non-reverting at P19, with no change to accrual.** Make `S`/`G` overflow impossible instead of accepted, and require a proof that `onInterest` cannot revert in any reachable state.
  - Rejected by the human as the sole fix: it covers only the failure causes known today.
  - Liveness of every rescue path, and of the shutdown trigger, would rest on a proof about another contract, re-done after every edit to it.
  - P19 should still make overflow impossible where it cheaply can. That is good practice, not the guarantee.
- **Option 3: accept the risk as documented.** Rejected outright by the human. The probability is very low, but the consequence is total and irreversible: every rescue path and the shutdown trigger are lost. A low probability does not justify an unbounded, unrecoverable consequence.
- **Solidity `try/catch` instead of an assembly call.**
  - `try/catch` reverts the caller when the return data does not decode, so a pool returning the wrong shape would still brick accrual.
  - Copying unbounded revert data costs memory gas the caller pays.
  - ADR-0029 chose a fixed-shape assembly call for the oracle for the same reasons.
- **Two guarded calls (`acceptsInterest`, then `onInterest`).** Rejected: two failure paths and two gas rules for one decision. A starved `acceptsInterest` would redirect interest exactly as a starved `onInterest` would.
- **A pre-call gas check (`gasleft() ≥ POOL_HOOK_GAS · 64/63 + margin`) instead of a post-failure floor.** Rejected:
  - it needs a margin for the gas spent between the check and the call, which is compiler-dependent;
  - it charges every accrual the full forwarded amount up front;
  - the post-failure floor reuses the argument ADR-0030 proved and measured on Base's real proxy, and costs nothing on the success path.
- **Guarding the ledger hook and the mints as well.** Rejected:
  - if the reserve also fails there is nowhere to send the interest;
  - skipping the mint would break I2;
  - their revert causes are closed (§3), so a silent catch would only hide a real bug.
