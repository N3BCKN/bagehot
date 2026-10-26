# CHG-016: DeficitLedger text — lock-free hooks, `AlreadySettled` locations, settlement step order

- Status: **proposed**, 2026-10-26 (P21 stage-3 spec audit, findings L3, L4, L5). Needs the human's
  approval and the protected-paths unlock of `docs/spec.md`.
- Affects: `docs/spec.md` §5.10, §11.2, §6.11.3 (text only). No code, model, vector or invariant change.

## Problem

The P21 DeficitLedger (`contracts/src/safety/DeficitLedger.sol`) and its model
(`model/protocol/deficit_ledger.py`) match §4.7, §5.6, §6.9 and §11.1. Three places in the spec text
do not describe them exactly:

1. **§5.10 (L3).** The rule is "every contract holding or moving tokens uses one transient lock over
   its state-changing external functions, except the callbacks marked lock-free below". The table marks
   only `DeficitLedger.onInterest` lock-free. The ledger's other single-caller hooks — `onPoolDust`,
   `recordDeficit`, `addAuctionDebt`, `onAuctionPayment`, `onAuctionShortfall` — carry no lock in the
   code either (`DeficitLedger.sol:130–164`). They make no external call, so nothing can re-enter
   through them, and their callers hold their own locks. `payTip`, `cover` and `onSettlement` move
   tokens and are locked.
2. **§11.2 (L4).** The `NotTriggered() / AlreadySettled() / WindowNotOver()` row lists `settle` and
   `VaultManager.onSettlement` as locations. It omits `DeficitLedger.onSettlement` and
   `DutchAuctionHouse.onSettlement`, which §5.6 and §6.11.3 define with `AlreadySettled`.
3. **§6.11.3 (L5).** The `DeficitLedger.onSettlement` pseudocode burns the reserve before it zeroes
   `reserve` and writes the rest of the state. The contract and model write all state first and then
   make the two token calls (checks–effects–interactions). The change came from static-analysis
   findings (slither reentrancy-no-eth / reentrancy-benign, aderyn reentrancy-state-change) at P21.
   Every observable is identical: the final state, the return value, the event values ("after the
   updates"), and the log order (burn `Transfer`, WETH `Transfer`, `LedgerSettled`). StableToken
   makes no callback, so no intermediate state can be observed, and a failure reverts everything in
   either order.

## Options

- **A — fix the text (recommended).** Mark the five hooks lock-free in §5.10, add the two locations
  in §11.2, and reorder §6.11.3's pseudocode to match the code. No code change; the code is
  already tested (`DeficitLedgerTest`, `test_deficit_ledger_model.py`).
- **B — change the code to the current text.** Add `nonReentrant` to the five hooks, and move the burn
  back before the state writes. That costs gas on every accrual-adjacent liquidation path. It brings
  back the reentrancy findings the reorder removed (they would be triaged, not fixed), and it adds no
  protection, because the hooks make no external call.

## Exact wording (option A)

### §5.10 — add a row after `VaultManager.liquidate → DeficitLedger.recordDeficit`

| `StabilityPool.withdraw/claimGains → DeficitLedger.onPoolDust`; `VaultManager.liquidate → DeficitLedger.recordDeficit`; `DutchAuctionHouse.* → DeficitLedger.addAuctionDebt / onAuctionPayment / onAuctionShortfall` | lock-free like `onInterest`: each is restricted to its one wired caller (§5.6), checks `!settled`, and makes no external call. `payTip`, `cover` and `onSettlement` move tokens and take the ledger's lock |

### §11.2 — the `NotTriggered() / AlreadySettled() / WindowNotOver()` row, "Where" column — replace

`settle`; `NotTriggered`/`AlreadySettled` also `VaultManager.onSettlement`; `AlreadySettled` also
`DeficitLedger.onSettlement` and `DutchAuctionHouse.onSettlement`

### §6.11.3 — `DeficitLedger.onSettlement` pseudocode — replace the body

```
function DeficitLedger.onSettlement():
    require(!settled, AlreadySettled)
    burned = reserve
    reserve = 0
    deficit += auctionDebt; auctionDebt = 0
    coll = recoveredColl; recoveredColl = 0
    settled = true
    if burned > 0: token.burnFrom(this, burned)         // all state written first (CEI)
    if coll > 0: WETH.safeTransfer(shutdownModule, coll)
    emit LedgerSettled(burned, deficit, coll)           // values after the updates
    return coll
```

## Impact

Spec text only. Solidity, model, vectors, invariants, differential rules: none. No experiment has run.
Preregistration: none.
