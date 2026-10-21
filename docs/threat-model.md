# Threat model

> **Stub — filled at P04, revisited at P38.** Blueprint §17.

Bagehot is testnet-only and will never hold real funds. The threat model exists because the
research question is about behaviour under adversarial conditions: a mechanism that is only safe
against honest actors has not been compared fairly against one that is safe against all of them.

## 1. Trust assumptions

<!-- What is assumed honest, what is assumed available, what is assumed bounded. Oracle, sequencer,
     liquidators, the deployer's one-shot wire(...), the absence of any admin role. -->

## 2. Assets and actors

| Actor | Capability | Motivation |
|---|---|---|

## 3. Threat register

| id | Threat | Vector | Impact | Likelihood | Mitigation | Residual risk | Test |
|---|---|---|---|---|---|---|---|
| T-01 | Redemption run below par | Once `systemColl · price < systemDebt`, each redemption lowers the TCR, so holders race to redeem first and late holders are left with the remainder | Value transfer between holders; accelerated collapse | — (P04) | `redeem` reverts `TCRBelowCritical()` below `CRITICAL_TCR`, at the same threshold and on the same quantities as the shutdown trigger (spec §6.7.2, D-27) | A system between `CRITICAL_TCR` and par can still be redeemed from; the shutdown still needs somebody to call `check()` | P03 invariant "no successful redemption while TCR < CRITICAL_TCR"; vector `redemption.json#tcr_guard` |

## 4. Out of scope

<!-- Explicitly: what this design does not defend against, and why that is acceptable for a
     testnet research deployment. Say it plainly rather than leaving it implied. -->

Carried from the P02 gate (spec §1.4), to be written up properly at P04:

- **Settlement forfeiture.** Settlement is pure pro-rata (ADR-10). A borrower who does not repay
  inside `REPAYMENT_WINDOW` forfeits the surplus collateral of their position to the claim pool —
  an over-collateralised borrower subsidises the rest of the holders. This is accepted: settling at
  the trigger price would need a usable price at settlement and a per-position loop, and the A/B
  comparison does not depend on the rule.
- **Depositor flight.** Nothing stops stability-pool depositors from withdrawing as losses
  approach; the deployment measures the effect instead of preventing it.
- **Full liquidation only.** No close factor in the MVP, so a borrower just below MCR pays the
  penalty on the whole debt.

## 5. Boundaries of the testnet deployment

<!-- Blueprint §15.6: what the Base Sepolia deployment is and is not evidence for -->
