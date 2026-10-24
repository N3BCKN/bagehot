# CHG-007: I5's "skipped nodes" clause is false for a call that ends on a cancelled partial

- Status: **approved in principle 2026-10-24 (item 1 option 1, item 2)**; the human asked for the exact
  wording and a negative test before unlocking `docs/invariants.md` — both below
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

## Exact wording to apply (after the unlock)

### I5, "Formula": replaces the paragraph "Separately, about the nodes the loop **skipped** …" and
### its code block (the line "and: at most one position per call …" stays)

Separately, about the nodes the loop visited **without** redeeming from them. Let `v₁ … v_k` be the
nodes the call visited, in visit order (`k` = `iterations`), and `remaining_j` the amount not yet
redeemed when `v_j` was visited:

```
for each j < k with no PositionRedeemed(v_j, …):
    effColl(v_j)·price < MCR·debtOf(v_j)                                    held at the visit (skipped)

if there is no PositionRedeemed(v_k, …), exactly one of (a), (b) holds at the visit:
  (a) effColl(v_k)·price < MCR·debtOf(v_k)                                                    skipped
  (b) effColl(v_k)·price ≥ MCR·debtOf(v_k), remaining_k < debtOf(v_k), nothing about v_k changed,
      and v_k is a cancelled partial for exactly one reason — the first of 1–3 that is true,
      tested in §6.7.3's order:
        1. d == 0                                                                    MIN_DEBT cap
        2. (effColl(v_k) − out)·price < MCR·⌈(effNorm(v_k) − dn)·index/RAY⌉     CHG-002 post-check
        3. find(effColl(v_k) − out, effNorm(v_k) − dn, v_k, v_k, upperHint, lowerHint)
           reports no slot                                                              stale hint
      where d = min(remaining_k, debtOf(v_k) − MIN_DEBT), dn = ⌊d·RAY/index⌋,
      out = ⌊d·(WAD − feeRate)/price⌋, and upperHint, lowerHint are the call's hints.

a last visit that is neither (a) nor (b) — above MCR with remaining_k ≥ debtOf(v_k), or above MCR
with none of 1–3 true — is an illegitimate early stop and violates I5.
```

The last visit is the only place a visited node may be left both unredeemed and at or above MCR,
and only for one of those three reasons. This is not a relaxation of the old clause for any other
node: every visit before the last must still have been below MCR.

### I5, "Checked in": append

`RedemptionLastVisitTest` — each of the three reasons recognised on a real redemption, and
`test_lastVisit_illegitimateStopIsRejected`: the contract stops on the last node with no legitimate
reason, and the check reports it.

### I5, "Breaks if": append

A redemption that ends on its last node without one of the three reasons — e.g. one that cancels the
partial whenever an earlier position was redeemed in full, or treats a small `d` as zero.
**Targeted sequences** gain: a full redemption followed by a cancelled partial on a position at
exactly `MIN_DEBT`, and the same with a stale hint.

### I15, "Breaks if": the second sentence

Replace "The gate placed before `accrue()`, so `D` misses the current block's interest." with:

"`belowCritical` reading the stored `index` instead of `currentIndex()` (§5.8), so `D` misses the
interest since the last accrual. (Placing the gate before `accrue()` is harmless: the view already
reads `currentIndex()`.)"

and add to its targeted sequences: "`dt > 0` since the last accrual, the gate evaluated as a view
without accruing first".

## Evidence that the reworded I5 still rejects an illegitimate stop

- `contracts/test/utils/RedemptionLastVisit.sol` evaluates (b) independently of the contract (OZ
  `Math` with the rounding written out, in §6.7.3's order) and returns the reason, or `None`.
- `RedemptionInvariantTest` asserts `lastVisitWithoutReason == 0`, alongside the clause for earlier
  visits. The campaign reaches the MIN_DEBT and stale-hint cancellations; the CHG-002 cancellation
  needs zero slack at the redemption's index and price, which random states do not produce, so it
  is covered by the targeted tests and the vector.
- **Negative test (unit):** `RedemptionLastVisitTest.test_lastVisit_illegitimateStopIsRejected`
  makes `find` lie to the VaultManager during the call only, so the contract stops on the last node
  although a slot exists; the independent check on the real list returns `None`.
- **Negative test (campaign, by mutation of the contract):** two wrong early stops, each run against
  the invariant and then reverted:
  - A — cancel the partial whenever an earlier position was fully redeemed (the review's F2
    example): `[FAIL: I5: the last visit stopped without a legitimate reason]`;
  - B — treat any partial below 1,000 as cancelled: same failure.
  The committed handler (without the reason check) passes all three invariants with mutant A in
  place, which is the gap the review identified.
