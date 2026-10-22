# ADR-0007: Require a minimum debt and a gas reserve per position

- Status: proposed
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 07. A liquidation is only performed if it pays. Below some position size the
penalty on the debt is worth less than the gas the liquidator spends, so small positions become
permanently unliquidatable and sit in the system as bad debt. On Base the cost is L2 execution plus
the L1 data fee (P09/P24), which moves with L1 gas, so the threshold is not a constant anyone can
hard-code with confidence.

Two instruments address it: a floor on debt, so the penalty is always worth something, and a
reserve posted by the borrower that pays whoever does the work.

## Decision

Every position carries `MIN_DEBT` as a floor on its debt at opening and after any operation that
leaves it active (`docs/spec.md` §5.1, `DebtBelowMinimum`, `RepayExceedsMaximum`), and posts
`GAS_RESERVE` in WETH at opening. The reserve goes to whoever liquidates the position in A, or
whoever starts its auction in B (§6.4, §6.8.2); it is returned on `close`, on a full redemption,
and through `reclaimGasReserve` after settlement (§5.1.10). Both are immutable parameters whose
values are derived from measured costs at P09/P24 and swept in the scenarios.

## Alternatives considered

- **A premium that grows as positions get smaller.** Price-dependent, needs a curve nobody can
  calibrate before P08, and still leaves a dust tail.
- **Protocol-funded liquidation rebates.** Needs a treasury and a policy for refilling it, i.e. an
  admin role (ADR-0009).

## Consequences

- Liquidation profitability has a floor that does not depend on the penalty alone; this is what
  makes the latency calibration (ADR-0025) meaningful.
- Small borrowers are excluded. The report states `MIN_DEBT` whenever it quotes a position-size
  distribution.
- `MIN_DEBT` appears in three more places as a dust rule: partial redemption (§6.7.3), partial
  auction purchase (§6.8.4, `NoPartialPurchase`) and the pool's `MIN_DEPOSIT` analogue (§5.3).
