"""Resumable `eth_getLogs` over a block range, with adaptive halving.

One directory per scan. Each accepted request is written as `<from>-<to>.json.gz`, then the
directory's `meta.json` advances `scanned_to`. An interrupted scan resumes from there; a finished
one issues no requests at all (data-pipeline skill: resumable, idempotent).
"""

from __future__ import annotations

import gzip
import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from data.fetch_oracle import ScanState
from data.rpc import RangeTooLarge


def _meta_path(directory: Path) -> Path:
    return directory / "meta.json"


def load_meta(directory: Path) -> dict[str, Any]:
    path = _meta_path(directory)
    return json.loads(path.read_text()) if path.exists() else {}


def _save_meta(directory: Path, meta: dict[str, Any]) -> None:
    path = _meta_path(directory)
    tmp = path.with_suffix(".json.part")
    tmp.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def scan_range(
    rpc,
    address: str,
    topics: list,
    lo: int,
    hi: int,
    directory: Path,
    state: ScanState,
) -> int:
    """Scan [lo, hi] inclusive into `directory`. Returns the number of logs fetched by this call.

    The query (address, topics, lo) is stored in the meta; resuming with a different query is
    refused rather than silently mixing two datasets.
    """
    directory.mkdir(parents=True, exist_ok=True)
    meta = load_meta(directory)
    query = {"address": address, "topics": topics, "from_block": lo}
    if meta and meta.get("query") != query:
        raise SystemExit(f"{directory}: stored scan was for a different query — refusing to mix")
    cursor = meta.get("scanned_to", lo - 1) + 1
    found = 0
    while cursor <= hi:
        top = min(hi, cursor + state.chunk - 1)
        try:
            logs = rpc.get_logs(address, topics, cursor, top)
        except RangeTooLarge:
            state.halve()
            continue
        state.succeeded()
        part = directory / f"{cursor:010d}-{top:010d}.json.gz"
        tmp = part.with_suffix(".gz.part")
        with gzip.open(tmp, "wt", encoding="utf-8") as out:
            json.dump(
                {"from_block": cursor, "to_block": top, "logs": logs}, out, separators=(",", ":")
            )
        tmp.replace(part)
        found += len(logs)
        _save_meta(directory, {"query": query, "scanned_to": top, "to_block": hi})
        cursor = top + 1
    return found


def iter_logs(directory: Path) -> Iterator[dict[str, Any]]:
    """Every stored log of a scan, in block order (files are named by block range)."""
    for part in sorted(directory.glob("*.json.gz")):
        with gzip.open(part, "rt", encoding="utf-8") as handle:
            yield from json.load(handle)["logs"]
