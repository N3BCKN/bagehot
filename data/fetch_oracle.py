"""Fetch Chainlink ETH/USD and L2-sequencer-uptime history on Base from an archive node.

    just oracle --verify-only     # on-chain check of config/8453.toml, a few requests
    just oracle --dry-run         # probe the provider's log-range cap and print the budget
    just oracle                   # fetch (resumable)

`just` loads BASE_ARCHIVE_RPC from .env; the value is never printed (data/rpc.py).

Method, per feed:
  1. Pin a head block (latest minus a reorg margin) and store it in the manifest, so a re-run
     scans exactly the same range and downloads nothing new.
  2. Verify `description()` and `decimals()` against config/8453.toml. Refuse to run on mismatch.
  3. Read the phase structure: `phaseId()` at head, `phaseAggregators(i)` for every phase, and the
     first block of each phase by binary search on `phaseId()` at historical blocks.
  4. Collect `AnswerUpdated(int256,uint256,uint256)` from each phase aggregator over its active
     range, filtered on that topic only (OCR aggregators also emit `NewTransmission`, which is
     never collected, so no round is counted twice). Ranges halve on "range too large".
     The last round an aggregator published *before* its phase began is collected too, because
     `latestRoundData()` returns it from the moment the phase starts.
  5. Re-read a sample of rounds through the proxy with phase-encoded ids
     `(phase << 64) | aggregatorRound` and require an exact match with the logs.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import random
import sys
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from eth_abi import decode, encode
from eth_utils import function_signature_to_4byte_selector, keccak, to_checksum_address

from data.rpc import RangeTooLarge, Rpc

CONFIG_PATH = Path("config/8453.toml")
RAW_ROOT = Path("data/raw/oracle")

ANSWER_UPDATED = "0x" + keccak(text="AnswerUpdated(int256,uint256,uint256)").hex()
PHASE_OFFSET = 64  # proxy round id = (phase << 64) | aggregator round id

REORG_MARGIN = 1_800  # blocks (one hour at 2 s) kept away from the tip
DEFAULT_MAX_CHUNK = 500_000
ASK_ABOVE_REQUESTS = 20_000  # P07 budget: above this, stop and ask the human
SAMPLE_ROUNDS = 200  # random rounds re-read through the proxy, per feed
FEEDS = ("eth_usd", "sequencer_uptime")


def selector(signature: str) -> str:
    return "0x" + function_signature_to_4byte_selector(signature).hex()


SEL = {
    name: selector(name)
    for name in (
        "description()",
        "decimals()",
        "phaseId()",
        "aggregator()",
        "latestRoundData()",
    )
}
SEL_PHASE_AGGREGATORS = selector("phaseAggregators(uint16)")
SEL_GET_ROUND_DATA = selector("getRoundData(uint80)")


# ----------------------------------------------------------------------------- config
def load_config(path: Path = CONFIG_PATH) -> dict[str, dict[str, Any]]:
    data = tomllib.loads(path.read_text())
    if data.get("chain_id") != 8453:
        raise SystemExit(f"{path}: chain_id must be 8453")
    feeds = {}
    for name in FEEDS:
        entry = dict(data["oracle"][name])
        if to_checksum_address(entry["proxy"]) != entry["proxy"]:
            raise SystemExit(f"{path}: {name} proxy is not EIP-55 checksummed")
        feeds[name] = entry
    return feeds


# ----------------------------------------------------------------------------- abi helpers
def call_string(rpc: Rpc, to: str, sel: str, block: int) -> str:
    return decode(["string"], bytes.fromhex(rpc.eth_call(to, sel, block)[2:]))[0]


def call_uint(rpc: Rpc, to: str, sel: str, block: int) -> int:
    raw = rpc.eth_call(to, sel, block)
    if raw in ("0x", ""):
        return 0  # no code at that block: treated as "not deployed yet"
    return decode(["uint256"], bytes.fromhex(raw[2:]))[0]


def phase_aggregator(rpc: Rpc, proxy: str, phase: int, block: int) -> str:
    data = SEL_PHASE_AGGREGATORS + encode(["uint16"], [phase]).hex()
    return to_checksum_address(
        decode(["address"], bytes.fromhex(rpc.eth_call(proxy, data, block)[2:]))[0]
    )


@dataclass(frozen=True)
class RoundData:
    round_id: int
    answer: int
    started_at: int
    updated_at: int
    answered_in_round: int


def get_round_data(rpc: Rpc, proxy: str, round_id: int, block: int) -> RoundData:
    data = SEL_GET_ROUND_DATA + encode(["uint80"], [round_id]).hex()
    out = decode(
        ["uint80", "int256", "uint256", "uint256", "uint80"],
        bytes.fromhex(rpc.eth_call(proxy, data, block)[2:]),
    )
    return RoundData(*out)


def encode_round(phase: int, aggregator_round: int) -> int:
    return (phase << PHASE_OFFSET) | aggregator_round


def decode_log(log: dict[str, Any]) -> dict[str, Any]:
    """AnswerUpdated: topic1 int256 current, topic2 uint256 roundId, data uint256 updatedAt."""
    topics = log["topics"]
    if topics[0].lower() != ANSWER_UPDATED:
        raise ValueError(f"not an AnswerUpdated log: {topics[0]}")
    answer = decode(["int256"], bytes.fromhex(topics[1][2:]))[0]
    round_id = int(topics[2], 16)
    updated_at = int(log["data"], 16)
    return {
        "aggregator_round_id": round_id,
        "answer": answer,
        "updated_at": updated_at,
        "block_number": int(log["blockNumber"], 16),
        "tx_hash": log["transactionHash"],
        "log_index": int(log["logIndex"], 16),
        "aggregator": to_checksum_address(log["address"]),
    }


# ----------------------------------------------------------------------------- phase structure
def first_block_where(predicate, lo: int, hi: int) -> int:
    """Smallest b in [lo, hi] with predicate(b) true, given predicate is monotone and true at hi."""
    while lo < hi:
        mid = (lo + hi) // 2
        if predicate(mid):
            hi = mid
        else:
            lo = mid + 1
    return lo


@dataclass
class Phase:
    phase: int
    aggregator: str
    start_block: int
    end_block: int  # inclusive


def read_phases(rpc: Rpc, proxy: str, head: int) -> tuple[int, list[Phase]]:
    """The proxy's creation block and its phases with their active block ranges."""
    current = call_uint(rpc, proxy, SEL["phaseId()"], head)
    if current == 0:
        raise SystemExit(f"{proxy}: phaseId() is 0 at head — not an aggregator proxy?")
    created = first_block_where(lambda b: rpc.get_code(proxy, b) not in ("0x", ""), 0, head)
    starts = [
        first_block_where(
            lambda b, i=i: call_uint(rpc, proxy, SEL["phaseId()"], b) >= i, created, head
        )
        for i in range(1, current + 1)
    ]
    phases = []
    for i, start in enumerate(starts, start=1):
        end = starts[i] - 1 if i < current else head
        phases.append(Phase(i, phase_aggregator(rpc, proxy, i, head), start, end))
    return created, phases


# ----------------------------------------------------------------------------- log scanning
@dataclass
class ScanState:
    chunk: int
    successes: int = 0
    max_chunk: int = DEFAULT_MAX_CHUNK
    halvings: int = 0

    def halve(self) -> None:
        if self.chunk == 1:
            raise SystemExit("provider refuses even a one-block log range")
        self.chunk = max(1, self.chunk // 2)
        self.successes = 0
        self.halvings += 1

    def succeeded(self) -> None:
        # Grow back slowly: providers that cap by result count only need small ranges where the
        # feed is busy.
        self.successes += 1
        if self.successes >= 8 and self.chunk < self.max_chunk:
            self.chunk = min(self.max_chunk, self.chunk * 2)
            self.successes = 0


def probe_chunk(rpc: Rpc, address: str, start: int, end: int, max_chunk: int) -> int:
    """Largest range (halving from max_chunk) the provider accepts at the start of [start, end]."""
    chunk = max_chunk
    while True:
        try:
            rpc.get_logs(address, [ANSWER_UPDATED], start, min(end, start + chunk - 1))
            return chunk
        except RangeTooLarge:
            if chunk == 1:
                raise SystemExit("provider refuses even a one-block log range") from None
            chunk //= 2


def phase_dir(feed: str, phase: int, root: Path = RAW_ROOT) -> Path:
    return root / feed / f"phase-{phase}"


def load_phase_meta(feed: str, phase: int, root: Path = RAW_ROOT) -> dict[str, Any]:
    path = phase_dir(feed, phase, root) / "meta.json"
    return json.loads(path.read_text()) if path.exists() else {}


def save_phase_meta(feed: str, phase: int, meta: dict[str, Any], root: Path = RAW_ROOT) -> None:
    path = phase_dir(feed, phase, root) / "meta.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.part")
    tmp.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def write_chunk(feed: str, phase: int, lo: int, hi: int, logs: list, root: Path = RAW_ROOT) -> None:
    path = phase_dir(feed, phase, root) / f"{lo:010d}-{hi:010d}.json.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".gz.part")
    with gzip.open(tmp, "wt", encoding="utf-8") as out:
        json.dump({"from_block": lo, "to_block": hi, "logs": logs}, out, separators=(",", ":"))
    tmp.replace(path)


def scan_phase(
    rpc: Rpc,
    feed: str,
    phase: Phase,
    state: ScanState,
    *,
    root: Path = RAW_ROOT,
    stream=None,
) -> int:
    """Scan [start, end] of one phase, resuming from the meta. Returns logs found this call."""
    stream = stream or sys.stdout
    meta = load_phase_meta(feed, phase.phase, root)
    if meta.get("aggregator") not in (None, phase.aggregator):
        raise SystemExit(f"{feed} phase {phase.phase}: stored aggregator differs from the chain")
    scanned_to = meta.get("scanned_to", phase.start_block - 1)
    found = 0
    cursor = scanned_to + 1
    while cursor <= phase.end_block:
        hi = min(phase.end_block, cursor + state.chunk - 1)
        try:
            logs = rpc.get_logs(phase.aggregator, [ANSWER_UPDATED], cursor, hi)
        except RangeTooLarge:
            state.halve()
            continue
        state.succeeded()
        write_chunk(feed, phase.phase, cursor, hi, logs, root)
        found += len(logs)
        meta.update(
            {
                "phase": phase.phase,
                "aggregator": phase.aggregator,
                "start_block": phase.start_block,
                "end_block": phase.end_block,
                "scanned_to": hi,
                "complete": hi == phase.end_block,
            }
        )
        save_phase_meta(feed, phase.phase, meta, root)
        cursor = hi + 1
    if found:
        print(f"  {feed} phase {phase.phase}: {found} logs (chunk now {state.chunk})", file=stream)
    return found


def find_pre_phase_log(
    rpc: Rpc, phase: Phase, state: ScanState, floor: int
) -> dict[str, Any] | None:
    """The aggregator's last AnswerUpdated strictly before its phase began, if any."""
    hi = phase.start_block - 1
    while hi >= floor:
        lo = max(floor, hi - state.chunk + 1)
        try:
            logs = rpc.get_logs(phase.aggregator, [ANSWER_UPDATED], lo, hi)
        except RangeTooLarge:
            state.halve()
            continue
        if logs:
            return max(logs, key=lambda x: (int(x["blockNumber"], 16), int(x["logIndex"], 16)))
        hi = lo - 1
    return None


def iter_phase_logs(feed: str, phase: int, root: Path = RAW_ROOT):
    for path in sorted(phase_dir(feed, phase, root).glob("*.json.gz")):
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            yield from json.load(handle)["logs"]


# ----------------------------------------------------------------------------- manifest
@dataclass
class FeedManifest:
    feed: str
    proxy: str
    description: str
    decimals: int
    head: int
    created_block: int
    phases: list[dict[str, Any]] = field(default_factory=list)
    pre_phase_logs: dict[str, Any] = field(default_factory=dict)
    verification: dict[str, Any] = field(default_factory=dict)


def manifest_path(feed: str, root: Path = RAW_ROOT) -> Path:
    return root / feed / "manifest.json"


def save_manifest(m: FeedManifest, root: Path = RAW_ROOT) -> None:
    path = manifest_path(m.feed, root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(m), indent=2, sort_keys=True) + "\n")


def load_manifest(feed: str, root: Path = RAW_ROOT) -> FeedManifest | None:
    path = manifest_path(feed, root)
    return FeedManifest(**json.loads(path.read_text())) if path.exists() else None


# ----------------------------------------------------------------------------- verification
def verify_feed(rpc: Rpc, name: str, cfg: dict[str, Any], head: int) -> tuple[str, int]:
    desc = call_string(rpc, cfg["proxy"], SEL["description()"], head)
    dec = call_uint(rpc, cfg["proxy"], SEL["decimals()"], head)
    if desc != cfg["description"] or dec != cfg["decimals"]:
        raise SystemExit(
            f"{name}: chain says description={desc!r} decimals={dec}, config says "
            f"{cfg['description']!r} / {cfg['decimals']} — refusing to continue"
        )
    return desc, dec


def verify_rounds(
    rpc: Rpc, m: FeedManifest, rows: list[dict[str, Any]], rng: random.Random
) -> dict[str, Any]:
    """Re-read rounds through the proxy and require an exact match with the logs."""
    by_phase: dict[int, list[dict[str, Any]]] = {}
    for r in rows:
        by_phase.setdefault(r["phase"], []).append(r)
    chosen: list[dict[str, Any]] = []
    for phase_rows in by_phase.values():
        chosen += [phase_rows[0], phase_rows[-1]]
    pool = [r for r in rows if r not in chosen]
    chosen += rng.sample(pool, min(SAMPLE_ROUNDS, len(pool)))

    mismatches = []
    started: dict[str, int] = {}
    for r in chosen:
        rid = encode_round(r["phase"], r["aggregator_round_id"])
        got = get_round_data(rpc, m.proxy, rid, m.head)
        if got.round_id != rid or got.answer != r["answer"] or got.updated_at != r["updated_at"]:
            mismatches.append(
                {
                    "round_id": str(rid),
                    "log": [r["answer"], r["updated_at"]],
                    "proxy": [got.answer, got.updated_at],
                }
            )
        started[str(rid)] = got.started_at
    return {"checked": len(chosen), "mismatches": mismatches, "started_at": started}


TIMESTAMP_SAMPLES = 40


def sequencer_outage_blocks(m: FeedManifest, root: Path = RAW_ROOT) -> list[int]:
    """Blocks of the sequencer feed's status changes: where a timestamp anomaly would show."""
    return [r["block_number"] for r in collect_rows(m, root)]


def verify_timestamps(rpc: Rpc, head: int, extra: list[int], rng: random.Random) -> dict[str, Any]:
    """Check timestamp(n) == timestamp(0) + 2n on random blocks and on the given blocks."""
    genesis = rpc.get_block_timestamp(0)
    blocks = sorted(set(rng.sample(range(1, head), TIMESTAMP_SAMPLES) + extra + [head]))
    mismatches = []
    for b in blocks:
        actual = rpc.get_block_timestamp(b)
        if actual != genesis + 2 * b:
            mismatches.append({"block": b, "expected": genesis + 2 * b, "actual": actual})
    return {
        "genesis_timestamp": genesis,
        "timestamp_samples": len(blocks),
        "timestamp_mismatches": mismatches,
    }


# ----------------------------------------------------------------------------- driver
def collect_rows(m: FeedManifest, root: Path = RAW_ROOT) -> list[dict[str, Any]]:
    rows = []
    for p in m.phases:
        for log in iter_phase_logs(m.feed, p["phase"], root):
            row = decode_log(log)
            row["phase"] = p["phase"]
            row["in_phase"] = True
            rows.append(row)
        pre = m.pre_phase_logs.get(str(p["phase"]))
        if pre:
            row = decode_log(pre)
            row["phase"] = p["phase"]
            row["in_phase"] = False
            rows.append(row)
    rows.sort(key=lambda r: (r["phase"], r["aggregator_round_id"]))
    return rows


def fetch(
    *,
    verify_only: bool = False,
    dry_run: bool = False,
    max_chunk: int = DEFAULT_MAX_CHUNK,
    ask_above: int = ASK_ABOVE_REQUESTS,
    refresh_head: bool = False,
    rps: float = 10.0,
    root: Path = RAW_ROOT,
) -> int:
    cfg = load_config()
    with Rpc.from_env(rps=rps) as rpc:
        latest = rpc.block_number()
        manifests: dict[str, FeedManifest] = {}

        for name in FEEDS:
            old = load_manifest(name, root)
            head = old.head if (old and not refresh_head) else latest - REORG_MARGIN
            desc, dec = verify_feed(rpc, name, cfg[name], head)
            print(f"{name}: {cfg[name]['proxy']} verified on-chain: {desc!r}, {dec} decimals")
            if verify_only:
                continue
            if old and old.head == head and old.phases:
                m = old
            else:
                created, phases = read_phases(rpc, cfg[name]["proxy"], head)
                m = FeedManifest(
                    name, cfg[name]["proxy"], desc, dec, head, created, [asdict(p) for p in phases]
                )
                save_manifest(m, root)
            manifests[name] = m
            for p in m.phases:
                span = f"{p['start_block']}..{p['end_block']}"
                print(f"  phase {p['phase']}: {p['aggregator']} blocks {span}")

        if verify_only:
            print(f"requests used: {rpc.requests}")
            return 0

        # ---- budget, from a probe of the provider's range cap
        first = manifests["eth_usd"].phases[0]
        chunk = probe_chunk(
            rpc, first["aggregator"], first["start_block"], first["end_block"], max_chunk
        )
        remaining = 0
        for m in manifests.values():
            for p in m.phases:
                done = load_phase_meta(m.feed, p["phase"], root).get(
                    "scanned_to", p["start_block"] - 1
                )
                remaining += math.ceil(max(0, p["end_block"] - done) / chunk)
        fixed = 2 * (SAMPLE_ROUNDS + 10) + 60
        budget = remaining + fixed
        print(
            f"log-range cap accepted: {chunk:,} blocks; requests so far: {rpc.requests}; "
            f"estimated remaining: {budget:,} ({remaining:,} log chunks + ~{fixed} checks)"
        )
        if budget > ask_above:
            raise SystemExit(
                f"estimated {budget:,} requests exceeds {ask_above:,}: stop and ask the human"
            )
        if dry_run:
            return 0

        # ---- scan
        for m in manifests.values():
            state = ScanState(chunk=chunk, max_chunk=chunk)
            for p in m.phases:
                phase = Phase(**p)
                scan_phase(rpc, m.feed, phase, state, root=root)
                if str(p["phase"]) not in m.pre_phase_logs:
                    pre = find_pre_phase_log(rpc, phase, state, m.created_block)
                    m.pre_phase_logs[str(p["phase"])] = pre
                    save_manifest(m, root)
            if state.halvings:
                print(f"  {m.feed}: range halved {state.halvings} times during the scan")

            # ---- verification through the proxy
            if not m.verification:
                rows = collect_rows(m, root)
                m.verification = verify_rounds(rpc, m, rows, random.Random(8453))
                if m.feed == "sequencer_uptime":
                    # Few rounds: read startedAt (the time of the status change) for every one.
                    m.verification["all_started_at"] = {
                        str(encode_round(r["phase"], r["aggregator_round_id"])): get_round_data(
                            rpc, m.proxy, encode_round(r["phase"], r["aggregator_round_id"]), m.head
                        ).started_at
                        for r in rows
                    }
                save_manifest(m, root)
            v = m.verification
            print(
                f"  {m.feed}: getRoundData checked {v['checked']} rounds, "
                f"{len(v['mismatches'])} mismatches"
            )
            if v["mismatches"]:
                raise SystemExit(f"{m.feed}: proxy rounds disagree with logs — see the manifest")

        # ---- block timestamps: Base is 2 s per block; check the formula, including outages
        ts_check = None
        for m in manifests.values():
            if "genesis_timestamp" not in m.verification:
                if ts_check is None:
                    outage_blocks = sequencer_outage_blocks(manifests["sequencer_uptime"], root)
                    ts_check = verify_timestamps(
                        rpc, manifests["eth_usd"].head, outage_blocks, random.Random(2)
                    )
                m.verification.update(ts_check)
                save_manifest(m, root)
        t = manifests["eth_usd"].verification
        print(
            f"  block timestamps: genesis {t['genesis_timestamp']}, "
            f"{t['timestamp_samples']} headers checked, "
            f"{len(t['timestamp_mismatches'])} mismatches"
        )
        if t["timestamp_mismatches"]:
            raise SystemExit("block timestamps do not follow genesis + 2 * n — see the manifest")

        print(f"requests used this run: {rpc.requests}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="probe and print the budget, no scan")
    ap.add_argument("--max-chunk", type=int, default=DEFAULT_MAX_CHUNK)
    ap.add_argument("--max-requests", type=int, default=ASK_ABOVE_REQUESTS)
    ap.add_argument("--refresh-head", action="store_true", help="extend to a new head block")
    ap.add_argument("--rps", type=float, default=10.0)
    args = ap.parse_args(argv)
    return fetch(
        verify_only=args.verify_only,
        dry_run=args.dry_run,
        max_chunk=args.max_chunk,
        ask_above=args.max_requests,
        refresh_head=args.refresh_head,
        rps=args.rps,
    )


if __name__ == "__main__":
    raise SystemExit(main())
