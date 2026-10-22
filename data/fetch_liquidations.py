"""Aave v3 liquidations on Base and the liquidatable windows behind them (P08).

Observed liquidations alone are biased: a position that became liquidatable and was never
liquidated inside the window leaves no event. So this module reconstructs, per stress window, when
each position *became* liquidatable (onset) and treats the time to liquidation as a duration with
right-censoring (ADR-0025).

    just liquidations logs                     # stage 1: events, windows, oracle updates
    just liquidations plan                     # prints the exact eth_call budget of stage 2
    just liquidations calls --approve-calls N  # stage 2, refuses unless N equals the plan
    just liquidations build                    # parquet outputs + spot checks

Approximation, stated where the results are used: health factor is read from Aave itself
(`getUserAccountData`), but only for users whose collateral is WETH alone and whose debt is USDC
and/or USDbC, outside eMode. For those users HF is linear in the WETH price, which is what lets the
onset be predicted from one call and then confirmed exactly by bracketing calls.

Every `eth_call` result is cached in SQLite keyed by (method, block, user): a re-run makes none.
"""

from __future__ import annotations

import argparse
import json
import random
import sqlite3
import sys
import tomllib
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import pandas as pd
from eth_abi import decode, encode
from eth_utils import keccak, to_checksum_address

from data.fetch_oracle import (
    ANSWER_UPDATED,
    REORG_MARGIN,
    SEL,
    ScanState,
    first_block_where,
    probe_chunk,
    selector,
    verify_timestamps,
)
from data.logscan import iter_logs, load_meta, scan_range
from data.rpc import Rpc

CONFIG_PATH = Path("config/8453.toml")
RAW_ROOT = Path("data/raw/liquidations")
PROCESSED_ROOT = Path("data/processed")
COINBASE = PROCESSED_ROOT / "prices_coinbase_1m.parquet"

WAD = 10**18
DEFAULT_SAMPLE = 300  # sampled (not liquidated) users per window
SPOT_CHECKS = 10
WINDOW_TAIL = 12 * 3600  # follow-up after a 24-hour drop, for late liquidations and recoveries
NAMED_WINDOWS = {"2024-08-05": ("2024-08-05", "2024-08-06")}
DRAWDOWNS = 3


def topic(signature: str) -> str:
    return "0x" + keccak(text=signature).hex()


LIQUIDATION_CALL = topic("LiquidationCall(address,address,address,uint256,uint256,address,bool)")
SUPPLY = topic("Supply(address,address,address,uint256,uint16)")
BORROW = topic("Borrow(address,address,address,uint256,uint8,uint256,uint16)")

SEL_ACCOUNT = selector("getUserAccountData(address)")
SEL_CONFIG = selector("getUserConfiguration(address)")
SEL_EMODE = selector("getUserEMode(address)")
SEL_RESERVES = selector("getReservesList()")
SEL_SOURCE = selector("getSourceOfAsset(address)")
SEL_ASSET_PRICE = selector("getAssetPrice(address)")


def address_topic(address: str) -> str:
    return "0x" + "0" * 24 + address[2:].lower()


def topic_address(value: str) -> str:
    return to_checksum_address("0x" + value[-40:])


# ----------------------------------------------------------------------------- config
@dataclass(frozen=True)
class Aave:
    pool: str
    oracle: str
    weth: str
    stables: dict[str, str]  # underlying -> label


def load_aave(path: Path = CONFIG_PATH) -> Aave:
    cfg = tomllib.loads(path.read_text())["aave_v3"]
    assets = cfg["assets"]
    return Aave(
        pool=cfg["pool"],
        oracle=cfg["aave_oracle"],
        weth=assets["WETH"]["underlying"],
        stables={assets[k]["underlying"]: assets[k]["label"] for k in ("USDC", "USDbC")},
    )


# ----------------------------------------------------------------------------- decoding
def decode_liquidation(log: dict[str, Any], aave: Aave) -> dict[str, Any]:
    """LiquidationCall. Topics: collateral, debt, user. Data: debtToCover, collateral amount,
    liquidator, receiveAToken."""
    debt_to_cover, collateral, liquidator, receive_a = decode(
        ["uint256", "uint256", "address", "bool"], bytes.fromhex(log["data"][2:])
    )
    debt_asset = topic_address(log["topics"][2])
    return {
        "user": topic_address(log["topics"][3]),
        "collateral_asset": topic_address(log["topics"][1]),
        "debt_asset": debt_asset,
        "debt_label": aave.stables.get(debt_asset, "other"),
        "debt_to_cover": str(debt_to_cover),
        "liquidated_collateral": str(collateral),
        "liquidator": to_checksum_address(liquidator),
        "receive_a_token": bool(receive_a),
        "block_number": int(log["blockNumber"], 16),
        "tx_hash": log["transactionHash"],
        "log_index": int(log["logIndex"], 16),
    }


def on_behalf_of(log: dict[str, Any]) -> str:
    """Supply and Borrow both index `onBehalfOf` as topic 2: the account whose position changed."""
    return topic_address(log["topics"][2])


def decode_account(raw: str) -> dict[str, int]:
    names = ("collateral_base", "debt_base", "available_base", "liq_threshold", "ltv", "hf")
    return dict(zip(names, decode(["uint256"] * 6, bytes.fromhex(raw[2:])), strict=True))


def single_weth_collateral(bitmap: int, reserves: list[str], aave: Aave) -> tuple[bool, str]:
    """Aave UserConfigurationMap: bit 2i = borrowing reserve i; bit 2i+1 = collateral reserve i."""
    collateral = {reserves[i] for i in range(len(reserves)) if bitmap >> (2 * i + 1) & 1}
    borrowing = {reserves[i] for i in range(len(reserves)) if bitmap >> (2 * i) & 1}
    if not borrowing:
        return False, "no_debt"
    if collateral != {aave.weth}:
        return False, "not_weth_only_collateral"
    if not borrowing <= set(aave.stables):
        return False, "non_stable_debt"
    return True, ""


# ----------------------------------------------------------------------------- windows
@dataclass(frozen=True)
class Window:
    id: str
    start_ts: int
    end_ts: int
    start_block: int
    end_block: int


def ts_to_block(ts: int, genesis_ts: int, *, ceil: bool) -> int:
    q, r = divmod(ts - genesis_ts, 2)
    return q + (1 if ceil and r else 0)


def build_windows(market: pd.Series, from_ts: int, genesis_ts: int, head: int) -> list[Window]:
    """The named window plus the largest Base-era 24-hour drops, each followed by WINDOW_TAIL."""
    from data.analyze_oracle import day, drawdown_windows

    spans: dict[str, tuple[int, int]] = {
        name: (day(a), day(b)) for name, (a, b) in NAMED_WINDOWS.items()
    }
    for label, (a, b) in drawdown_windows(market, from_ts, k=DRAWDOWNS + len(spans)).items():
        if len(spans) >= DRAWDOWNS + len(NAMED_WINDOWS):
            break
        if any(a < y and x < b for x, y in spans.values()):
            continue  # overlaps a window already chosen
        spans[label.split(" ")[0] + "-drop"] = (a, b)
    out = []
    for wid, (a, b) in sorted(spans.items(), key=lambda kv: kv[1][0]):
        end = b + WINDOW_TAIL
        out.append(
            Window(
                wid,
                a,
                end,
                ts_to_block(a, genesis_ts, ceil=True),
                min(head, ts_to_block(end, genesis_ts, ceil=False)),
            )
        )
    return out


# ----------------------------------------------------------------------------- onset logic
def first_below(prices: list[int], threshold: int) -> int | None:
    """Index of the first price strictly below `threshold`."""
    return next((i for i, p in enumerate(prices) if p < threshold), None)


def liquidation_price(price0: int, hf0: int) -> int:
    """HF is linear in the WETH price for a WETH-only, stablecoin-debt position."""
    return price0 * WAD // hf0


def walk_to_onset(below, n: int, start: int, *, forward: bool = True) -> int | None:
    """First index in [0, n) where `below(i)` is true, searching from `start`.

    `below(i)` costs one eth_call. From a correct prediction this takes two calls: the start
    (true) and the index before it (false). If the start is false, `forward` decides whether to
    walk on (a prediction that came slightly early) or to conclude there is no onset (the start was
    already the most likely index, e.g. the window's lowest price).
    """
    if n == 0:
        return None
    i = min(max(start, 0), n - 1)
    if below(i):
        while i > 0 and below(i - 1):
            i -= 1
        return i
    if not forward:
        return None
    for j in range(i + 1, n):
        if below(j):
            return j
    return None


def onset_start(prices: list[int], threshold: int, *, liquidated: bool) -> tuple[int, bool]:
    """Where to start the onset search, and whether to walk forward from there.

    With a predicted index (the first price under the user's liquidation price) the search starts
    there and may walk forward. Without one, the position must have changed during the window (or
    it never became liquidatable): a liquidated user is checked at the last update before the
    liquidation, a sampled user at the window's lowest price — one call either way, then a
    backward walk only if that call finds HF < 1.
    """
    predicted = first_below(prices, threshold)
    if predicted is not None:
        return predicted, True
    if liquidated:
        return len(prices) - 1, False
    return min(range(len(prices)), key=prices.__getitem__), False


# ----------------------------------------------------------------------------- call cache
class BudgetExhausted(RuntimeError):
    pass


class CachedCaller:
    """eth_call through an SQLite cache. Only cache misses count against the approved budget."""

    def __init__(self, rpc, path: Path, budget: int | None):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.rpc = rpc
        self.db = sqlite3.connect(path)
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS calls (method TEXT, block INTEGER, arg TEXT, result TEXT,"
            " PRIMARY KEY (method, block, arg))"
        )
        # Cumulative spend across runs: a stop-and-resume must not reset the approved budget.
        self.db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER)")
        row = self.db.execute("SELECT value FROM meta WHERE key='spent'").fetchone()
        self.spent = row[0] if row else 0
        self.budget = budget
        self.hits = 0

    def call(self, method: str, to: str, data: str, block: int, arg: str) -> str:
        row = self.db.execute(
            "SELECT result FROM calls WHERE method=? AND block=? AND arg=?", (method, block, arg)
        ).fetchone()
        if row:
            self.hits += 1
            return row[0]
        if self.budget is not None and self.spent >= self.budget:
            raise BudgetExhausted(f"approved budget of {self.budget} eth_calls reached")
        result = self.rpc.eth_call(to, data, block)
        self.spent += 1
        self.db.execute("INSERT INTO calls VALUES (?,?,?,?)", (method, block, arg, result))
        self.db.execute("INSERT OR REPLACE INTO meta VALUES ('spent', ?)", (self.spent,))
        self.db.commit()
        return result

    def user_call(self, method: str, sel: str, pool: str, user: str, block: int) -> str:
        data = sel + encode(["address"], [user]).hex()
        return self.call(method, pool, data, block, user.lower())


# ----------------------------------------------------------------------------- stage 1
def manifest_path(root: Path = RAW_ROOT) -> Path:
    return root / "manifest.json"


def load_manifest(root: Path = RAW_ROOT) -> dict[str, Any]:
    path = manifest_path(root)
    return json.loads(path.read_text()) if path.exists() else {}


def save_manifest(m: dict[str, Any], root: Path = RAW_ROOT) -> None:
    manifest_path(root).parent.mkdir(parents=True, exist_ok=True)
    manifest_path(root).write_text(json.dumps(m, indent=2, sort_keys=True) + "\n")


def market_series(path: Path = COINBASE) -> pd.Series:
    if not path.exists():
        raise SystemExit(f"{path} missing — P06 prices are needed to choose the windows")
    m = pd.read_parquet(path, columns=["ts", "close"])
    return pd.Series(m["close"].to_numpy(), index=m["ts"].to_numpy())


def uint_call(rpc, to: str, data: str, block: int) -> int:
    return decode(["uint256"], bytes.fromhex(rpc.eth_call(to, data, block)[2:]))[0]


def address_call(rpc, to: str, data: str, block: int) -> str:
    return to_checksum_address(
        decode(["address"], bytes.fromhex(rpc.eth_call(to, data, block)[2:]))[0]
    )


def window_oracle(rpc, aave: Aave, w: Window, state: ScanState, root: Path) -> dict[str, Any]:
    """The WETH price source Aave used in the window, and every update of it there."""
    arg = encode(["address"], [aave.weth]).hex()
    src_start = address_call(rpc, aave.oracle, SEL_SOURCE + arg, w.start_block)
    src_end = address_call(rpc, aave.oracle, SEL_SOURCE + arg, w.end_block)
    if src_start != src_end:
        raise SystemExit(f"{w.id}: Aave changed the WETH source inside the window — handle by hand")
    agg_start = address_call(rpc, src_start, SEL["aggregator()"], w.start_block)
    agg_end = address_call(rpc, src_start, SEL["aggregator()"], w.end_block)
    if agg_start != agg_end:
        raise SystemExit(
            f"{w.id}: the source switched aggregator inside the window — handle by hand"
        )

    directory = root / "windows" / w.id / "oracle"
    scan_range(rpc, agg_start, [ANSWER_UPDATED], w.start_block, w.end_block, directory, state)
    # The update in force when the window opens: the last one before it.
    before = None
    hi = w.start_block - 1
    while before is None and hi > w.start_block - 2_000_000:
        lo = hi - state.chunk + 1
        logs = rpc.get_logs(agg_start, [ANSWER_UPDATED], lo, hi)
        before = logs[-1] if logs else None
        hi = lo - 1
    if before is None:
        raise SystemExit(f"{w.id}: no oracle update in the 2M blocks before the window")

    # Aave's own price at the window start must equal that answer, or the source is an adapter.
    aave_price = uint_call(rpc, aave.oracle, SEL_ASSET_PRICE + arg, w.start_block)
    answer_before = decode(["int256"], bytes.fromhex(before["topics"][1][2:]))[0]
    if aave_price != answer_before:
        raise SystemExit(
            f"{w.id}: AaveOracle price {aave_price} != source answer {answer_before} — the source "
            "is not a plain feed; the linear-HF onset prediction would be wrong"
        )
    return {"source": src_start, "aggregator": agg_start, "before": before}


def stage_logs(rpc: Rpc, aave: Aave, *, max_chunk: int, root: Path = RAW_ROOT) -> dict[str, Any]:
    m = load_manifest(root)
    if "head" not in m:
        m["head"] = rpc.block_number() - REORG_MARGIN
        m["genesis_ts"] = rpc.get_block_timestamp(0)
        m["timestamp_check"] = verify_timestamps(rpc, m["head"], [], random.Random(8))
        if m["timestamp_check"]["timestamp_mismatches"]:
            raise SystemExit("block timestamps do not follow genesis + 2n")
        m["pool_created"] = first_block_where(
            lambda b: rpc.get_code(aave.pool, b) not in ("0x", ""), 0, m["head"]
        )
        save_manifest(m, root)
    head, genesis, created = m["head"], m["genesis_ts"], m["pool_created"]

    if "windows" not in m:
        windows = build_windows(market_series(), genesis + 2 * created, genesis, head)
        m["windows"] = [asdict(w) for w in windows]
        save_manifest(m, root)
    windows = [Window(**w) for w in m["windows"]]
    print("windows: " + ", ".join(f"{w.id} [{w.start_block:,}..{w.end_block:,}]" for w in windows))

    chunk = probe_chunk(rpc, aave.pool, created, head, max_chunk)
    state = ScanState(chunk=chunk, max_chunk=chunk)
    stables = [address_topic(a) for a in aave.stables]
    last_end = max(w.end_block for w in windows)

    scans = {
        "liquidations": ([LIQUIDATION_CALL, address_topic(aave.weth), stables], created, head),
        "supply_weth": ([SUPPLY, address_topic(aave.weth)], created, last_end),
        "borrow_stable": ([BORROW, stables], created, last_end),
    }
    for name, (topics, lo, hi) in scans.items():
        n = scan_range(rpc, aave.pool, topics, lo, hi, root / name, state)
        print(f"  {name}: +{n} logs (scanned to {load_meta(root / name)['scanned_to']:,})")

    for w in windows:
        key = f"oracle:{w.id}"
        if key not in m:
            m[key] = window_oracle(rpc, aave, w, state, root)
            save_manifest(m, root)
    print(f"stage 1 requests: {rpc.requests}")
    return m


# ----------------------------------------------------------------------------- plan
def window_updates(w: Window, m: dict[str, Any], root: Path = RAW_ROOT) -> list[tuple[int, int]]:
    """(block, answer) of every source update in force during the window, oldest first."""
    before = m[f"oracle:{w.id}"]["before"]
    logs = [before, *iter_logs(root / "windows" / w.id / "oracle")]
    out = []
    for lg in logs:
        answer = decode(["int256"], bytes.fromhex(lg["topics"][1][2:]))[0]
        out.append((int(lg["blockNumber"], 16), answer))
    return out


def falling(updates: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Updates whose answer fell versus the previous one (the first entry is the opening price)."""
    return [u for prev, u in zip(updates, updates[1:], strict=False) if u[1] < prev[1]]


def cohorts(w: Window, aave: Aave, root: Path, sample: int, seed: int) -> dict[str, list[str]]:
    liq = [decode_liquidation(lg, aave) for lg in iter_logs(root / "liquidations")]
    liquidated = sorted(
        {r["user"] for r in liq if w.start_block <= r["block_number"] <= w.end_block}
    )
    suppliers = {
        on_behalf_of(lg)
        for lg in iter_logs(root / "supply_weth")
        if int(lg["blockNumber"], 16) < w.start_block
    }
    borrowers = {
        on_behalf_of(lg)
        for lg in iter_logs(root / "borrow_stable")
        if int(lg["blockNumber"], 16) < w.start_block
    }
    pool = sorted((suppliers & borrowers) - set(liquidated))
    rng = random.Random(f"{seed}:{w.id}")
    return {"liquidated": liquidated, "sampled": sorted(rng.sample(pool, min(sample, len(pool))))}


def plan_calls(m: dict[str, Any], aave: Aave, *, sample: int, seed: int, root: Path = RAW_ROOT):
    """Exact count of stage-2 eth_calls for the planned path, per window and category."""
    rows = []
    for wd in m["windows"]:
        w = Window(**wd)
        c = cohorts(w, aave, root, sample, seed)
        users = len(c["liquidated"]) + len(c["sampled"])
        rows.append(
            {
                "window": w.id,
                "liquidated": len(c["liquidated"]),
                "sampled": len(c["sampled"]),
                "reserves_list": 1,
                "filters": 3 * users,  # configuration, eMode, account data at the window start
                "onset_brackets": 2 * users,
                "recovery_brackets": 2 * len(c["sampled"]),
                "falling_updates": len(falling(window_updates(w, m, root))),
            }
        )
    total = sum(
        r["reserves_list"] + r["filters"] + r["onset_brackets"] + r["recovery_brackets"]
        for r in rows
    )
    return rows, total + SPOT_CHECKS


# ----------------------------------------------------------------------------- stage 2
def reconstruct_window(
    w: Window, m, aave: Aave, caller: CachedCaller, users: dict[str, list[str]], root: Path
):
    reserves_raw = caller.call("getReservesList", aave.pool, SEL_RESERVES, w.start_block, "")
    reserves = [
        to_checksum_address(a) for a in decode(["address[]"], bytes.fromhex(reserves_raw[2:]))[0]
    ]
    updates = window_updates(w, m, root)
    price0 = updates[0][1]
    drops = falling(updates)
    drop_prices = [p for _, p in drops]
    liq = [decode_liquidation(lg, aave) for lg in iter_logs(root / "liquidations")]
    first_liq: dict[str, dict] = {}
    for r in sorted(liq, key=lambda r: (r["block_number"], r["log_index"])):
        if w.start_block <= r["block_number"] <= w.end_block:
            first_liq.setdefault(r["user"], r)

    def account(user: str, block: int) -> dict[str, int]:
        return decode_account(
            caller.user_call("getUserAccountData", SEL_ACCOUNT, aave.pool, user, block)
        )

    out, excluded = [], []
    for cohort, members in users.items():
        for user in members:
            bitmap = decode(
                ["uint256"],
                bytes.fromhex(
                    caller.user_call(
                        "getUserConfiguration", SEL_CONFIG, aave.pool, user, w.start_block
                    )[2:]
                ),
            )[0]
            emode = decode(
                ["uint256"],
                bytes.fromhex(
                    caller.user_call("getUserEMode", SEL_EMODE, aave.pool, user, w.start_block)[2:]
                ),
            )[0]
            if emode:
                excluded.append({"user": user, "cohort": cohort, "reason": f"emode_{emode}"})
                continue
            ok, reason = single_weth_collateral(bitmap, reserves, aave)
            if not ok:
                excluded.append({"user": user, "cohort": cohort, "reason": reason})
                continue
            a0 = account(user, w.start_block)
            if a0["debt_base"] == 0:
                excluded.append({"user": user, "cohort": cohort, "reason": "no_debt"})
                continue
            if a0["hf"] < WAD:
                excluded.append({"user": user, "cohort": cohort, "reason": "liquidatable_at_start"})
                continue

            liq_row = first_liq.get(user)
            limit = len(drops)
            if liq_row:  # end-of-block state at the liquidation block is post-liquidation
                limit = sum(1 for b, _ in drops if b < liq_row["block_number"])
            threshold = liquidation_price(price0, a0["hf"])
            onset_idx, predicted = None, None
            if limit:
                start, forward = onset_start(
                    drop_prices[:limit], threshold, liquidated=bool(liq_row)
                )
                predicted = start if forward else None
                onset_idx = walk_to_onset(
                    lambda i, u=user: account(u, drops[i][0])["hf"] < WAD,
                    limit,
                    start,
                    forward=forward,
                )

            if onset_idx is None:
                if liq_row and any(b == liq_row["block_number"] for b, _ in drops):
                    onset_block = liq_row[
                        "block_number"
                    ]  # oracle update and liquidation in one block
                    method = "same_block"
                else:
                    excluded.append(
                        {
                            "user": user,
                            "cohort": cohort,
                            "reason": "liquidated_without_observed_onset"
                            if liq_row
                            else "never_liquidatable",
                        }
                    )
                    continue
            else:
                onset_block, method = (
                    drops[onset_idx][0],
                    "predicted" if onset_idx == predicted else "walked",
                )

            onset_acct = account(user, onset_block) if method != "same_block" else a0
            if liq_row:
                end_block, event, reason = liq_row["block_number"], 1, ""
            else:
                end_block, event, reason = w.end_block, 0, "window_end"
                later = [(b, p) for b, p in updates if b > onset_block]
                rec = next((k for k, (_, p) in enumerate(later) if p >= threshold), None)
                if rec is not None and account(user, later[rec][0])["hf"] >= WAD:
                    end_block, reason = later[rec][0], "recovery"
            out.append(
                {
                    "user": user,
                    "window_id": w.id,
                    "cohort": cohort,
                    "onset_block": onset_block,
                    "end_block": end_block,
                    "event": event,
                    "censor_reason": reason,
                    "onset_method": method,
                    "collateral_base_at_onset": str(onset_acct["collateral_base"]),
                    "debt_base_at_onset": str(onset_acct["debt_base"]),
                    "hf_at_onset": str(onset_acct["hf"]),
                    "hf_at_window_start": str(a0["hf"]),
                    "debt_label": liq_row["debt_label"] if liq_row else "",
                }
            )
    return out, excluded


def check_approval(approve: int, total: int, spent: int) -> None:
    """The first approval must equal the printed plan exactly. Only once that much has been spent
    may a larger, newly approved number extend it."""
    if approve == total or (approve > total and spent >= total):
        return
    raise SystemExit(f"--approve-calls {approve} does not match the plan ({total}); run `plan`")


def stage_calls(rpc, aave: Aave, *, approve: int, sample: int, seed: int, root: Path = RAW_ROOT):
    m = load_manifest(root)
    plan, total = plan_calls(m, aave, sample=sample, seed=seed, root=root)
    caller = CachedCaller(rpc, root / "calls.sqlite", budget=approve)
    check_approval(approve, total, caller.spent)
    rows, excluded = [], []
    try:
        for wd in m["windows"]:
            w = Window(**wd)
            users = cohorts(w, aave, root, sample, seed)
            r, e = reconstruct_window(w, m, aave, caller, users, root)
            rows += r
            excluded += [{**x, "window_id": w.id} for x in e]
            print(f"  {w.id}: {len(r)} durations, {len(e)} excluded; calls spent {caller.spent}")
        rows_liq = [r for r in rows if r["event"] == 1 and r["onset_method"] != "same_block"]
        checks = []
        for r in random.Random(seed).sample(rows_liq, min(SPOT_CHECKS, len(rows_liq))):
            hf = decode_account(
                caller.user_call(
                    "getUserAccountData", SEL_ACCOUNT, aave.pool, r["user"], r["end_block"] - 1
                )
            )["hf"]
            checks.append(
                {
                    "user": r["user"],
                    "window_id": r["window_id"],
                    "onset_block": r["onset_block"],
                    "liquidation_block": r["end_block"],
                    "onset_precedes": r["onset_block"] < r["end_block"],
                    "hf_before_liquidation": str(hf),
                    "hf_below_one": hf < WAD,
                }
            )
    except BudgetExhausted as exc:
        print(
            f"stopped: {exc}. Everything so far is cached; approve more and re-run.",
            file=sys.stderr,
        )
        return 2
    (root / "durations.json").write_text(
        json.dumps(
            {
                "rows": rows,
                "excluded": excluded,
                "spot_checks": checks,
                "plan": plan,
                "calls_spent": caller.spent,
                "cache_hits": caller.hits,
            },
            indent=1,
        )
        + "\n"
    )
    passed = sum(c["hf_below_one"] and c["onset_precedes"] for c in checks)
    print(
        f"stage 2: {len(rows)} durations; spot checks {passed}"
        f"/{len(checks)} pass; calls spent {caller.spent} of {total}"
    )
    return 0


# ----------------------------------------------------------------------------- build
def build(aave: Aave, root: Path = RAW_ROOT) -> None:
    m = load_manifest(root)
    genesis = m["genesis_ts"]
    liq = [decode_liquidation(lg, aave) for lg in iter_logs(root / "liquidations")]
    events = pd.DataFrame(liq)
    events["block_timestamp"] = genesis + 2 * events["block_number"]
    PROCESSED_ROOT.mkdir(parents=True, exist_ok=True)
    events.to_parquet(PROCESSED_ROOT / "liquidations_base.parquet", index=False)

    d = json.loads((root / "durations.json").read_text())
    frame = pd.DataFrame(d["rows"])
    frame["onset_ts"] = genesis + 2 * frame["onset_block"]
    frame["end_ts"] = genesis + 2 * frame["end_block"]
    frame["event"] = frame["event"].astype("int8")
    frame.to_parquet(PROCESSED_ROOT / "liquidation_durations.parquet", index=False)
    (PROCESSED_ROOT / "liquidation_exclusions.json").write_text(
        json.dumps({"excluded": d["excluded"], "spot_checks": d["spot_checks"]}, indent=1) + "\n"
    )
    print(f"{len(events):,} liquidation events, {len(frame):,} durations written")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("stage", choices=["logs", "plan", "calls", "build"])
    ap.add_argument("--approve-calls", type=int)
    ap.add_argument("--sample", type=int, default=DEFAULT_SAMPLE)
    ap.add_argument("--seed", type=int, default=8453)
    ap.add_argument("--max-chunk", type=int, default=500_000)
    args = ap.parse_args(argv)
    aave = load_aave()

    if args.stage == "build":
        build(aave)
        return 0
    if args.stage == "plan":
        rows, total = plan_calls(load_manifest(), aave, sample=args.sample, seed=args.seed)
        for r in rows:
            print(json.dumps(r))
        print(
            f"stage 2 needs exactly {total} eth_calls on the planned path "
            f"(incl. {SPOT_CHECKS} spot checks). Approve with --approve-calls {total}."
        )
        return 0
    with Rpc.from_env() as rpc:
        if args.stage == "logs":
            stage_logs(rpc, aave, max_chunk=args.max_chunk)
            return 0
        if args.approve_calls is None:
            raise SystemExit(
                "stage 2 needs --approve-calls N, where N is the number `plan` printed"
            )
        return stage_calls(
            rpc, aave, approve=args.approve_calls, sample=args.sample, seed=args.seed
        )


if __name__ == "__main__":
    raise SystemExit(main())
