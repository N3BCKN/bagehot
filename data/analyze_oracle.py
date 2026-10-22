"""Empirics of the Chainlink ETH/USD feed and the sequencer-uptime feed on Base.

Writes `reports/oracle-empirics.md`. Inputs: the two P07 parquet files and, for the
oracle-vs-market section, the P06 Coinbase minute candles.

Floats appear only here, in statistics (`CLAUDE.md`): the stored datasets keep exact integers.

    uv run python -m data.analyze_oracle
"""

from __future__ import annotations

import argparse
import tomllib
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pandas as pd

from data.fetch_oracle import CONFIG_PATH, load_manifest
from data.process_oracle import OUTPUTS, PROCESSED_ROOT
from data.sources import iso_utc

REPORT = Path("reports/oracle-empirics.md")
COINBASE = PROCESSED_ROOT / "prices_coinbase_1m.parquet"

# Stress windows from the P06 list that fall inside Base's history, plus drawdowns found below.
NAMED_WINDOWS = {"2024-08-05 yen-carry unwind": ("2024-08-05", "2024-08-06")}
DRAWDOWN_WINDOWS = 3  # largest Base-era 24-hour drops, detected from the Coinbase series

DT_BINS = [0, 10, 60, 300, 600, 1080, 1140, 1190, 1200, 1210, 1260, 1800, 3600, np.inf]
DEV_BINS_BPS = [0, 5, 10, 12.5, 14, 15, 16, 17.5, 20, 25, 50, 100, np.inf]


def day(text: str) -> int:
    return int(datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=UTC).timestamp())


def load_oracle(path: Path = PROCESSED_ROOT / OUTPUTS["eth_usd"]) -> pd.DataFrame:
    """The rounds actually visible through the proxy, in time order, with float prices for stats."""
    f = pd.read_parquet(path).sort_values(["updated_at", "phase", "log_index"], ignore_index=True)
    f["price"] = f["answer"].map(int).astype("float64") / 10.0 ** f["decimals"].astype("int64")
    f["dt"] = f["updated_at"].diff()
    f["rel_change"] = (f["price"] / f["price"].shift() - 1.0).abs()
    return f


def quantile_table(values: pd.Series, qs=(0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99), fmt="{:.0f}"):
    v = values.dropna()
    head = "| " + " | ".join(f"p{int(q * 100)}" for q in qs) + " | max | n |"
    sep = "|" + "---|" * (len(qs) + 2)
    row = (
        "| "
        + " | ".join(fmt.format(v.quantile(q)) for q in qs)
        + f" | {fmt.format(v.max())} | {len(v):,} |"
    )
    return "\n".join([head, sep, row])


def row(*cells) -> str:
    """One markdown table row."""
    return "| " + " | ".join(str(c) for c in cells) + " |"


def histogram_table(values: pd.Series, bins, label: str, unit: str) -> str:
    v = values.dropna()
    counts = pd.cut(v, bins=bins, right=False).value_counts(sort=False)
    lines = [f"| {label} ({unit}) | updates | share |", "|---|---|---|"]
    for interval, n in counts.items():
        lo, hi = interval.left, interval.right
        span = f"[{lo:g}, {hi:g})" if np.isfinite(hi) else f"≥ {lo:g}"
        lines.append(f"| {span} | {n:,} | {n / len(v) * 100:.2f}% |")
    return "\n".join(lines)


# ----------------------------------------------------------------------------- inference
def infer_heartbeat(f: pd.DataFrame, documented: int, threshold_pct: float) -> dict:
    """Heartbeat = where non-deviation updates pile up.

    Updates whose relative change is far below any plausible threshold (< 1/3 of the documented
    one) can only have been forced by the heartbeat. Their Δt mode, and the upper envelope of Δt
    over the whole series (outside sequencer outages), are the evidence.
    """
    quiet = f[(f["rel_change"] * 100 < threshold_pct / 3)]
    dt = quiet["dt"].dropna()
    mode = int(dt.round(-1).mode().iloc[0]) if len(dt) else None
    return {
        "quiet_updates": int(len(dt)),
        "quiet_dt_median": float(dt.median()) if len(dt) else float("nan"),
        "quiet_dt_mode_10s": mode,
        "share_quiet_within_60s_of_doc": float(((dt - documented).abs() <= 60).mean())
        if len(dt)
        else float("nan"),
        "dt_p99_all": float(f["dt"].quantile(0.99)),
    }


def infer_threshold(f: pd.DataFrame, heartbeat: float, threshold_pct: float) -> dict:
    """Threshold = the floor under |Δ|/price for updates that came *before* the heartbeat.

    An update that arrives well before the heartbeat must have been triggered by deviation, so the
    low quantiles of its |Δ|/price sit at the threshold. A few fall below it: the trigger compares
    the network's median observation with the on-chain answer, and the price can retrace between
    the trigger and the transmitted median. Those are counted, not hidden.
    """
    early = f[f["dt"] < 0.9 * heartbeat]
    rel_bps = early["rel_change"].dropna() * 10_000
    return {
        "deviation_updates": int(len(rel_bps)),
        "p1_bps": float(rel_bps.quantile(0.01)),
        "p5_bps": float(rel_bps.quantile(0.05)),
        "p10_bps": float(rel_bps.quantile(0.10)),
        "median_bps": float(rel_bps.median()),
        "share_below_doc": float((rel_bps < threshold_pct * 100).mean()),
        "rel_bps": rel_bps,
    }


# ----------------------------------------------------------------------------- market comparison
def market_minutes(path: Path = COINBASE) -> pd.Series | None:
    if not path.exists():
        return None
    m = pd.read_parquet(path, columns=["ts", "close"])
    return pd.Series(m["close"].to_numpy(), index=m["ts"].to_numpy())


def oracle_vs_market(f: pd.DataFrame, market: pd.Series) -> dict:
    """Two views of the gap the protocol lives in.

    At each update: how far the *previous* on-chain answer was from the market in the minute
    before the update (the staleness the protocol was acting on), and how far the new answer is.
    Over time: for every market minute, the gap between the answer then in force and the market
    close, which weights the gap by how long the protocol saw it.
    """
    # Market close of the last complete minute before each update.
    minute = (f["updated_at"] // 60) * 60 - 60
    mk = market.reindex(minute.to_numpy()).to_numpy()
    prev_answer = f["price"].shift().to_numpy()
    before = np.abs(prev_answer / mk - 1.0) * 10_000
    after = np.abs(f["price"].to_numpy() / mk - 1.0) * 10_000

    # Answer in force at each market minute (the latest update at or before that minute's close).
    lo, hi = int(f["updated_at"].iloc[0]), int(f["updated_at"].iloc[-1])
    mm = market[(market.index >= lo) & (market.index <= hi)]
    close_time = mm.index.to_numpy() + 60
    idx = np.searchsorted(f["updated_at"].to_numpy(), close_time, side="right") - 1
    in_force = f["price"].to_numpy()[idx]
    gap = np.abs(in_force / mm.to_numpy() - 1.0) * 10_000
    return {
        "before_bps": pd.Series(before),
        "after_bps": pd.Series(after),
        "gap_bps": pd.Series(gap),
        "gap_ts": pd.Series(mm.index.to_numpy()),
    }


def drawdown_windows(
    market: pd.Series, start: int, k: int = DRAWDOWN_WINDOWS
) -> dict[str, tuple[int, int]]:
    """The k largest non-overlapping 24-hour drops after `start`, from 5-minute closes."""
    m = market[market.index >= start]
    if m.empty:
        return {}
    five = m.groupby((m.index // 300) * 300).last()
    s = pd.Series(five.to_numpy(), index=pd.to_datetime(five.index, unit="s", utc=True))
    s = s.resample("5min").last().ffill()  # analysis-only fill, never stored (P06 rule)
    change = s / s.shift(288) - 1.0  # 288 five-minute steps = 24 h
    out: dict[str, tuple[int, int]] = {}
    taken: list[pd.Timestamp] = []
    for t, v in change.sort_values().items():
        if len(out) == k or not np.isfinite(v):
            break
        if any(abs((t - u).total_seconds()) < 3 * 86400 for u in taken):
            continue
        taken.append(t)
        end = int(t.timestamp())
        out[f"{(t - pd.Timedelta(hours=24)).strftime('%Y-%m-%d')} 24h drop {v * 100:.1f}%"] = (
            end - 86400,
            end,
        )
    return out


# ----------------------------------------------------------------------------- sequencer
def downtime_episodes(seq: pd.DataFrame) -> pd.DataFrame:
    s = seq.sort_values(["started_at", "phase", "aggregator_round_id"], key=None, ignore_index=True)
    s = s[s["in_phase"]]
    rows = []
    for i, r in s.iterrows():
        if r["answer"] == "1":
            nxt = s[(s.index > i) & (s["answer"] == "0")]
            end = int(nxt["started_at"].iloc[0]) if len(nxt) else None
            rows.append(
                {
                    "down_from": int(r["started_at"]),
                    "up_again": end,
                    "duration_s": (end - int(r["started_at"])) if end else None,
                    "reported_in_block": int(r["block_number"]),
                }
            )
    return pd.DataFrame(rows)


# ----------------------------------------------------------------------------- report
def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    cfg = tomllib.loads(CONFIG_PATH.read_text())["oracle"]
    doc_thr = float(cfg["eth_usd"]["deviation_threshold_pct"])
    doc_hb = int(cfg["eth_usd"]["heartbeat_s"])

    f = load_oracle()
    seq = pd.read_parquet(PROCESSED_ROOT / OUTPUTS["sequencer_uptime"])
    man = load_manifest("eth_usd")
    sman = load_manifest("sequencer_uptime")
    market = market_minutes()

    hb = infer_heartbeat(f, doc_hb, doc_thr)
    hb_est = hb["quiet_dt_mode_10s"] or doc_hb
    th = infer_threshold(f, hb_est, doc_thr)
    lag = f["block_timestamp"] - f["updated_at"]

    L: list[str] = []
    L.append("# Oracle empirics — Chainlink ETH/USD and sequencer uptime on Base\n")
    L.append(
        f"Generated by `uv run python -m data.analyze_oracle` on "
        f"{datetime.now(tz=UTC).strftime('%Y-%m-%d')} from the P07 datasets "
        "(`data/cards/oracle_ethusd_base.md`, `data/cards/sequencer_base.md`). "
        "Prices are the feed's raw 8-decimal answers converted to float for statistics only.\n"
    )

    L.append("## 1. What was measured\n")
    L.append("| item | value |\n|---|---|")
    L.append(f"| proxy | `{man.proxy}` ({man.description}, {man.decimals} decimals) |")
    L.append(
        f"| phases | {len(man.phases)} — "
        + ", ".join(
            f"{p['phase']}: `{p['aggregator']}` blocks {p['start_block']:,}–{p['end_block']:,}"
            for p in man.phases
        )
        + " |"
    )
    pre_phase = int((~f["in_phase"]).sum())
    first, last = iso_utc(int(f["updated_at"].iloc[0])), iso_utc(int(f["updated_at"].iloc[-1]))
    v = man.verification
    L.append(row("rounds", f"{len(f):,} ({pre_phase} pre-phase rounds visible at a phase start)"))
    L.append(row("first / last update", f"{first} / {last}"))
    L.append(
        row(
            "getRoundData cross-check",
            f"{v['checked']} rounds re-read through the proxy, {len(v['mismatches'])} mismatches",
        )
    )
    L.append(
        row(
            "block timestamps",
            f"genesis {v['genesis_timestamp']} + 2·n; {v['timestamp_samples']} headers "
            f"checked, {len(v['timestamp_mismatches'])} mismatches",
        )
    )
    L.append(
        row(
            "documented parameters",
            f"deviation {doc_thr}%, heartbeat {doc_hb} s (`config/8453.toml`)",
        )
        + "\n"
    )

    L.append("## 2. Inferred heartbeat and deviation threshold\n")
    L.append("| parameter | documented | inferred | evidence |\n|---|---|---|---|")
    hb_evidence = (
        f"mode (10 s bins) of Δt over the {hb['quiet_updates']:,} updates whose \\|Δ\\|/price is "
        "below a third of the documented threshold — updates nothing but the heartbeat can "
        f"explain; median {hb['quiet_dt_median']:.0f} s; "
        f"{hb['share_quiet_within_60s_of_doc'] * 100:.1f}% of them within 60 s of {doc_hb} s"
    )
    th_evidence = (
        f"\\|Δ\\|/price of the {th['deviation_updates']:,} updates that came before 0.9 × "
        f"heartbeat: p1 {th['p1_bps']:.2f}, p5 {th['p5_bps']:.2f}, p10 {th['p10_bps']:.2f}, "
        f"median {th['median_bps']:.2f} bps; {th['share_below_doc'] * 100:.2f}% fall below "
        "the documented value"
    )
    L.append(row("heartbeat", f"{doc_hb} s", f"**{hb_est} s**", hb_evidence))
    L.append(
        row(
            "deviation threshold",
            f"{doc_thr}% ({doc_thr * 100:.0f} bps)",
            f"**≈ {th['p5_bps']:.1f} bps (p5)**",
            th_evidence,
        )
        + "\n"
    )
    L.append(
        "Updates just below the threshold are expected and are not errors: the network triggers on "
        "the deviation of its median observation from the on-chain answer, then transmits a new "
        "median, and the market can retrace in between.\n"
    )
    L.append("### |Δ|/price of early (deviation-triggered) updates\n")
    L.append(histogram_table(th["rel_bps"], DEV_BINS_BPS, "\\|Δ\\|/price", "bps") + "\n")

    L.append("## 3. Inter-update times\n")
    L.append(quantile_table(f["dt"]) + "\n")
    L.append(histogram_table(f["dt"], DT_BINS, "Δt", "s") + "\n")
    L.append("### |Δ|/price at every update (bps)\n")
    L.append(quantile_table(f["rel_change"] * 10_000, fmt="{:.2f}") + "\n")

    L.append("## 4. Update time against block time\n")
    within = (lag.abs() <= 1).mean() * 100
    equal = (lag == 0).mean() * 100
    L.append(
        f"`block_timestamp − updated_at` over all rounds: {within:.2f}% within 1 s, "
        f"{equal:.2f}% exactly equal, max {int(lag.max())} s, min {int(lag.min())} s.\n"
    )
    L.append(quantile_table(lag.astype("float64")) + "\n")

    windows = dict(NAMED_WINDOWS)
    if market is not None:
        windows.update(drawdown_windows(market, int(f["updated_at"].iloc[0])))
    L.append("## 5. Stress windows\n")
    L.append(row("window", "updates", "max Δt (s)", "max \\|Δ\\|/price (bps)", "median Δt (s)"))
    L.append("|---|---|---|---|---|")
    for label, (a, b) in windows.items():
        a, b = (day(a), day(b)) if isinstance(a, str) else (a, b)
        w = f[(f["updated_at"] >= a) & (f["updated_at"] < b)]
        if w.empty:
            L.append(f"| {label} | 0 | — | — | — |")
            continue
        L.append(
            row(
                label,
                f"{len(w):,}",
                int(w["dt"].max()),
                f"{w['rel_change'].max() * 10_000:.1f}",
                f"{w['dt'].median():.0f}",
            )
        )
    L.append("")

    L.append("## 6. Oracle against the market (Coinbase ETH-USD, P06)\n")
    if market is None:
        L.append("_P06 Coinbase dataset not found: section skipped._\n")
    else:
        vm = oracle_vs_market(f, market)
        L.append(
            "At each update: deviation of the previous on-chain answer (what the protocol was "
            "acting on) and of the new answer from the market close of the minute before.\n"
        )
        L.append("**Previous answer vs market, just before an update (bps)**\n")
        L.append(quantile_table(vm["before_bps"], fmt="{:.2f}") + "\n")
        L.append("**New answer vs market (bps)**\n")
        L.append(quantile_table(vm["after_bps"], fmt="{:.2f}") + "\n")
        L.append(
            "**Time-weighted gap** — for every market minute, the answer in force against the "
            "market close (bps). This is the gap of blueprint ch. 10, weighted by how long the "
            "protocol saw it.\n"
        )
        L.append(quantile_table(vm["gap_bps"], fmt="{:.2f}") + "\n")
        L.append(
            "| window | minutes | median gap | p99 gap | max gap (bps) |\n|---|---|---|---|---|"
        )
        for label, (a, b) in windows.items():
            a, b = (day(a), day(b)) if isinstance(a, str) else (a, b)
            sel = (vm["gap_ts"] >= a) & (vm["gap_ts"] < b)
            g = vm["gap_bps"][sel.to_numpy()]
            if g.empty:
                L.append(f"| {label} | 0 | — | — | — |")
                continue
            L.append(
                row(
                    label,
                    f"{len(g):,}",
                    f"{g.median():.2f}",
                    f"{g.quantile(0.99):.2f}",
                    f"{g.max():.2f}",
                )
            )
        L.append("")

    L.append("## 7. Sequencer downtime episodes\n")
    eps = downtime_episodes(seq)
    L.append(
        f"Sequencer-uptime proxy `{sman.proxy}`: {len(seq):,} status rounds "
        f"({iso_utc(int(seq['started_at'].min()))} – {iso_utc(int(seq['started_at'].max()))}).\n"
    )
    if eps.empty:
        L.append("_No downtime recorded._\n")
    else:
        L.append(
            "| down from (UTC) | up again (UTC) | duration | reported in block |\n|---|---|---|---|"
        )
        for _, e in eps.iterrows():
            up = iso_utc(int(e["up_again"])) if pd.notna(e["up_again"]) else "still down at head"
            dur = f"{int(e['duration_s']):,} s" if pd.notna(e["duration_s"]) else "—"
            L.append(row(iso_utc(int(e["down_from"])), up, dur, f"{int(e['reported_in_block']):,}"))
        L.append("")

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(L) + "\n")
    print(f"wrote {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
