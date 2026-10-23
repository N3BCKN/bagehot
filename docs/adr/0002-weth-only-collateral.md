# ADR-0002: Accept WETH as the only collateral

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 02. A comparison between two liquidation mechanisms is only clean if both
face the same collateral. Every extra asset multiplies the parameter space (one MCR, one penalty,
one liquidity curve per asset) and introduces correlation between assets, which is itself a
research question and not this one.

WETH on Base has the deepest DEX liquidity of any asset on the chain (measured at P25), a
Chainlink ETH/USD feed with the longest history (P07), and liquidation events to calibrate against
(P08). An LST would add a second price process, a staking yield and a de-peg risk of its own.

## Decision

`VaultManager` holds exactly one collateral token, WETH, fixed as an immutable at construction
(`docs/spec.md` §4.2). There is no asset registry, no per-asset parameters and no code path that
is parameterised by a collateral address. The gas reserve is WETH too (ADR-0016).

## Alternatives considered

- **A basket of LSTs.** Needs a per-asset oracle, per-asset MCR and a correlation model; the
  liquidation comparison would be confounded by which asset happened to be liquidated.
- **Multiple isolated markets.** Equivalent to running the experiment several times; the budget
  (P29 sweeps) does not allow it, and nothing in the research question requires it.

## Consequences

- Single-asset accounting: `totalCollateral` is one number, and the invariants of §10 are
  equalities over one token rather than sums over a registry.
- The results generalise only to ETH-collateralised CDPs. The report must say so.
- Native ETH is never handled (ADR-0016), so no `payable` function and no fallback exists.
