"""Turn stored raw pages into `data/processed/prices_<source>_1m.parquet`.

Schema, exactly:

    ts      int64    candle OPEN time, UTC seconds, always a multiple of 60
    open    float64
    high    float64
    low     float64
    close   float64
    volume  float64
    source  string

Missing minutes stay missing. Nothing is forward-filled, interpolated or invented here: a gap in
the venue's data is a fact about the venue, and `validate.py` reports it. A zero-volume minute is
a real row and is kept as one — it is not the same thing as a gap.

    uv run python -m data.process_prices --source coinbase --write-card
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

from data.fetch_prices import RAW_ROOT, iter_raw_pages, month_paths
from data.sources import DEFAULT_SOURCES, MINUTE, SOURCES, Candle, Source, iso_utc

PROCESSED_ROOT = Path("data/processed")
CARD_ROOT = Path("data/cards")

SCHEMA = pa.schema(
    [
        pa.field("ts", pa.int64(), nullable=False),
        pa.field("open", pa.float64(), nullable=False),
        pa.field("high", pa.float64(), nullable=False),
        pa.field("low", pa.float64(), nullable=False),
        pa.field("close", pa.float64(), nullable=False),
        pa.field("volume", pa.float64(), nullable=False),
        pa.field("source", pa.string(), nullable=False),
    ]
)

GEN_START = "<!-- generated: files -->"
GEN_END = "<!-- /generated -->"


def processed_path(source: Source) -> Path:
    return PROCESSED_ROOT / f"prices_{source.name}_1m.parquet"


def candles_to_frame(candles: Iterable[Candle], source: Source) -> tuple[pd.DataFrame, dict]:
    """Deduplicate, sort and type the candles. Returns the frame and a small provenance report."""
    rows = list(candles)
    misaligned = [c.ts for c in rows if c.ts % MINUTE]
    if misaligned:
        raise ValueError(
            f"{source.name}: {len(misaligned)} candle timestamps are not minute-aligned"
        )

    frame = pd.DataFrame(
        {
            "ts": pd.Series([c.ts for c in rows], dtype="int64"),
            "open": pd.Series([c.open for c in rows], dtype="float64"),
            "high": pd.Series([c.high for c in rows], dtype="float64"),
            "low": pd.Series([c.low for c in rows], dtype="float64"),
            "close": pd.Series([c.close for c in rows], dtype="float64"),
            "volume": pd.Series([c.volume for c in rows], dtype="float64"),
        }
    )
    frame["source"] = source.name

    duplicated = int(frame.duplicated(subset="ts").sum())
    value_cols = ["open", "high", "low", "close", "volume"]
    # A duplicate that disagrees with its twin is worth knowing about: overlapping pages should
    # return identical candles, and a conflict means the venue revised the bar.
    conflicts = int(frame.duplicated(subset=["ts", *value_cols]).sum())
    conflicting = duplicated - conflicts

    frame = frame.drop_duplicates(subset="ts", keep="last").sort_values("ts", ignore_index=True)

    # A venue that pads no-trade minutes with zero-volume bars has forward-filled them itself.
    # A bar with no volume is not an observed price, so it becomes a gap like any other.
    empty = 0
    if source.emits_empty_minutes:
        no_trade = frame["volume"] == 0.0
        empty = int(no_trade.sum())
        frame = frame[~no_trade].reset_index(drop=True)

    return frame, {
        "rows_in": len(rows),
        "rows_out": int(len(frame)),
        "duplicate_rows": duplicated,
        "conflicting_duplicates": int(conflicting),
        "empty_minutes_dropped": empty,
    }


def build(source: Source, *, root: Path = RAW_ROOT) -> tuple[pd.DataFrame, dict]:
    candles: list[Candle] = []
    pages = 0
    for page in iter_raw_pages(source, root=root):
        candles.extend(source.parse(page["payload"]))
        pages += 1
    frame, report = candles_to_frame(candles, source)
    report["pages"] = pages
    return frame, report


def write_parquet(frame: pd.DataFrame, path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    table = pa.Table.from_pandas(frame, schema=SCHEMA, preserve_index=False)
    tmp = path.with_suffix(".parquet.part")
    pq.write_table(table, tmp, compression="zstd")
    tmp.replace(path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def month_metas(source: Source, *, root: Path = RAW_ROOT) -> list[dict]:
    out = []
    for meta_path in sorted((root / source.name).glob("*.meta.json")):
        out.append(json.loads(meta_path.read_text()))
    return out


def card_block(source: Source, frame: pd.DataFrame, report: dict, digest: str) -> str:
    metas = month_metas(source)
    requests = sum(m.get("requests", 0) for m in metas)
    first_ts, last_ts = (
        (int(frame["ts"].iloc[0]), int(frame["ts"].iloc[-1])) if len(frame) else (0, 0)
    )
    expected = ((last_ts - first_ts) // MINUTE + 1) if len(frame) else 0
    coverage = (len(frame) / expected * 100.0) if expected else 0.0
    raw_bytes = sum(month_paths(source, m["month"])[0].stat().st_size for m in metas)

    return "\n".join(
        [
            GEN_START,
            "",
            "| field | value |",
            "|---|---|",
            f"| processed file | `{processed_path(source).as_posix()}` |",
            f"| sha256 | `{digest}` |",
            f"| rows | {len(frame):,} |",
            f"| first candle (open, UTC) | {iso_utc(first_ts)} |",
            f"| last candle (open, UTC) | {iso_utc(last_ts)} |",
            f"| minutes in range | {expected:,} |",
            f"| coverage | {coverage:.4f}% |",
            f"| duplicate raw rows dropped | {report['duplicate_rows']:,} "
            f"({report['conflicting_duplicates']:,} with differing values) |",
            f"| zero-volume (no-trade) bars turned into gaps | "
            f"{report['empty_minutes_dropped']:,} |",
            f"| raw months | {len(metas)} |",
            f"| raw pages | {report['pages']:,} |",
            f"| raw requests | {requests:,} |",
            f"| raw bytes (gzip) | {raw_bytes:,} |",
            f"| generated | {datetime.now(tz=UTC).strftime('%Y-%m-%d')} |",
            "",
            "Per-month raw checksums live in `data/raw/prices/"
            f"{source.name}/<YYYY-MM>.meta.json` (git-ignored, regenerated by the fetcher).",
            "",
            GEN_END,
        ]
    )


def update_card(source: Source, block: str) -> Path:
    path = CARD_ROOT / f"prices_{source.name}.md"
    text = path.read_text()
    if GEN_START not in text or GEN_END not in text:
        raise SystemExit(f"{path}: generated block markers missing")
    updated = re.sub(
        re.escape(GEN_START) + r".*?" + re.escape(GEN_END), block, text, flags=re.DOTALL
    )
    path.write_text(updated)
    return path


def process(source: Source, *, write_card: bool = True, stream=None) -> dict:
    stream = stream or sys.stdout
    frame, report = build(source)
    if frame.empty:
        raise SystemExit(f"{source.name}: no raw pages found — run data.fetch_prices first")
    digest = write_parquet(frame, processed_path(source))
    report["sha256"] = digest
    print(
        f"{source.name}: {len(frame):,} rows -> {processed_path(source)} "
        f"({report['duplicate_rows']:,} duplicates dropped)",
        file=stream,
    )
    if write_card:
        path = update_card(source, card_block(source, frame, report, digest))
        print(f"{source.name}: card updated {path}", file=stream)
    return report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--source", action="append", choices=sorted(SOURCES), help="repeatable")
    ap.add_argument("--no-card", action="store_true")
    args = ap.parse_args(argv)
    for name in args.source or DEFAULT_SOURCES:
        process(SOURCES[name], write_card=not args.no_card)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
