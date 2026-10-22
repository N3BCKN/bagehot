# Data card — selected Base blocks (stress, calm, named)

Starting points for the fork experiments (P09). Produced by `just blocks`
(`data/blocks.py`) from the P06 Coinbase minute series plus Base block headers.

## Selection rules

| kind | rule |
|---|---|
| named | 2024-08-05, at that day's largest 15-minute move |
| stress | top 20 absolute 15-minute log returns since Base's public launch (2023-08-09), no two within 6 h of each other or of the named pick |
| calm | 10 random 24-hour windows from the lowest decile of realised volatility (annualised std of 1-minute log returns), ≥ 7 days apart from each other and ≥ 2 days from any stress pick; seed 9 |

Returns are computed only across contiguous minutes — a move spanning a Coinbase gap is not a
candidate. The 24-hour return looks back to the last close at most 10 minutes before t − 24 h.

## Timestamp → block

A binary search on `eth_getBlockByNumber`, cached in `data/raw/blocks/timestamps.sqlite`, returning
the last block at or before the selected minute. On Base it starts from genesis + 2n, so a lookup
costs about two headers (31 blocks resolved in 64 requests). `ts − block_timestamp` is 1 s for
every row: Base blocks fall on odd seconds, the selected minutes on even ones.

## Known characteristics

- One calm block (2024-06-01 22:55 UTC) has no 24-hour return: t − 24 h falls inside Coinbase's
  67-minute gap of 2024-05-31 22:11–23:19 (`reports/data-validation.md`). Left empty rather than
  filled from another moment; the block keeps its price, 15-minute return and volatility.
- Price context (`close`, `ret_15m`, `ret_24h`, `vol_24h`) is Coinbase's, not the on-chain oracle's.

<!-- generated: files -->

| field | value |
|---|---|
| processed file | `data/processed/blocks_selected.parquet` |
| sha256 | `880fa4f2432ba70aae9225bca430e761518c37942efe41ee1eddaf63cfec2d63` |
| rows | 31 |
| columns | `kind`, `rank`, `ts`, `iso`, `block_number`, `block_timestamp`, `reason`, `close`, `ret_15m`, `ret_24h`, `vol_24h` |
| generated | 2026-10-22 |

<!-- /generated -->
