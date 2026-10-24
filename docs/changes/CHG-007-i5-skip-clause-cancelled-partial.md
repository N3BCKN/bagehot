# CHG-007: I5's "skipped nodes" clause is false for a call that ends on a cancelled partial

- Status: **proposed** — awaiting the human
- Raised: 2026-10-24, P16 (while writing the I5 invariant handler)
- Affects: `docs/invariants.md` I5 ("Formula", second block); also I15 "Breaks if" (item 2 below,
  independent, same file). No spec, vector, contract or model change.

## Problem

I5 says, about the nodes the loop visited but did not redeem from:

```
for each id visited and not redeemed from:  effColl(id)·price < MCR·debtOf(id)   held at the visit
```

§6.7.3 counts a **cancelled partial** as a visit ("Every visited node counts as an iteration,
including skipped ones and a cancelled partial"). A partial is cancelled at exactly `MIN_DEBT`,
by the CHG-002 post-check, or on a stale hint. All three cancel a position that is **at or above**
MCR. When the same call redeemed something earlier, it succeeds, and the clause is violated on its
last visit. The contract, the model and the vectors agree with §6.7.3. Only I5's wording is wrong.

## Evidence

Deterministic, model and contract alike. Start parameters, price 2,000, index RAY:

1. Position 1 (erin): 100 WETH, 20,000 debt. Position 2 (frank): 2.22 WETH, 2,000 debt (= MIN_DEBT,
   ICR 2.22). Position 3 (dave, the tail): 2.21 WETH, 2,000 debt (= MIN_DEBT, ICR 2.21).
2. erin redeems 2,500 with `maxIterations = 10`. Visit 3: full redemption (2,000). Visit 2:
   `remaining = 500 < debt`, `d = min(500, 2,000 − 2,000) = 0`, so the partial is cancelled and the
   loop ends.
3. The result is `redeemed = 2,000` and `iterations = 2`, and the call succeeds. Position 2 was
   visited, was not redeemed from, and has ICR 2.22 ≥ MCR, so the clause fails.

The same happens with a CHG-002 cancellation or a stale hint after one or more full redemptions.
`redemption.json` has no such case: each of its cancelled partials reverts `NothingRedeemed`,
because nothing was redeemed before it.

## Options

1. **Reword the clause to except the cancelled partial** (recommended):

   ```
   for each id visited and not redeemed from, except the last visit of the call:
       effColl(id)·price < MCR·debtOf(id)   held at the visit
   the last visit is either redeemed from, below MCR, or a cancelled partial — a position with
   remaining < debtOf(id) that is at exactly MIN_DEBT, fails the CHG-002 post-check, or has no slot
   within MAX_HINT_STEPS — and in the last case nothing about it changed
   ```

   This states exactly what §6.7.3 does. The handler can check the last visit's reason
   independently, from the pre-call state and the hint helper's simulation.
2. **Stop counting a cancelled partial as an iteration** (spec change to §6.7.3). Rejected: it
   changes behaviour and the reported `iterations` only to fit the invariant's wording, and the
   visit really happened (its reads cost gas).

## Impact

- `docs/invariants.md` I5 only (needs the file unlocked). The I5 handler (P16) asserts the reworded
  clause. Its "Breaks if" and targeted-sequences paragraphs gain this sequence as a regression test.
- No spec, vector, Solidity or model change; no experiments have run.

## Item 2 (independent, found by the P16 security review, F4): I15's "Breaks if" names a failure that cannot happen

I15 lists "The gate placed before `accrue()`, so `D` misses the current block's interest" as a way
to break it. It cannot: `belowCritical` reads `systemDebt()`, which uses `currentIndex()` (§5.8),
and accrual changes neither `totalNormDebt`, `systemColl`, nor the ledger's `auctionDebt`/`deficit`.
A mutant moving `accrue()` after the gate survives every test because it is equivalent. The real
hazard is the one §5.8 already forbids: a `belowCritical` that reads the **stored** `index`.

**Proposed:** replace that "Breaks if" sentence with "A `belowCritical` that reads the stored
`index` instead of `currentIndex()` (§5.8), so `D` misses interest since the last accrual", and add
the targeted sequence "`dt > 0` since the last accrual, gate evaluated as a view without accruing".
