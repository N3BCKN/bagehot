"""Fetch and process every dataset the report needs. Driven by `just data`.

P06 added prices. Later prompts append their own steps here (oracle history P07, liquidations
P08, costs P09, liquidity P25). Each step is resumable, so re-running after an interruption
continues rather than restarting, and a complete run issues no requests at all.

    uv run python -m data.fetch_all              # everything, default sources
    uv run python -m data.fetch_all --dry-run    # budgets only, no network
"""

from __future__ import annotations

import argparse

from data.fetch_prices import (
    ASK_ABOVE_REQUESTS,
    DEFAULT_START,
    fetch_source,
    last_complete_month_end,
    parse_day,
)
from data.process_prices import process
from data.sources import DEFAULT_SOURCES, SOURCES


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--source", action="append", choices=sorted(SOURCES), help="repeatable")
    ap.add_argument("--start", default=DEFAULT_START)
    ap.add_argument("--end", default=None)
    ap.add_argument("--rps", type=float, default=5.0)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-requests", type=int, default=ASK_ABOVE_REQUESTS)
    args = ap.parse_args(argv)

    start = parse_day(args.start)
    end = parse_day(args.end) if args.end else last_complete_month_end()
    names = args.source or list(DEFAULT_SOURCES)

    budget = 0
    for name in names:
        result = fetch_source(
            SOURCES[name],
            start,
            end,
            rps=args.rps,
            dry_run=args.dry_run,
            ask_above=args.max_requests,
        )
        budget += result["pending"]
    if args.dry_run:
        print(f"total requests to send: {budget}")
        return 0

    for name in names:
        process(SOURCES[name])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
