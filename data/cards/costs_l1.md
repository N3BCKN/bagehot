# Data card — Ethereum L1 per-gas prices in the named stress windows

`just costs l1` (`data/fetch_costs.py`). Per-gas prices only: the gas our liquidation uses is
measured at P20, and the L1-regime cost is that gas × these prices, computed there.

## Source

| field | value |
|---|---|
| chain | Ethereum mainnet (1), read-only, RPC from `ETH_MAINNET_RPC` (never printed) |
| windows | 2020-03-12/13, 2021-05-19, 2022-05-09..12, 2024-08-05 (UTC days) |
| window bounds | exact block headers at each window's first and last block (binary search, cached) |
| retrieved | 2026-10-22 |

## Method

- **After London (EIP-1559)**: `eth_feeHistory` for every block if the provider serves that depth;
  otherwise every 10th block read in full (column `source` says which). Base fee from the header,
  priority-fee percentiles gas-weighted.
- **Before London (2020, 2021)**: there is no base fee. Every 10th block is read in full and the
  gas-weighted percentiles of the price paid are computed (`price_p*_wei`; weights = gas limit,
  because receipts are not read for L1).
- `block_timestamp_approx` is linear in block number between the exact window bounds — approximate
  by construction, hence the name.

<!-- generated: files -->

| field | value |
|---|---|
| processed file | `data/processed/costs_l1.parquet` |
| sha256 | `0e219ebb5a2b2be319ebe93eec7c2583647ee1be90b0eb43b1993cd8fd2d9e56` |
| rows | 5,136 |
| columns | `block_number`, `block_timestamp`, `base_fee_wei`, `gas_used_ratio`, `fee_txs`, `weights`, `priority_p10_wei`, `priority_p25_wei`, `priority_p50_wei`, `priority_p75_wei`, `priority_p90_wei`, `price_p10_wei`, `price_p25_wei`, `price_p50_wei`, `price_p75_wei`, `price_p90_wei`, `source`, `window`, `regime`, `block_timestamp_approx` |
| generated | 2026-10-22 |

<!-- /generated -->
