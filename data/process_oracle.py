"""Turn the stored oracle logs into two parquet files.

`data/processed/oracle_ethusd_base.parquet`

    phase                int16    proxy phase the round belongs to
    round_id             string   proxy round id, (phase << 64) | aggregator round — a uint80
    aggregator_round_id  string   round id inside the phase aggregator
    answer               string   raw int256 answer, FEED decimals (8) — never scaled, never float
    decimals             int8
    updated_at           int64    updatedAt from the log, UTC seconds
    block_number         int64
    block_timestamp      int64    genesis + 2 * block_number, checked against sampled headers
    tx_hash              string
    log_index            int32
    aggregator           string   phase aggregator that emitted the log
    in_phase             bool     False for the one round an aggregator published before its
                                  phase began (visible through the proxy from the phase start)

`data/processed/sequencer_base.parquet` — same columns plus `started_at` (int64, from
getRoundData through the proxy: the time of the status change). answer 0 = up, 1 = down.

On-chain integers are strings or exact int64 columns, never floats (data-pipeline skill). Round
ids are uint80 and do not fit int64 once phase-encoded, hence strings.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

from data.fetch_oracle import RAW_ROOT, collect_rows, encode_round, load_manifest

PROCESSED_ROOT = Path("data/processed")
OUTPUTS = {"eth_usd": "oracle_ethusd_base.parquet", "sequencer_uptime": "sequencer_base.parquet"}
BLOCK_TIME = 2  # seconds; Base produces a block every 2 s since genesis (checked, see below)

BASE_FIELDS = [
    pa.field("phase", pa.int16(), nullable=False),
    pa.field("round_id", pa.string(), nullable=False),
    pa.field("aggregator_round_id", pa.string(), nullable=False),
    pa.field("answer", pa.string(), nullable=False),
    pa.field("decimals", pa.int8(), nullable=False),
    pa.field("updated_at", pa.int64(), nullable=False),
    pa.field("block_number", pa.int64(), nullable=False),
    pa.field("block_timestamp", pa.int64(), nullable=False),
    pa.field("tx_hash", pa.string(), nullable=False),
    pa.field("log_index", pa.int32(), nullable=False),
    pa.field("aggregator", pa.string(), nullable=False),
    pa.field("in_phase", pa.bool_(), nullable=False),
]
ORACLE_SCHEMA = pa.schema(BASE_FIELDS)
SEQUENCER_SCHEMA = pa.schema([*BASE_FIELDS, pa.field("started_at", pa.int64(), nullable=False)])


def block_timestamp(block: int, genesis_ts: int) -> int:
    return genesis_ts + BLOCK_TIME * block


def check_rounds(frame: pd.DataFrame) -> list[str]:
    """Round ids strictly increase within each phase and are consecutive among in-phase rounds.

    Returns a list of human-readable problems; empty means clean.
    """
    problems = []
    for phase, group in frame.groupby("phase", sort=True):
        ids = group["aggregator_round_id"].astype("int64").to_numpy()
        if (ids[1:] <= ids[:-1]).any():
            problems.append(f"phase {phase}: round ids not strictly increasing")
        inside = group[group["in_phase"]]["aggregator_round_id"].astype("int64").to_numpy()
        jumps = [
            (int(a), int(b)) for a, b in zip(inside[:-1], inside[1:], strict=True) if b != a + 1
        ]
        for a, b in jumps:
            problems.append(f"phase {phase}: gap between rounds {a} and {b}")
    return problems


def build_frame(rows: list[dict], decimals: int, genesis_ts: int, started: dict | None = None):
    frame = pd.DataFrame(
        {
            "phase": pd.Series([r["phase"] for r in rows], dtype="int16"),
            "round_id": [str(encode_round(r["phase"], r["aggregator_round_id"])) for r in rows],
            "aggregator_round_id": [str(r["aggregator_round_id"]) for r in rows],
            "answer": [str(r["answer"]) for r in rows],
            "decimals": pd.Series([decimals] * len(rows), dtype="int8"),
            "updated_at": pd.Series([r["updated_at"] for r in rows], dtype="int64"),
            "block_number": pd.Series([r["block_number"] for r in rows], dtype="int64"),
            "block_timestamp": pd.Series(
                [block_timestamp(r["block_number"], genesis_ts) for r in rows], dtype="int64"
            ),
            "tx_hash": [r["tx_hash"] for r in rows],
            "log_index": pd.Series([r["log_index"] for r in rows], dtype="int32"),
            "aggregator": [r["aggregator"] for r in rows],
            "in_phase": pd.Series([r["in_phase"] for r in rows], dtype="bool"),
        }
    )
    if started is not None:
        missing = [rid for rid in frame["round_id"] if rid not in started]
        if missing:
            raise SystemExit(f"{len(missing)} sequencer rounds have no startedAt from getRoundData")
        frame["started_at"] = pd.Series([started[rid] for rid in frame["round_id"]], dtype="int64")
    return frame


def write(frame: pd.DataFrame, schema: pa.Schema, path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".parquet.part")
    pq.write_table(
        pa.Table.from_pandas(frame, schema=schema, preserve_index=False), tmp, compression="zstd"
    )
    tmp.replace(path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def process(*, root: Path = RAW_ROOT, stream=None) -> dict[str, str]:
    stream = stream or sys.stdout
    digests = {}
    for feed, filename in OUTPUTS.items():
        m = load_manifest(feed, root)
        if m is None or not m.verification:
            raise SystemExit(f"{feed}: no verified manifest — run `just oracle` first")
        genesis_ts = m.verification.get("genesis_timestamp")
        if genesis_ts is None:
            raise SystemExit(f"{feed}: manifest lacks the checked genesis timestamp")
        rows = collect_rows(m, root)
        started = m.verification.get("all_started_at") if feed == "sequencer_uptime" else None
        frame = build_frame(rows, m.decimals, genesis_ts, started)
        problems = check_rounds(frame)
        if problems:
            raise SystemExit(f"{feed}: " + "; ".join(problems[:10]))
        schema = SEQUENCER_SCHEMA if feed == "sequencer_uptime" else ORACLE_SCHEMA
        digests[feed] = write(frame, schema, PROCESSED_ROOT / filename)
        print(f"{feed}: {len(frame):,} rounds -> {PROCESSED_ROOT / filename}", file=stream)
    return digests


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    process()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
