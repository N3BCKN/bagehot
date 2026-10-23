# ADR-0001: Peg the stablecoin to the US dollar

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 01. The research question is about liquidation mechanisms: deployment A
(stability pool) against deployment B (Dutch auction) under identical conditions. Everything that
is not the mechanism should contribute as little variance as possible.

The unit of account enters the system in exactly three places: the oracle (`docs/spec.md` §6.10
reads one ETH/USD feed), the collateral ratio (§2.4), and the redemption floor (§6.7, one token
redeems one dollar of collateral less the fee). A peg whose own target moves would put a second
stochastic process into every one of them.

## Decision

The stablecoin targets 1 USD. The protocol has no peg-defence machinery of its own: the floor is
redemption at par (§6.7) and the ceiling is the ability to borrow at MCR (§5.1.1). No price feed
for the stablecoin exists anywhere in the system, and no contract reads a market price of it.

## Alternatives considered

- **Gold or a basket.** Adds a second oracle and a second volatility process to every ICR, and no
  liquid Base price feed with the history P06–P07 needs.
- **An index (CPI-linked) or a governed target price.** A moving target makes the redemption floor
  time-dependent and the NICR ordering (§6.3) price-dependent; it also needs a governance path,
  which ADR-0009 forbids.

## Consequences

- Peg dynamics are explicitly out of scope (`docs/spec.md` §1.3): the report never claims the
  token traded at 1 USD, only that the protocol's internal floor and ceiling held.
- Every result is quoted in dollars of debt, which makes A and B directly comparable.
- Depeg behaviour in the secondary market cannot be measured by this design. Reversing the choice
  means a new oracle, new invariants around the target price, and a re-run of every sweep.
