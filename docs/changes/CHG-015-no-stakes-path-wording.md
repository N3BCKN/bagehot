# CHG-015: the no-stakes path needs no stake left, not no position left; and the view window during `onLiquidation`

- Status: **approved 2026-10-26** (the human delegated the decision). **Applied 2026-10-27:** spec/invariant text written.
- Affects: `docs/spec.md` §1.2, §6.4.4, §5.10 (text only). No code, model or vector change: the code
  already tests `totalStakes > 0`.

## Problem

§6.4.4 says the no-stakes path happens "if the liquidated position was the last active one", and §1.2
"deficit only if no other position exists". Under stake collapse (T-25, P17-1) it is also reached with
active positions whose stake is 0: `VaultManagerLiquidationTest.test_liquidate_stakeZeroSurvivor_deficitWhileActive`
(collapsed snapshots, then the real `liquidate`), and the core campaign counts it with real
liquidations (`liqDeficitWithActive`). The code is right; the text is not.

Separately (P20-I2): while the strategy runs, `totalCollateral`, `totalStakes` and `activeCount` are
already reduced but `totalNormDebt` is not, so `systemColl`/`tcr`/`belowCritical`/`sortKey` read a
transiently low TCR. Nothing untrusted runs in that window today; §5.10 should say so, so that a future
strategy does not add an untrusted call there.

## Exact wording

### §6.4.4, first sentence — replace

If no stake is left after the liquidated position's is removed (`totalStakes == 0`) — because it was
the last active position, or because every remaining position is staked 0 after stake collapse (T-25)
— a remainder cannot be redistributed.

### §1.2 — replace "deficit only if no other position exists"

deficit only if no other position holds a stake

### §5.10, the `VaultManager.liquidate → strategy.onLiquidation` row — append to Notes

While the strategy runs, the VaultManager has removed the position from `totalCollateral`,
`totalStakes` and `activeCount` but not yet from `totalNormDebt`, so its system views read a
transiently low TCR; a strategy must make no call that could reach code reading them (today: A sends
WETH and burns stablecoin, B calls only the ledger).

## Impact

Spec text only.
