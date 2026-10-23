# ADR-0008: Read one Chainlink ETH/USD feed plus the L2 sequencer-uptime feed

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 08. The protocol needs a price for three decisions: whether a position is
liquidatable, what a redemption pays, and where an auction starts. On Base the canonical source is
the Chainlink ETH/USD aggregator, and the chain itself can stop: after a sequencer outage the first
blocks carry stale user state, so a price that was fresh by timestamp can still be acted on by
nobody but the first transaction through the door.

Chainlink publishes an L2 sequencer-uptime feed precisely for this, and the standard mitigation is
a grace period after a restart.

## Decision

`OracleAdapter` reads exactly two feeds: the ETH/USD price feed and the sequencer-uptime feed
(`docs/spec.md` §4.8, §6.10). A price is usable only if the sequencer feed answers 0 (up) and the
restart is at least `GRACE_PERIOD` old, the answer is positive, no older than `STALENESS`, inside
`[MIN_PRICE, MAX_PRICE]`, and `updatedAt` is not in the future. Both calls are `staticcall`s with a
gas cap and a post-failure gas check (ADR-0024). Reads are lazy: only operations that need a price
pay for one (§7).

## Alternatives considered

- **A custom oracle or a DEX TWAP.** On Base the deepest pools are the same ones the liquidation
  model measures for slippage (P25); using them as the price source would make the price endogenous
  to the very event being measured.
- **Several feeds with a median.** More code, more failure modes, and no second feed on Base with
  comparable history for P07.

## Consequences

- Oracle failure is a first-class state, not an exception: `failureStart` (§4.8) drives the
  `ORACLE` shutdown trigger (§6.11.1), and `lastGoodPrice` is informational only.
- The experiment inherits Chainlink's phase structure; history extraction must walk phases (P07).
- Every operation that needs a price can revert `PriceUnusable`; the invariant set must treat that
  as normal, not as a bug (P03).
