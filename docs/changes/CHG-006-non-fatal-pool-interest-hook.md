# CHG-006: A failing stability pool must not stop accrual; its interest share falls back to the reserve

- Status: **approved 2026-10-24 (option 1); applied at P19 on 2026-10-26** with `docs/spec.md` and
  `spec/vectors/**` unlocked by the human: spec §3.1 (`POOL_HOOK_GAS = 200_000`, from a measured worst
  case of 86,981 gas), §3.4 (VaultManager index 8), §5.3.4, §5.9, §5.10, §6.2, §6.6.3, §6.6.5, §11.1,
  §11.2; `interest.json` gains `poolHook` and the vector `accrue_pool_hook_fails`. ADR-0033 accepted.
  §3.3 needed no text: the range is a constructor check (constraint 6). The table below says "§5.7" for
  the pool function table; it is §5.3.4. The `product_sum.json` note says "mint then onInterest"; under
  ADR-0033 the pool books first and is minted after, with the same end state. Two sub-cases of
  AC-CHG006-1 (liquidation, `ShutdownModule.check`) are deferred to P20 and the ShutdownModule prompt
  (human decision 2026-10-26). The "failing-pool mode" the Impact section promises for the P19 handler
  is covered by `VaultManagerPoolHookTest`'s matrix (eight failure modes × every accruing operation)
  instead: the only way to make the *real* pool fail inside a campaign is to corrupt its storage, which
  breaks the pool's own invariants (I3) by construction and would measure nothing. `POOL_HOOK_GAS`'s
  measurement was refreshed to 86,981 after the pool's final interface (spec §3.1).
- Raised: 2026-10-24, P15 (security-reviewer finding F4; open issue P15-1; threat T-24)
- Affects: `docs/spec.md` §6.2 (accrual), §6.6.3 (the "Accepted" overflow paragraph), §6.6.5 and the
  pool function table (§5.7: `acceptsInterest` / `onInterest`), §3.1 / §3.3 / §3.4 (one new
  VaultManager parameter), §5.10 (call graph), §11.1 (one new event); the VaultManager constructor and
  `_accrue`; `model/protocol/vault.py`; `interest.json` (a `poolHook` field per case); I1 and I2 are
  unchanged in formula (see Impact)

## Problem

Since P15 every normal-mode operation starts with `_accrue()`: the rescue paths `repay`,
`addCollateral` and `close`, liquidation (P20) and `ShutdownModule.check` (§6.11.1), which accrues
before it calls `onShutdown`. `_accrue()` calls `stabilityPool.acceptsInterest()`,
`stabilityPool.onInterest(toPool)`, `deficitLedger.onInterest(toReserve)` and `token.mint`. A revert
in any of them reverts every one of those operations, and because `check()` reverts too, the
shutdown window — where `_accrue` returns before any hook and the rescue paths stop depending on the
pool — can never be reached. The result is total and irreversible: no repay, no close, no
liquidation, no shutdown.

## Evidence

- §6.6.3 already *accepts* that `S` or `G` (checked arithmetic) overflow after ≥ 338 adversarial
  events in one `(epoch, scale)`, each an accrual near the supply cap or a full-supply
  deposit-and-withdraw cycle (≥ 10^8 events at realistic sizes). `G` overflows inside `onInterest`.
  §6.6.3 judged the consequence as a pool failure; since P15 it is a protocol failure.
- `VaultManagerInterestHooksTest.test_F4_revertingPool_blocksNormalMode_notTheWindow` (committed at
  P15) pins today's behaviour: a reverting pool makes `repay` revert in normal mode; after shutdown the
  rescue paths work without the pool.
- Any future bug in the pool's interest path, known or not, has the same consequence.

## Options

1. **Make the pool hook non-fatal** (approved). Accrual calls the pool under a gas-capped,
   failure-tolerant call; if the pool fails or declines, its share goes to the reserve. The pool is
   minted only after it has booked the amount, so the pool's I1 holds either way. Rescue paths,
   liquidation and `check()` then never depend on the pool.
2. **Prove the pool non-reverting at P19.** Make `S`/`G` overflow impossible rather than accepted and
   require P19 to prove `onInterest` cannot revert in any reachable state. No change to accrual.
   *Rejected as the sole fix* (human, 2026-10-24): it covers only the failure causes known today.
3. **Accept as documented.** *Rejected outright* (human, 2026-10-24): a low probability does not
   justify an unbounded, unrecoverable consequence.

## Recommendation and design (option 1)

### Spec §6.2 — proposed wording

```
function accrue():
    if shutdown: return                                   // index frozen at the trigger
    dt = block.timestamp − lastAccrual
    if dt == 0: return
    newIndex = mulDivUp(index, rpow(RAY + RATE_PER_SECOND, dt), RAY)
    interest = mulDivUp(totalNormDebt, newIndex − index, RAY)
    index = newIndex; lastAccrual = block.timestamp
    toPool = 0
    if stabilityPool != address(0):
        offered = mulDivDown(interest, POOL_SHARE_BPS, BPS)
        if offered > 0:
            (ok, booked) = guardedCall(stabilityPool.onInterest(offered), POOL_HOOK_GAS)
            if ok and booked: toPool = offered
            else if not ok: require(gasleft() ≥ ceil(2·POOL_HOOK_GAS / 63), InsufficientGasForPoolHook)
                            emit PoolInterestRedirected(offered)
    toReserve = interest − toPool
    if toPool > 0:    token.mint(stabilityPool, toPool)   // after the pool booked it
    if toReserve > 0: token.mint(deficitLedger, toReserve); deficitLedger.onInterest(toReserve)
    emit InterestAccrued(newIndex, interest, toPool, toReserve, block.timestamp)
```

- **One pool call instead of two.** `acceptsInterest()` and `onInterest()` merge into
  `onInterest(amount) returns (bool booked)`: the pool returns `false` without changing state when
  `totalDeposits < MIN_DEPOSIT` (today's `acceptsInterest() == false`), books and returns `true`
  otherwise. One guarded call means one gas rule and one failure path instead of two. `acceptsInterest`
  stays as a view for off-chain readers; accrual no longer calls it.
- **`guardedCall`** is a fixed-shape assembly `call` (the ADR-0029 pattern): gas `POOL_HOOK_GAS`,
  return data copied only if it is exactly 32 bytes, decoded as a bool only if it is 0 or 1.
  `ok = false` when the call reverts, runs out of gas, returns any other size, or returns a word other
  than 0 or 1. Solidity `try/catch` is not used: it reverts the caller on malformed return data, so a
  pool returning the wrong shape would still brick accrual.
- **Pool booked, then minted.** If the pool fails, nothing has been minted to it and its `G` is
  unchanged (the revert rolled it back), so its I1 (interest gains ≤ token balance) holds. Between
  booking and minting no external call runs (`onInterest` stays call-free, §5.10).
- **`PoolInterestRedirected(offered)`** is emitted only when the call failed (`ok = false`). A
  declined offer (`booked = false`, deposits below the minimum) is normal operation and emits nothing,
  as today.

### Gas rule (the CHG-004 pattern, applied to the pool hook)

The attack: a caller supplies just enough gas that `onInterest` runs out inside, the failure path
redirects the pool's share to the reserve, and the rest of the transaction still completes. The
attacker gains nothing directly but can strip depositors of their interest at will. The defence is the
§6.10.3 argument, unchanged:

- the call forwards `F = min(POOL_HOOK_GAS, ⌊63/64 · available⌋)`; a starved call leaves the
  VaultManager its own reserve `< F/63`, plus at most `F/63` handed back by any chain of nested calls
  (the pool makes none, but the bound does not rely on that);
- so after a starved call `gasleft() < 2·POOL_HOOK_GAS/63`, and the check
  `gasleft() ≥ ceil(2·POOL_HOOK_GAS / 63)` turns every starved call into a revert of the whole
  transaction instead of a redirection;
- a genuine failure either reverts early (handing back almost all of `F`) or burns the whole cap while
  the caller supplied more than `POOL_HOOK_GAS · 64/63 + ceil(2·POOL_HOOK_GAS/63)`; both pass the
  check and are redirected.

`POOL_HOOK_GAS` is a new immutable VaultManager constructor argument, not a default. Its value is
**derived at P19 from a measurement**: at least twice the pool's worst-case `onInterest` cost
(cold storage, new `(epoch, scale)` slot, non-zero carry), measured on the real pool and recorded in
§3.1 next to the value. Range `[50_000, 1_000_000]` (as `ORACLE_GAS`); the floor is derived, not a
second parameter, because nothing about the pool hook calls for tuning it separately. In deployment
B (`stabilityPool == address(0)`) the parameter is checked but unused.

### The fallback path must not be a new single point of failure

With option 1 the remaining calls in accrual are `token.mint(deficitLedger, ·)`,
`deficitLedger.onInterest(·)` and `token.mint(stabilityPool, ·)` after a successful booking. Each is
protocol code with a closed set of revert causes:

| Call | Revert causes | Why unreachable |
|---|---|---|
| `deficitLedger.onInterest(a)` | `onlyVault`; checked `reserve += a` | caller is always the VaultManager; `reserve ≤ token.balanceOf(ledger) ≤ totalSupply ≤ 2^128 − 1`, so the add cannot overflow. It must stay call-free and lock-free (§5.10) |
| `token.mint(·, a)` | `NotWired`, `Unauthorized`, `SupplyCapExceeded` | accrual runs only `whenWired` and the VaultManager is the minter. `SupplyCapExceeded` needs total supply, i.e. total debt (I2), near `2^128 − 1 ≈ 3.4·10^38` wei. Borrowing cannot get there: debt is at most collateral value / MCR, and even all ETH in existence (~1.2·10^26 wei) at `MAX_PRICE` (≤ 10^30, i.e. 10^12 USD per ETH) is worth ~1.2·10^38 wei, below the cap. Only compounding interest can, after ~38 years at 100 %/yr from a 1B-token supply and centuries at 5 %. That is the same kind of fixed horizon as the index overflow (§2.2, ~166 years at the maximum rate), which already ends every operation, and no caller can move it closer |

So the fallback cannot be made to revert by any caller, and none of its revert causes depend on the
pool. P19 must prove this with tests (criterion 1 below), not with this table.

## P19 acceptance criteria (named; to be copied into `prompts/P19-*.md` once the kit is committed)

- **P19-AC-CHG006-1 — The fallback path cannot revert.**
  - The ledger's `onInterest` is call-free and lock-free. A fuzz test drives `reserve` from 0 up to
    the supply cap through `onInterest`, with the token minted to match, and never reverts.
  - With a pool that reverts, panics (`G` overflow forced by a harness), burns all its gas, returns
    the wrong size or returns a word other than 0/1, both `accrue()` and every operation that accrues
    succeed: `repay`, `addCollateral`, `close`, `borrow`, `withdrawCollateral`, `open`, liquidation and
    `ShutdownModule.check`.
  - The whole offered amount reaches the reserve, `PoolInterestRedirected` is emitted, and I2 holds.
  - A test pins `SupplyCapExceeded` as the only remaining revert path of accrual, reachable only by
    compounding interest (a harness state near the cap).
- **P19-AC-CHG006-2 — Under-supplying gas cannot fake a pool failure.**
  - `POOL_HOOK_GAS` is set from a recorded measurement of the real pool's worst-case `onInterest`,
    with the derivation written next to the value in §3.1.
  - A sweep over caller gas limits, with the real pool and with a pool that needs a large share of the
    cap, records **zero** redirections: every probe either books to the pool or reverts the whole
    transaction (`InsufficientGasForPoolHook` or plain out-of-gas).
  - A pool that genuinely burns more than the cap is redirected when the caller supplies enough gas.
  - The boundary is tested one unit above and one unit below the floor.
- **P19-AC-CHG006-3 — ADR.** ADR-0033 is accepted by the human before the spec text is applied.

## Impact

- **Spec:** §6.2 (above); §6.6.3's "Accepted" paragraph is reworded: an overflow now makes the pool's
  `onInterest` fail and its share go to the reserve for the rest of that `(epoch, scale)`, but no
  longer blocks anything else. Also §6.6.5 (`returns (bool booked)`, no precondition revert), the pool
  table in §5.7, §3.1 / §3.3 / §3.4 (`POOL_HOOK_GAS`, a new VaultManager constructor index), §5.10 (the
  accrual row notes the guarded call) and §11.1 (`PoolInterestRedirected`). §5.9's supply-cap sentence
  stays, sharpened to "reachable only by compounding interest".
- **Invariants:** I1 and I2 keep their formulas. I2's `E` is unaffected because
  `toPool + toReserve = interest` in every branch. I1 for the pool holds because nothing is minted to
  a pool that has not booked. No new invariant; the P19 handler adds a failing-pool mode.
- **Vectors:** `interest.json` gains an optional `poolHook` per case (`book` default, `decline`,
  `fail`); the expected split already follows from it.
- **Solidity:** VaultManager constructor and `_accrue`; `IStabilityPoolInterest` merges the two
  functions. P15's `HostileInterestSink` and F4 tests are updated: F4's test flips from "blocks" to
  "redirects", which is the point of the change, not a loosening.
- **Python model:** `vault.py` `_accrue` takes the pool outcome (`book` / `decline` / `fail`).
- **Threat model:** T-24's mitigation becomes this change; its residual is the supply-cap horizon.
- **Experiments / preregistration:** none have run.
