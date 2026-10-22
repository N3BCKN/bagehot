"""Fetch one-minute ETH candles into `data/raw/prices/<source>/<YYYY-MM>.jsonl.gz`.

Chunked by UTC month, then by the source's page size. Resumable: a month with a `.meta.json`
whose checksum matches its data file is skipped without a single request. Idempotent: re-running
after a complete fetch issues no requests and changes no bytes.

    uv run python -m data.fetch_prices --dry-run                 # budget only, no network
    uv run python -m data.fetch_prices --source coinbase
    uv run python -m data.fetch_prices --start 2019-01-01 --end 2026-10-01

Raw pages are stored exactly as received, with the request that produced them, so processing can
be redone without refetching (data-pipeline skill).
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from data.http import RateLimiter, get_json, make_client
from data.sources import DEFAULT_SOURCES, MINUTE, SOURCES, Source, iso_utc

RAW_ROOT = Path("data/raw/prices")
DEFAULT_START = "2019-01-01"
ASK_ABOVE_REQUESTS = 50_000  # prompt's budget: above this, stop and ask the human


# ----------------------------------------------------------------------------- chunk planning
@dataclass(frozen=True)
class Window:
    start: int  # UTC seconds, inclusive, aligned to 60
    end: int  # UTC seconds, exclusive, aligned to 60

    @property
    def minutes(self) -> int:
        return (self.end - self.start) // MINUTE


def parse_day(text: str) -> int:
    """`YYYY-MM-DD` as UTC midnight. No local time anywhere in this pipeline."""
    return int(datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=UTC).timestamp())


def last_complete_month_end(now: datetime | None = None) -> int:
    """First second of the current UTC month: the exclusive end of the last complete month."""
    now = now or datetime.now(tz=UTC)
    return int(datetime(now.year, now.month, 1, tzinfo=UTC).timestamp())


def month_key(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=UTC).strftime("%Y-%m")


def month_windows(start: int, end: int) -> list[Window]:
    """Split [start, end) into calendar-month windows, UTC."""
    out: list[Window] = []
    cursor = start
    while cursor < end:
        day = datetime.fromtimestamp(cursor, tz=UTC)
        nxt = datetime(day.year + (day.month == 12), (day.month % 12) + 1, 1, tzinfo=UTC)
        out.append(Window(cursor, min(int(nxt.timestamp()), end)))
        cursor = int(nxt.timestamp())
    return out


def page_windows(window: Window, max_candles: int) -> Iterator[Window]:
    """Split one month into request-sized pages; the last page may be short."""
    span = max_candles * MINUTE
    cursor = window.start
    while cursor < window.end:
        yield Window(cursor, min(cursor + span, window.end))
        cursor += span


def plan(source: Source, start: int, end: int) -> list[tuple[Window, int]]:
    """(month window, number of requests) for every month in range."""
    return [
        (m, sum(1 for _ in page_windows(m, source.max_candles))) for m in month_windows(start, end)
    ]


# ----------------------------------------------------------------------------- raw storage
def month_paths(source: Source, month: str, *, root: Path = RAW_ROOT) -> tuple[Path, Path]:
    base = root / source.name
    return base / f"{month}.jsonl.gz", base / f"{month}.meta.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def month_is_complete(source: Source, window: Window, *, root: Path = RAW_ROOT) -> bool:
    """Done means: the meta exists, still describes the file on disk, and covers this window.

    The window comparison matters. A run restricted to part of a month (`--start`/`--end`) writes
    a meta for the range it actually fetched; a later full run must notice that the stored month
    is narrower than the one it wants and fetch it again, rather than skipping a half-filled
    month for ever.
    """
    data_path, meta_path = month_paths(source, month_key(window.start), root=root)
    if not (data_path.exists() and meta_path.exists()):
        return False
    try:
        meta = json.loads(meta_path.read_text())
    except json.JSONDecodeError:
        return False
    covers = meta.get("window_start") == window.start and meta.get("window_end") == window.end
    return covers and meta.get("complete") is True and meta.get("sha256") == sha256_file(data_path)


def fetch_month(
    source: Source,
    window: Window,
    *,
    client,
    limiter: RateLimiter,
    fetch=get_json,
    root: Path = RAW_ROOT,
) -> dict[str, Any]:
    """Fetch every page of one month and write it atomically. Returns the month's metadata."""
    month = month_key(window.start)
    data_path, meta_path = month_paths(source, month, root=root)
    data_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = data_path.with_suffix(".jsonl.gz.part")

    requests = 0
    rows = 0
    with gzip.open(tmp_path, "wt", encoding="utf-8") as out:
        for page in page_windows(window, source.max_candles):
            params = source.params(page.start, page.end)
            payload = fetch(client, source.url, params, limiter=limiter)
            requests += 1
            rows += len(source.parse(payload))
            record = {
                "fetched_at": datetime.now(tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "url": source.url,
                "params": params,
                "window": {"start": page.start, "end": page.end},
                "payload": payload,
            }
            out.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
    tmp_path.replace(data_path)

    meta = {
        "source": source.name,
        "venue": source.venue,
        "symbol": source.symbol,
        "quote": source.quote,
        "month": month,
        "window_start": window.start,
        "window_end": window.end,
        "window_start_iso": iso_utc(window.start),
        "window_end_iso": iso_utc(window.end),
        "requests": requests,
        "rows": rows,
        "sha256": sha256_file(data_path),
        "complete": True,
    }
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    return meta


def iter_raw_pages(source: Source, *, root: Path = RAW_ROOT) -> Iterator[dict[str, Any]]:
    """Every stored page of a source, oldest month first."""
    base = root / source.name
    for path in sorted(base.glob("*.jsonl.gz")):
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            for line in handle:
                yield json.loads(line)


# ----------------------------------------------------------------------------- driver
def fetch_source(
    source: Source,
    start: int,
    end: int,
    *,
    rps: float = 5.0,
    dry_run: bool = False,
    ask_above: int = ASK_ABOVE_REQUESTS,
    client=None,
    fetch=get_json,
    stream=None,
    root: Path = RAW_ROOT,
) -> dict[str, Any]:
    stream = stream or sys.stdout
    months = plan(source, start, end)
    pending = [(m, n) for m, n in months if not month_is_complete(source, m, root=root)]
    budget = sum(n for _, n in pending)
    total = sum(n for _, n in months)

    print(
        f"{source.name}: {iso_utc(start)} .. {iso_utc(end)}  "
        f"{len(months)} months, {total} requests planned, "
        f"{len(pending)} months pending, {budget} requests to send "
        f"(page size {source.max_candles}, {rps} req/s)",
        file=stream,
    )
    if budget > ask_above:
        raise SystemExit(
            f"request budget {budget} exceeds {ask_above}: stop and ask the human before running"
        )
    if dry_run:
        return {"source": source.name, "planned": total, "pending": budget, "sent": 0}

    limiter = RateLimiter(rps=rps)
    owns_client = client is None
    client = client or make_client()
    sent = 0
    try:
        for window, _ in pending:
            meta = fetch_month(
                source, window, client=client, limiter=limiter, fetch=fetch, root=root
            )
            sent += meta["requests"]
            print(
                f"  {meta['month']}: {meta['rows']} candles in {meta['requests']} requests",
                file=stream,
            )
    finally:
        if owns_client:
            client.close()
    return {"source": source.name, "planned": total, "pending": budget, "sent": sent}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--source", action="append", choices=sorted(SOURCES), help="repeatable")
    ap.add_argument("--start", default=DEFAULT_START, help="UTC day, inclusive (YYYY-MM-DD)")
    ap.add_argument("--end", default=None, help="UTC day, exclusive; default: start of this month")
    ap.add_argument("--rps", type=float, default=5.0)
    ap.add_argument("--dry-run", action="store_true", help="print the budget and exit")
    ap.add_argument("--max-requests", type=int, default=ASK_ABOVE_REQUESTS)
    args = ap.parse_args(argv)

    start = parse_day(args.start)
    end = parse_day(args.end) if args.end else last_complete_month_end()
    if end <= start:
        raise SystemExit(f"empty range: {iso_utc(start)} .. {iso_utc(end)}")

    for name in args.source or DEFAULT_SOURCES:
        fetch_source(
            SOURCES[name],
            start,
            end,
            rps=args.rps,
            dry_run=args.dry_run,
            ask_above=args.max_requests,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
