# CHG-014: `liquidate` checks that the collateral the strategy reports returning actually arrived

- Status: **proposed**, 2026-10-26 (P20 security review, finding P20-L1).
- Affects: `docs/spec.md` §6.4.1 (one balance check), §11.2 (one error); the VaultManager; the Python
  model; one unit test. No vector changes (no conforming strategy triggers it).

## Problem

CHG-012 added `debtAbsorbed ≤ debt` and `collReturned ≤ coll`. Neither checks that `collReturned` WETH
reached the VaultManager. §6.4.1 says "the strategy … transfers `collReturned` back to the VaultManager
before returning", but nothing enforces it. A faulty strategy — a future one, or a bug in the auction
house — that reports `(debt − 1, 1e18)` and transfers nothing passes both checks; `_redistribute` then
adds 1e18 to `pendingColl` with no WETH behind it. I1's VaultManager row breaks silently, and the last
of `_applyPending`/`close`/`onSettlement` to pay that WETH out reverts on the transfer — which bricks
settlement (a rescue path).

## Options

1. **Check the receipt** (recommended): read `WETH.balanceOf(this)` before the strategy call and
   require `balanceAfter == balanceBefore + collReturned` (`CollReturnedNotReceived`). Two balance
   reads; exact equality, so a strategy that sends more is caught too. Same defence-in-depth reasoning
   as CHG-012 and the human's decision d.
2. **Keep CHG-012 as range checks** and rely on the strategy contract and I1 in the campaigns. The
   failure would surface only at payout time, far from its cause.

## Exact wording (option 1)

### §6.4.1 — the strategy call and the checks after it

```
    wethBefore = WETH.balanceOf(this)
    (debtAbsorbed, collReturned) = strategy.onLiquidation(id, owner, debt, coll, price)
    require(debtAbsorbed ≤ debt, DebtAbsorbedExceedsDebt)                 // defence in depth (CHG-012)
    require(collReturned ≤ coll, CollReturnedExceedsColl)
    require(WETH.balanceOf(this) == wethBefore + collReturned, CollReturnedNotReceived)   // CHG-014
```

### §11.2 — new row

| `CollReturnedNotReceived()` | the VaultManager's WETH did not grow by exactly `collReturned` across `onLiquidation` (CHG-014) | `liquidate` |

## Impact

VaultManager (two balance reads, about 2,200 gas when warm), Python model, one unit test per direction
(nothing sent; more sent) plus the exact case accepted. VaultManager size: about +100 bytes (P20-SIZE).
