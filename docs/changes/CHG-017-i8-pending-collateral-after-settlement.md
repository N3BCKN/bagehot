# CHG-017: I8's pending-collateral inequality cannot hold after settlement

- Status: **approved by the human 2026-10-27** (option 1; proposed the same day, P22 spec audit of the
  Python model, finding 4). Model, Foundry and the invariants text applied 2026-10-27.
- Affects: `docs/invariants.md` I8 ("Formula", the first line). No spec algorithm, contract, model or
  vector change.

## Problem

I8 asserts, "at every step" and with scope "every phase" (`docs/invariants.md` I8):

```
Σ_active pendingColl(p) ≤ pendingColl ,  Σ_active pendingNorm(p) ≤ pendingNormDebt
```

At settlement `VaultManager.onSettlement` sends `totalCollateral + pendingColl` to the ShutdownModule
and sets `pendingColl = 0` (spec §5.1.11; `VaultManager.sol:583–585`). Positions keep their stored
fields: stake, `snapLColl`, `snapLDebt` (§5.1.11, "positions keep their stored fields"). A position
that had pending collateral before settlement still has `pendingColl(p) = ⌊stake·(LColl −
snapLColl)/DP⌋ > 0` afterwards, against a bucket of 0. The left inequality is then false on a correct
implementation. The collateral is not lost: it joined the claim pool, which is the point of
settlement.

The debt half is unaffected: `pendingNormDebt` is not touched at settlement, and the inequality keeps
holding.

## Evidence

- Code: `onSettlement` above. Model: `vault.py` `on_settlement` does the same.
- Both checkers already cut the collateral half at settlement without saying so in the text: Foundry
  `CoreHandler.checkI8` returns early when `v.settled()` (`CoreHandler.sol:1634`), skipping both
  halves; the Python `check_I8` (P22) skips only the collateral half and cites this CHG.
- Sequence: any redistribution leaving a position with pending collateral, then trigger and settle.
  `tests/model/test_invariants_model.py::test_I8_after_settlement_checks_the_debt_half_only` reaches
  it on the model (with `pendingColl == 0` after settlement, while positions still have pending
  rewards).

## Options

1. **Scope the collateral half to live and window** (recommended). The text says what both checkers
   must do; the debt half stays "every phase". Foundry's `checkI8` should then keep checking the debt
   half after settlement (a test change, not a weakening: today it checks neither half there).
2. **Keep `pendingColl` after settlement** (change `onSettlement` to leave the bucket and send the
   WETH anyway). The bucket would then describe WETH the VaultManager no longer holds, breaking I1's
   settled row. Rejected.
3. **Define pending collateral as zero after settlement** (a view change). Adds a phase branch to
   `effective` for no protocol purpose. Rejected.

## Exact wording (option 1) for `docs/invariants.md` I8

### Replaces the first line of the formula block

```
Σ_active pendingColl(p) ≤ pendingColl            (live and window — see below)
Σ_active pendingNorm(p) ≤ pendingNormDebt        (every phase)
```

### Added after the formula block

**The collateral half stops at settlement** (CHG-017): `onSettlement` moves `pendingColl` into the
claim pool and zeroes it, while positions keep their stakes and snapshots (§5.1.11), so a position
that had pending collateral still reports it against an empty bucket. The WETH is not missing — it is
in `claimColl`, which I1's settled rows and I10 account for. `pendingNormDebt` is not touched, so the
debt half holds in every phase.

## Impact

- `docs/invariants.md` I8 only.
- Python model: `model.invariants.check_I8` already implements option 1.
- Foundry: `CoreHandler.checkI8` checks the debt half after settlement (it returned early before);
  `CoreHandlerPhasesTest.test_I8_afterSettlement_checksTheDebtHalfOnly` fails without the change.
  Foundry's coverage gets stronger, not weaker.
- Spec, contracts, vectors, differential, experiments: none.
