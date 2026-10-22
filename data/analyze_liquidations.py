"""Liquidation latency on Base as a right-censored duration: Kaplan–Meier versus the naive view.

Writes `reports/liquidation-empirics.md` from `data/processed/liquidation_durations.parquet`.

Latency is the time from onset (the first oracle update after which the position's health factor
was below 1) to the liquidation. A position that recovered, or that was still unliquidated when
the window closed, is censored: we know its latency exceeded what we saw, not what it was.
Dropping those positions — the naive "observed liquidations only" view — keeps exactly the fast
cases and understates latency. The report shows both so the difference is a number (ADR-0025).

    uv run python -m data.analyze_liquidations
"""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pandas as pd

PROCESSED = Path("data/processed")
REPORT = Path("reports/liquidation-empirics.md")
Z95 = 1.959963984540054
CHECKPOINTS = [0, 2, 30, 60, 300, 900, 3600, 6 * 3600]  # seconds
SIZE_BUCKETS = [
    (0, 10_000, "< $10k"),
    (10_000, 100_000, "$10k–$100k"),
    (100_000, np.inf, "≥ $100k"),
]
BASE_DECIMALS = 8  # Aave v3 base currency: USD with 8 decimals


def kaplan_meier(durations, events) -> pd.DataFrame:
    """Product-limit estimator with Greenwood variance and log-log 95% intervals.

    One row per distinct event time: time, at risk, events, censored at that time, S(t), and the
    interval. Censored observations at a tie with an event count as at risk for that event (the
    usual convention: censoring happens just after).
    """
    t = np.asarray(durations, dtype="float64")
    e = np.asarray(events, dtype="int64")
    if t.size == 0:
        return pd.DataFrame(
            columns=["time", "at_risk", "events", "censored", "survival", "lo", "hi"]
        )
    order = np.argsort(t, kind="mergesort")
    t, e = t[order], e[order]
    times = np.unique(t)
    rows, survival, greenwood = [], 1.0, 0.0
    n = t.size
    for u in times:
        at_u = t == u
        d = int(e[at_u].sum())
        c = int(at_u.sum()) - d
        if d:
            survival *= 1.0 - d / n
            if n > d:
                greenwood += d / (n * (n - d))
        if d:
            if 0.0 < survival < 1.0:
                se_ll = np.sqrt(greenwood) / abs(np.log(survival))
                lo = survival ** np.exp(Z95 * se_ll)
                hi = survival ** np.exp(-Z95 * se_ll)
            else:
                lo = hi = survival
            rows.append((u, n, d, c, survival, lo, hi))
        n -= d + c
    return pd.DataFrame(
        rows, columns=["time", "at_risk", "events", "censored", "survival", "lo", "hi"]
    )


def survival_at(km: pd.DataFrame, t: float) -> tuple[float, float, float]:
    """S(t) and its interval: the last step at or before t (1.0 before the first event)."""
    past = km[km["time"] <= t]
    if past.empty:
        return 1.0, 1.0, 1.0
    last = past.iloc[-1]
    return float(last["survival"]), float(last["lo"]), float(last["hi"])


def median_time(km: pd.DataFrame) -> float | None:
    below = km[km["survival"] <= 0.5]
    return float(below["time"].iloc[0]) if len(below) else None


def rmst(km: pd.DataFrame, horizon: float) -> float:
    """Restricted mean time to liquidation up to `horizon`: the area under S(t) on [0, horizon]."""
    area, prev_t, prev_s = 0.0, 0.0, 1.0
    for _, r in km.iterrows():
        if r["time"] >= horizon:
            break
        area += prev_s * (r["time"] - prev_t)
        prev_t, prev_s = r["time"], r["survival"]
    return area + prev_s * (horizon - prev_t)


def latencies(frame: pd.DataFrame) -> pd.DataFrame:
    f = frame.copy()
    f["latency"] = (f["end_ts"] - f["onset_ts"]).astype("float64")
    f["debt_usd"] = f["debt_base_at_onset"].map(int).astype("float64") / 10**BASE_DECIMALS
    return f


def fmt_t(seconds: float | None) -> str:
    if seconds is None or not np.isfinite(seconds):
        return "not reached"
    if seconds < 120:
        return f"{seconds:.0f} s"
    if seconds < 7200:
        return f"{seconds / 60:.1f} min"
    return f"{seconds / 3600:.1f} h"


def km_table(f: pd.DataFrame) -> list[str]:
    km = kaplan_meier(f["latency"], f["event"])
    lines = ["| t | still unliquidated S(t) | 95% interval |", "|---|---|---|"]
    for t in CHECKPOINTS:
        s, lo, hi = survival_at(km, t)
        lines.append(f"| {fmt_t(t)} | {s:.3f} | [{lo:.3f}, {hi:.3f}] |")
    return lines


def summary_row(label: str, f: pd.DataFrame, horizon: float) -> str:
    km = kaplan_meier(f["latency"], f["event"])
    observed = f[f["event"] == 1]["latency"]
    naive_med = fmt_t(float(observed.median())) if len(observed) else "—"
    naive_mean = fmt_t(float(observed.mean())) if len(observed) else "—"
    censored = (f["event"] == 0).mean() * 100 if len(f) else 0.0
    tail = float(km["survival"].iloc[-1]) * 100 if len(km) else 100.0
    return (
        f"| {label} | {len(f):,} | {int(f['event'].sum()):,} | {censored:.1f}% | "
        f"{naive_med} | {naive_mean} | {fmt_t(median_time(km))} | {fmt_t(rmst(km, horizon))} | "
        f"{tail:.1f}% |"
    )


def main(argv: list[str] | None = None) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    frame = latencies(pd.read_parquet(PROCESSED / "liquidation_durations.parquet"))
    extra = json.loads((PROCESSED / "liquidation_exclusions.json").read_text())
    excluded = pd.DataFrame(extra["excluded"])
    checks = extra["spot_checks"]
    horizon = float(frame["latency"].max()) if len(frame) else 0.0

    L = ["# Liquidation latency on Base — Aave v3, WETH collateral, stablecoin debt\n"]
    L.append(
        f"Generated by `uv run python -m data.analyze_liquidations` on "
        f"{datetime.now(tz=UTC).strftime('%Y-%m-%d')} from `liquidation_durations.parquet` "
        "(card: `data/cards/liquidations_base.md`).\n"
    )
    L.append(
        "**Approximation.** Health factor comes from Aave's own `getUserAccountData`, but only "
        "for users whose sole collateral is WETH and whose debt is USDC and/or USDbC, outside "
        "eMode. Everyone else is excluded and counted below. Onset is the first *falling* oracle "
        "update of the source Aave used in the window after which HF < 1, read at end of block; "
        "a liquidation in the same block as the update that enabled it has latency 0 by "
        "construction (`onset_method = same_block`).\n"
    )

    L.append("## 1. Positions\n")
    L.append("| window | liquidated | sampled | with onset | events | censored |")
    L.append("|---|---|---|---|---|---|")
    for wid, g in frame.groupby("window_id", sort=True):
        L.append(
            f"| {wid} | {int((g['cohort'] == 'liquidated').sum())} | "
            f"{int((g['cohort'] == 'sampled').sum())} | {len(g)} | {int(g['event'].sum())} | "
            f"{int((g['event'] == 0).sum())} |"
        )
    L.append("")
    if not excluded.empty:
        L.append("**Excluded or without onset**, by reason (never silently dropped):\n")
        L.append("| reason | liquidated cohort | sampled cohort |\n|---|---|---|")
        for reason, g in excluded.groupby("reason", sort=True):
            L.append(
                f"| {reason} | {int((g['cohort'] == 'liquidated').sum())} | "
                f"{int((g['cohort'] == 'sampled').sum())} |"
            )
        L.append("")
    same = int((frame["onset_method"] == "same_block").sum())
    L.append(
        f"Same-block liquidations (update and liquidation in one block): {same} of "
        f"{int(frame['event'].sum())} events.\n"
    )

    L.append("## 2. Spot checks (acceptance)\n")
    L.append(
        "Ten liquidated users with onset before the liquidation block: onset must precede the "
        "liquidation, and HF at the liquidation block − 1 must be below 1.\n"
    )
    L.append(
        "| user | window | onset block | liquidation block | onset precedes "
        "| HF at block − 1 | HF < 1 |"
    )
    L.append("|---|---|---|---|---|---|---|")
    for c in checks:
        precedes = "yes" if c["onset_precedes"] else "**NO**"
        below = "yes" if c["hf_below_one"] else "**NO**"
        hf = int(c["hf_before_liquidation"]) / 1e18
        L.append(
            f"| `{c['user']}` | {c['window_id']} | {c['onset_block']:,} | "
            f"{c['liquidation_block']:,} | {precedes} | {hf:.4f} | {below} |"
        )
    L.append("")

    L.append("## 3. Kaplan–Meier — all positions with onset\n")
    L += km_table(frame)
    L.append("")

    L.append("## 4. Naive versus censoring-aware\n")
    L.append(
        f'"Naive" uses observed liquidations only. KM uses every position with an onset, '
        f"censored ones included. RMST is the restricted mean up to {fmt_t(horizon)}, the "
        "longest follow-up observed. The last column is the share still unliquidated at the "
        "end of follow-up.\n"
    )
    L.append(
        "| group | positions | events | censored | naive median | naive mean | KM median | "
        "KM RMST | never liquidated |"
    )
    L.append("|---|---|---|---|---|---|---|---|---|")
    L.append(summary_row("all", frame, horizon))
    for lo, hi, label in SIZE_BUCKETS:
        g = frame[(frame["debt_usd"] >= lo) & (frame["debt_usd"] < hi)]
        if len(g):
            L.append(summary_row(f"debt {label}", g, horizon))
    L.append("")

    L.append("## 5. Kaplan–Meier by position size (debt at onset)\n")
    for lo, hi, label in SIZE_BUCKETS:
        g = frame[(frame["debt_usd"] >= lo) & (frame["debt_usd"] < hi)]
        if len(g):
            L.append(f"### Debt {label} — {len(g):,} positions\n")
            L += km_table(g)
            L.append("")

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(L) + "\n")
    print(f"wrote {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
