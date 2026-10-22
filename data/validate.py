"""Validate the processed datasets and write `reports/data-validation.md`.

Prices (P06): monotonicity, duplicates, gaps with durations, outlier flags, cross-source
divergence overall and inside the named stress windows, and a check that each data card's
checksum still matches the file it describes.

Outliers and divergences are **flagged, never removed**: a 40% minute in March 2020 is the data,
not an error, and the decision about what to do with it belongs to the analysis, not the loader.

    uv run python -m data.validate
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pandas as pd

from data.process_prices import CARD_ROOT, processed_path
from data.sources import DEFAULT_SOURCES, MINUTE, SOURCES, Source, iso_utc

REPORT_PATH = Path("reports/data-validation.md")

# Windows the prompt names: the dates where a quote-currency or feed problem would show up most.
STRESS_WINDOWS: dict[str, tuple[str, str]] = {
    "2020-03-12/13 covid crash": ("2020-03-12", "2020-03-14"),
    "2021-05-19 deleveraging": ("2021-05-19", "2021-05-20"),
    "2022-05-09..12 UST collapse": ("2022-05-09", "2022-05-13"),
    "2024-08-05 yen-carry unwind": ("2024-08-05", "2024-08-06"),
}

OUTLIER_K = 8.0  # |1-min log return| > K * rolling MAD
OUTLIER_WINDOW = 1440  # one day of minutes
GAP_REPORT_LIMIT = 25  # longest gaps listed per source; the rest are summarised


def day(text: str) -> int:
    return int(datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=UTC).timestamp())


@dataclass
class Gap:
    start: int  # last candle before the gap (open time)
    end: int  # first candle after the gap (open time)

    @property
    def minutes(self) -> int:
        return (self.end - self.start) // MINUTE - 1


def load(source: Source) -> pd.DataFrame:
    path = processed_path(source)
    if not path.exists():
        raise SystemExit(f"{path} missing — run data.process_prices first")
    return pd.read_parquet(path)


def find_gaps(ts: pd.Series) -> list[Gap]:
    diffs = ts.diff()
    idx = np.flatnonzero((diffs > MINUTE).to_numpy())
    return [Gap(int(ts.iloc[i - 1]), int(ts.iloc[i])) for i in idx]


def flag_outliers(frame: pd.DataFrame, k: float = OUTLIER_K, window: int = OUTLIER_WINDOW):
    """Flag minutes whose log return exceeds k rolling MADs. Contiguous minutes only."""
    close = frame["close"].to_numpy()
    ret = np.full(len(frame), np.nan)
    contiguous = frame["ts"].diff().to_numpy() == MINUTE
    with np.errstate(divide="ignore", invalid="ignore"):
        ret[1:] = np.where(contiguous[1:], np.log(close[1:] / close[:-1]), np.nan)
    series = pd.Series(ret, index=frame.index)
    med = series.rolling(window, min_periods=window // 4).median()
    mad = (series - med).abs().rolling(window, min_periods=window // 4).median()
    threshold = k * mad
    flagged = series.abs() > threshold.replace(0.0, np.nan)
    return series, flagged.fillna(False)


def divergence(a: pd.DataFrame, b: pd.DataFrame) -> dict:
    """Relative close-price difference on the minutes both sources have."""
    merged = a[["ts", "close"]].merge(b[["ts", "close"]], on="ts", suffixes=("_a", "_b"))
    if merged.empty:
        return {"minutes": 0}
    rel = ((merged["close_a"] - merged["close_b"]).abs() / merged["close_b"]).to_numpy()
    worst = int(np.argmax(rel))
    return {
        "minutes": int(len(merged)),
        "median_bps": float(np.median(rel) * 10_000),
        "p95_bps": float(np.quantile(rel, 0.95) * 10_000),
        "max_bps": float(rel[worst] * 10_000),
        "max_at": iso_utc(int(merged["ts"].iloc[worst])),
    }


def slice_window(frame: pd.DataFrame, start: str, end: str) -> pd.DataFrame:
    return frame[(frame["ts"] >= day(start)) & (frame["ts"] < day(end))]


def card_checksum_ok(source: Source) -> tuple[bool, str]:
    path = CARD_ROOT / f"prices_{source.name}.md"
    if not path.exists():
        return False, "card missing"
    match = re.search(r"\| sha256 \| `([0-9a-f]{64})` \|", path.read_text())
    if not match:
        return False, "no checksum in card"
    actual = hashlib.sha256(processed_path(source).read_bytes()).hexdigest()
    return (match.group(1) == actual), f"card {match.group(1)[:12]}… file {actual[:12]}…"


def report_prices(sources: list[Source], stream=None) -> tuple[str, bool]:
    stream = stream or sys.stdout
    frames = {s.name: load(s) for s in sources}
    lines: list[str] = []
    ok = True

    lines.append("## Prices — one-minute candles (P06)\n")
    header = (
        "| source | quote | rows | first (UTC) | last (UTC) | coverage | monotonic "
        "| duplicate ts | gaps | missing minutes |"
    )
    lines.append(header)
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    gaps_by_source: dict[str, list[Gap]] = {}
    outliers_by_source: dict[str, pd.DataFrame] = {}

    for s in sources:
        f = frames[s.name]
        ts = f["ts"]
        monotonic = bool(ts.is_monotonic_increasing)
        dupes = int(ts.duplicated().sum())
        gaps = find_gaps(ts)
        gaps_by_source[s.name] = gaps
        missing = sum(g.minutes for g in gaps)
        expected = (int(ts.iloc[-1]) - int(ts.iloc[0])) // MINUTE + 1
        ok &= monotonic and dupes == 0
        lines.append(
            f"| {s.name} | {s.quote} | {len(f):,} | {iso_utc(int(ts.iloc[0]))} | "
            f"{iso_utc(int(ts.iloc[-1]))} | {len(f) / expected * 100:.4f}% | "
            f"{'yes' if monotonic else '**NO**'} | {dupes} | {len(gaps):,} | {missing:,} |"
        )

        returns, flagged = flag_outliers(f)
        outliers_by_source[s.name] = pd.DataFrame(
            {"ts": f["ts"][flagged], "log_return": returns[flagged]}
        )

    lines.append(
        "\nCoverage is rows divided by the minutes between the first and last candle. "
        "Gaps are minutes the venue did not return; they are preserved as absences and "
        "never filled.\n"
    )

    lines.append("### Gaps\n")
    for s in sources:
        gaps = sorted(gaps_by_source[s.name], key=lambda g: g.minutes, reverse=True)
        lines.append(
            f"**{s.name}** — {len(gaps):,} gaps, "
            f"{sum(g.minutes for g in gaps):,} minutes missing in total.\n"
        )
        if gaps:
            lines.append("| from (last candle) | to (next candle) | missing minutes |")
            lines.append("|---|---|---|")
            for g in gaps[:GAP_REPORT_LIMIT]:
                lines.append(f"| {iso_utc(g.start)} | {iso_utc(g.end)} | {g.minutes:,} |")
            if len(gaps) > GAP_REPORT_LIMIT:
                rest = gaps[GAP_REPORT_LIMIT:]
                lines.append(
                    f"| … {len(rest):,} shorter gaps | | {sum(g.minutes for g in rest):,} |"
                )
        lines.append("")

    lines.append("### Outlier flags\n")
    lines.append(
        f"Flag rule: `|1-minute log return| > {OUTLIER_K} x rolling MAD` over "
        f"{OUTLIER_WINDOW} minutes, computed only across contiguous minutes. Flagged, "
        "never dropped.\n"
    )
    lines.append("| source | flagged minutes | share | largest flagged move | at (UTC) |")
    lines.append("|---|---|---|---|---|")
    for s in sources:
        o = outliers_by_source[s.name]
        if o.empty:
            lines.append(f"| {s.name} | 0 | 0.0000% | — | — |")
            continue
        worst = o.iloc[o["log_return"].abs().to_numpy().argmax()]
        lines.append(
            f"| {s.name} | {len(o):,} | {len(o) / len(frames[s.name]) * 100:.4f}% | "
            f"{float(worst['log_return']) * 100:+.2f}% | {iso_utc(int(worst['ts']))} |"
        )

    lines.append("\n### Cross-source divergence\n")
    usd = [s for s in sources if s.quote == "USD"]
    others = [s for s in sources if s.quote != "USD"]
    if others:
        lines.append(
            "Only sources with the same quote currency are compared. "
            f"Excluded from the comparison: {', '.join(f'{s.name} ({s.quote})' for s in others)}.\n"
        )
    if len(usd) < 2:
        lines.append("_Fewer than two USD-quoted sources: nothing to compare._\n")
    else:
        a, b = usd[0], usd[1]
        lines.append(
            f"`{a.name}` against `{b.name}`, relative difference of closes in basis points.\n"
        )
        lines.append("| window | common minutes | median | p95 | max | max at (UTC) |")
        lines.append("|---|---|---|---|---|---|")
        rows = [("whole range", frames[a.name], frames[b.name])]
        for label, (start, end) in STRESS_WINDOWS.items():
            rows.append(
                (
                    label,
                    slice_window(frames[a.name], start, end),
                    slice_window(frames[b.name], start, end),
                )
            )
        for label, fa, fb in rows:
            d = divergence(fa, fb)
            if not d["minutes"]:
                lines.append(f"| {label} | 0 | — | — | — | — |")
                continue
            lines.append(
                f"| {label} | {d['minutes']:,} | {d['median_bps']:.2f} | {d['p95_bps']:.2f} | "
                f"{d['max_bps']:.2f} | {d['max_at']} |"
            )

    lines.append("\n### Data-card checksums\n")
    lines.append("| source | card | state |")
    lines.append("|---|---|---|")
    for s in sources:
        good, detail = card_checksum_ok(s)
        ok &= good
        lines.append(
            f"| {s.name} | `data/cards/prices_{s.name}.md` | "
            f"{'match' if good else '**MISMATCH**'} ({detail}) |"
        )

    return "\n".join(lines) + "\n", ok


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--source", action="append", choices=sorted(SOURCES), help="repeatable")
    args = ap.parse_args(argv)
    sources = [SOURCES[n] for n in (args.source or DEFAULT_SOURCES)]

    body, ok = report_prices(sources)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    header = (
        "# Data validation\n\n"
        f"Generated by `uv run python -m data.validate` on "
        f"{datetime.now(tz=UTC).strftime('%Y-%m-%d %H:%M')} UTC. "
        "Checks are described in `.claude/skills/data-pipeline/SKILL.md`; anomalies are flagged, "
        "never silently repaired.\n\n"
    )
    REPORT_PATH.write_text(header + body)
    print(f"wrote {REPORT_PATH}")
    if not ok:
        print("validation found a hard problem (see the report)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
