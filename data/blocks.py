"""Choose the Base blocks the fork experiments start from: stress, calm, and named (P09).

    just blocks            # select from P06 prices, resolve block numbers on Base, write parquet

Stress blocks: the top-k 15-minute absolute ETH log returns since Base launch (Coinbase minutes,
P06), de-duplicated so no two lie within STRESS_SEPARATION of each other. Calm blocks: random
24-hour windows from the lowest decile of realised volatility, also de-duplicated. 2024-08-05 is
always included, at its largest 15-minute move. Every row says why it was chosen and carries the
price context around it.

Timestamp → block is a binary search on `eth_getBlockByNumber`, cached; it works on any chain.
On Base it starts from genesis + 2n as a guess, so a lookup costs a couple of headers.
"""

from __future__ import annotations

import argparse
import json
import random
import sqlite3
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

from data.analyze_oracle import day
from data.rpc import Rpc
from data.sources import iso_utc

PROCESSED = Path("data/processed")
COINBASE = PROCESSED / "prices_coinbase_1m.parquet"
CACHE = Path("data/raw/blocks/timestamps.sqlite")
OUTPUT = PROCESSED / "blocks_selected.parquet"

BASE_PUBLIC_LAUNCH = "2023-08-09"  # Base mainnet opened to the public; earlier blocks were dev-only
STRESS_K = 20
STRESS_SEPARATION = 6 * 3600
CALM_K = 10
CALM_SEPARATION = 7 * 86400  # between calm picks: diversity across market regimes
CALM_CLEAR_OF_STRESS = 2 * 86400  # a calm pick only needs to stay clear of a stress state
CALM_DECILE = 0.10
NAMED = {"2024-08-05": "2024-08-05"}
SEED = 9


# ----------------------------------------------------------------------------- price features
def minute_frame(path: Path = COINBASE, start_ts: int | None = None) -> pd.DataFrame:
    """Coinbase closes on a full minute grid. Missing minutes stay NaN — no forward fill here
    either, so a return across a gap is NaN rather than a stale-price artefact."""
    m = pd.read_parquet(path, columns=["ts", "close"])
    if start_ts is not None:
        m = m[m["ts"] >= start_ts]
    grid = np.arange(int(m["ts"].iloc[0]), int(m["ts"].iloc[-1]) + 60, 60)
    close = pd.Series(m["close"].to_numpy(), index=m["ts"].to_numpy()).reindex(grid)
    f = pd.DataFrame({"ts": grid, "close": close.to_numpy()})
    logc = np.log(f["close"])
    f["ret_15m"] = logc - logc.shift(15)
    # 24h return against the last close at most 10 minutes before t - 24h, so a single missing
    # minute does not erase the context (the 15-minute return stays exact: it ranks the picks).
    past = logc.shift(1440)
    for lag in range(1441, 1451):
        past = past.fillna(logc.shift(lag))
    f["ret_24h"] = logc - past
    r1 = logc.diff()
    # 24h realised volatility of 1-minute returns, annualised; needs most of the day present.
    f["vol_24h"] = r1.rolling(1440, min_periods=1200).std() * np.sqrt(525_600)
    return f


def pick_separated(
    candidates: pd.DataFrame,
    k: int,
    separation: int,
    order_col: str,
    ascending: bool,
    avoid: list[int] | None = None,
    avoid_separation: int | None = None,
) -> pd.DataFrame:
    """Greedy top-k by `order_col`.

    A candidate is skipped if it lies within `separation` of an earlier pick of this kind, or
    within `avoid_separation` (default: `separation`) of a timestamp in `avoid` — picks of other
    kinds. Fewer than k picks is reported, never silent.
    """
    avoid = list(avoid or [])
    avoid_separation = separation if avoid_separation is None else avoid_separation
    taken: list[int] = []
    chosen = []
    for _, row in candidates.sort_values(order_col, ascending=ascending).iterrows():
        if len(chosen) == k:
            break
        t0 = int(row["ts"])
        if any(abs(t0 - t) < separation for t in taken):
            continue
        if any(abs(t0 - t) < avoid_separation for t in avoid):
            continue
        taken.append(t0)
        chosen.append(row)
    return pd.DataFrame(chosen)


def select_times(f: pd.DataFrame, rng: random.Random) -> pd.DataFrame:
    """The selected timestamps with kind, rank, reason and price context."""
    rows = []
    # Named windows first, so stress picks are de-duplicated against them.
    for name, d in NAMED.items():
        w = f[(f["ts"] >= day(d)) & (f["ts"] < day(d) + 86400)].dropna(subset=["ret_15m"])
        best = w.loc[w["ret_15m"].abs().idxmax()]
        rows.append(
            {
                **best.to_dict(),
                "kind": "named",
                "rank": 0,
                "reason": f"named window {name}: largest 15-min move that day "
                f"({best['ret_15m'] * 100:+.2f}%)",
            }
        )
    named_ts = [int(r["ts"]) for r in rows]

    moves = f.dropna(subset=["ret_15m"]).assign(abs_ret=lambda x: x["ret_15m"].abs())
    stress = pick_separated(moves, STRESS_K, STRESS_SEPARATION, "abs_ret", False, named_ts)
    for rank, (_, r) in enumerate(stress.iterrows(), start=1):
        rows.append(
            {
                **r.drop("abs_ret").to_dict(),
                "kind": "stress",
                "rank": rank,
                "reason": f"top-{STRESS_K} 15-min |log return| since Base launch, rank {rank} "
                f"({r['ret_15m'] * 100:+.2f}%), ≥ {STRESS_SEPARATION // 3600} h from "
                "other picks",
            }
        )

    vols = f.dropna(subset=["vol_24h"])
    cut = vols["vol_24h"].quantile(CALM_DECILE)
    calm_pool = vols[vols["vol_24h"] <= cut].sample(frac=1.0, random_state=rng.randrange(2**31))
    calm_pool = calm_pool.assign(order=np.arange(len(calm_pool)))
    stress_ts = [int(r["ts"]) for r in rows]
    calm = pick_separated(
        calm_pool,
        CALM_K,
        CALM_SEPARATION,
        "order",
        True,
        stress_ts,
        avoid_separation=CALM_CLEAR_OF_STRESS,
    )
    for kind, got, want in (("stress", len(stress), STRESS_K), ("calm", len(calm), CALM_K)):
        if got < want:
            print(f"warning: only {got} of {want} {kind} blocks satisfy the separation rules")
    for rank, (_, r) in enumerate(calm.iterrows(), start=1):
        rows.append(
            {
                **r.drop("order").to_dict(),
                "kind": "calm",
                "rank": rank,
                "reason": f"random 24h window in the lowest {CALM_DECILE:.0%} of realised "
                f"volatility (≤ {cut * 100:.1f}% annualised; this one "
                f"{r['vol_24h'] * 100:.1f}%), ≥ {CALM_SEPARATION // 86400} days from other "
                f"calm picks and ≥ {CALM_CLEAR_OF_STRESS // 86400} days from stress picks",
            }
        )
    out = pd.DataFrame(rows)
    out["ts"] = out["ts"].astype("int64")
    return out.sort_values("ts", ignore_index=True)


# ----------------------------------------------------------------------------- ts → block
class BlockClock:
    """Timestamp → the last block at or before it, by binary search on headers, cached."""

    def __init__(self, rpc: Rpc, chain: str, cache: Path = CACHE):
        cache.parent.mkdir(parents=True, exist_ok=True)
        self.rpc, self.chain = rpc, chain
        self.db = sqlite3.connect(cache)
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS headers (chain TEXT, block INTEGER, ts INTEGER,"
            " PRIMARY KEY (chain, block))"
        )

    def timestamp(self, block: int) -> int:
        row = self.db.execute(
            "SELECT ts FROM headers WHERE chain=? AND block=?", (self.chain, block)
        ).fetchone()
        if row:
            return row[0]
        ts = self.rpc.get_block_timestamp(block)
        self.db.execute("INSERT INTO headers VALUES (?,?,?)", (self.chain, block, ts))
        self.db.commit()
        return ts

    def block_at(self, ts: int, lo: int, hi: int, guess: int | None = None) -> int:
        """Largest block b in [lo, hi] with timestamp(b) <= ts. `guess` narrows the bracket."""
        if guess is not None and lo <= guess <= hi:
            if self.timestamp(guess) <= ts:
                lo = guess
                if guess + 1 <= hi and self.timestamp(guess + 1) > ts:
                    return guess
            else:
                hi = guess - 1
        if self.timestamp(lo) > ts:
            raise ValueError(f"{iso_utc(ts)} is before block {lo}")
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.timestamp(mid) <= ts:
                lo = mid
            else:
                hi = mid - 1
        return lo


@dataclass(frozen=True)
class BaseChain:
    genesis_ts: int
    head: int

    def guess(self, ts: int) -> int:
        return max(0, min(self.head, (ts - self.genesis_ts) // 2))


def resolve(times: pd.DataFrame, clock: BlockClock, chain: BaseChain) -> pd.DataFrame:
    out = times.copy()
    blocks = [clock.block_at(int(t), 0, chain.head, chain.guess(int(t))) for t in out["ts"]]
    out["block_number"] = pd.Series(blocks, dtype="int64")
    out["block_timestamp"] = pd.Series([clock.timestamp(b) for b in blocks], dtype="int64")
    return out


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    f = minute_frame(start_ts=day(BASE_PUBLIC_LAUNCH))
    times = select_times(f, random.Random(SEED))
    with Rpc.from_env() as rpc:
        head = rpc.block_number() - 1_800
        clock = BlockClock(rpc, "base")
        chain = BaseChain(clock.timestamp(0), head)
        out = resolve(times, clock, chain)
        print(f"resolved {len(out)} blocks with {rpc.requests} requests")
    out["iso"] = out["ts"].map(iso_utc)
    cols = [
        "kind",
        "rank",
        "ts",
        "iso",
        "block_number",
        "block_timestamp",
        "reason",
        "close",
        "ret_15m",
        "ret_24h",
        "vol_24h",
    ]
    PROCESSED.mkdir(parents=True, exist_ok=True)
    out[cols].to_parquet(OUTPUT, index=False)
    print(json.dumps(out["kind"].value_counts().to_dict()), f"-> {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
