# ADR-0011: Run the experiments on a Base mainnet fork

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §6 decision 11. The quantities the report is about — how fast liquidators arrive, how
much slippage a liquidation of a given size suffers, what a transaction costs during a crash —
only exist where real liquidity and a real oracle do. A testnet has neither: its pools are empty
and its feeds are synthetic, so every number measured there would describe the testnet.

## Decision

Experiments run against a fork of Base mainnet pinned to specific blocks, chosen for the stress
episodes identified at P09. Liquidity is measured in the fork at those blocks (P25), oracle
history is extracted from the real aggregators (P07), and transaction cost combines L2 execution
with the L1 data fee read from the GasPriceOracle predeploy (P09/P24). Base Sepolia (84532) is
used only for the end-to-end deployment demonstration (P42), never for measurement. Mainnet is
read-only: no broadcast ever targets 8453 (ADR-0019).

## Alternatives considered

- **Pure simulation with assumed liquidity.** Cheap, but the slippage model would be an
  assumption rather than a measurement, and the A/B comparison turns on exactly that number.
- **Testnet measurement.** Produces numbers that look like data and are not.

## Consequences

- Every measured number is tied to a block number, which goes into the data cards (ADR-0020) and
  the preregistration (ADR-0013).
- An archive RPC for Base is a hard dependency of the data prompts.
- Results describe Base at those blocks. The report states the episodes it used.
