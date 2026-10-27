# ADR-0036: `liquidate` validates the strategy's answer, including the collateral it returns

- Status: accepted 2026-10-27 (human); proposed the same day (records CHG-012, approved by the human 2026-10-26 as P20 decision d,
  and CHG-014, approved 2026-10-26 under the human's delegation)
- Date: 2026-10-27
- Prompt: P20 (CHG-012, security review P20-L1 → CHG-014); spec text applied at P21's close
- Supersedes: —

## Context

`VaultManager.liquidate` hands the position's collateral to the deployment's strategy (the stability
pool in A, the auction house in B, ADR-0003) and trusts its answer `(debtAbsorbed, collReturned)` to
split the position into an absorbed part and a remainder for redistribution or the deficit (§6.4.1).
A faulty strategy could:
- report more debt absorbed than the position had;
- report more collateral returned than it received;
- report collateral returned that it never sent.

The first two would corrupt `totalNormDebt` or `pendingColl`. The third would book WETH in
`pendingColl` with nothing behind it. I1's VaultManager row would then break silently, and the last
payout of that WETH (`_applyPending`, `close` or `onSettlement`) would revert, bricking settlement.

## Decision

After `onLiquidation` returns, the VaultManager requires:
- `debtAbsorbed ≤ debt` (`DebtAbsorbedExceedsDebt`, CHG-012);
- `collReturned ≤ coll` (`CollReturnedExceedsColl`, CHG-012);
- `WETH.balanceOf(this) == wethBefore + collReturned` (`CollReturnedNotReceived`, CHG-014), with
  `wethBefore` read immediately before the call.

The equality is exact, so a strategy that sends more is caught too. No conforming strategy can trigger
any of the three. They are defence in depth against a future strategy or a bug in one.

## Consequences

- Two balance reads (about 2,200 gas warm) and about 100 bytes of VaultManager code (P20-SIZE).
- The Python model mirrors all three checks and raises the same errors.
- A failure surfaces at liquidation time, next to its cause, not at payout time.
- Spec §6.4.1 and §11.2; full reasoning in `docs/changes/CHG-012-*.md` and `docs/changes/CHG-014-*.md`.
