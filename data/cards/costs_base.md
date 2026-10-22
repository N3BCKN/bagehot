# Data card — Base transaction costs at the selected blocks

`just costs base` (`data/fetch_costs.py`). Kit correction 10: a Base transaction costs L2
execution plus an L1 data fee; both are here.

## Source

| field | value |
|---|---|
| chain | Base mainnet (8453), read-only, archive RPC from `BASE_ARCHIVE_RPC` (never printed) |
| L2 execution | the 30 blocks (one minute) ending at each selected block, read in full with `eth_getBlockReceipts` |
| L1 data fee | OP Stack `GasPriceOracle` predeploy `0x420000000000000000000000000000000000000F`, `getL1Fee(bytes)`, `l1BaseFee()`, `blobBaseFee()`, archive `eth_call` at the selected block |
| retrieved | 2026-10-22 |

## Method

- **Why full blocks, not `eth_feeHistory`:** the provider serves `eth_feeHistory` only for recent
  blocks (HTTP 503 at depth, verified). Reading the blocks gives the same statistic independently of
  provider depth: base fee from the header; priority fee = `min(maxPriorityFeePerGas,
  maxFeePerGas − baseFee)` (EIP-1559) or `gasPrice − baseFee` (legacy), percentiles weighted by gas
  used from the receipts — what `eth_feeHistory` computes. Column `weights` records `gas_used` for
  every row here.
- **OP Stack deposit transactions** (type `0x7e`, including the L1-attributes system transaction)
  pay no fee and are excluded.
- **L1 data fee payloads** are RLP-encoded EIP-1559 envelopes with deterministic pseudo-random
  signature bytes (real signatures are incompressible noise, and the oracle prices compressed size):
  Bagehot A `liquidate(uint256)`, Bagehot B `buy(uint256,uint256,uint256,address,bytes)`, and Aave v3
  `liquidationCall(...)` as a reference. Byte sizes are in the `payload_bytes_*` columns.
- Wei values are exact integers; `eth_usd` (Coinbase close at the selected block) is for USD
  conversion in the report only.

## Known characteristics

- `blob_base_fee_wei` is null at the 9 selected blocks before Base's Ecotone upgrade (March 2024),
  where `blobBaseFee()` does not exist. Those are also the blocks with the largest L1 data fees
  (≈ $1–1.50 per liquidation against ≈ $0.0005–0.0007 after blobs).

<!-- generated: files -->

| field | value |
|---|---|
| processed file | `data/processed/costs_base.parquet` |
| sha256 | `8815252bedd3b6c2ea91f00031849c97e2586dd4b6d3d9503dc0c59b651bad48` |
| rows | 930 |
| columns | `block_number`, `block_timestamp`, `base_fee_wei`, `gas_used_ratio`, `fee_txs`, `weights`, `priority_p10_wei`, `priority_p25_wei`, `priority_p50_wei`, `priority_p75_wei`, `priority_p90_wei`, `price_p10_wei`, `price_p25_wei`, `price_p50_wei`, `price_p75_wei`, `price_p90_wei`, `selected_block`, `kind`, `rank`, `eth_usd`, `is_selected`, `l1_fee_wei_bagehot_a_liquidate`, `l1_fee_wei_bagehot_b_buy`, `l1_fee_wei_aave_liquidation_call`, `l1_base_fee_wei`, `blob_base_fee_wei`, `payload_bytes_bagehot_a`, `payload_bytes_bagehot_b`, `payload_bytes_aave` |
| generated | 2026-10-22 |

<!-- /generated -->
