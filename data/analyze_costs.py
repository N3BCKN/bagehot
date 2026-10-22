"""`reports/cost-empirics.md` from the P09 datasets: selected blocks, Base costs, L1 crash prices.

Floats appear only here, in statistics (`CLAUDE.md`); the parquet files keep wei as integers.
"""

from __future__ import annotations

from datetime import UTC, datetime

import pandas as pd

from data.blocks import OUTPUT as BLOCKS
from data.fetch_costs import COSTS_BASE, COSTS_L1, L1_WINDOWS, REPORT, SAMPLE_EVERY
from data.sources import iso_utc

GWEI = 1e9
PAYLOADS = {
    "bagehot_a_liquidate": "Bagehot A `liquidate`",
    "bagehot_b_buy": "Bagehot B `buy`",
    "aave_liquidation_call": "Aave v3 `liquidationCall`",
}


def row(*cells) -> str:
    return "| " + " | ".join(str(c) for c in cells) + " |"


def selected_section(blocks: pd.DataFrame) -> list[str]:
    L = [
        "## 1. Selected blocks\n",
        f"{len(blocks)} blocks: "
        + ", ".join(f"{n} {k}" for k, n in blocks["kind"].value_counts().items())
        + ". Price context is the Coinbase ETH-USD minute close (P06).\n",
        row("kind", "rank", "time (UTC)", "block", "ETH-USD", "15-min", "24 h", "24 h vol (ann.)"),
        "|---|---|---|---|---|---|---|---|",
    ]
    for _, b in blocks.sort_values(["kind", "rank"]).iterrows():
        L.append(
            row(
                b["kind"],
                int(b["rank"]),
                b["iso"],
                f"{int(b['block_number']):,}",
                f"{b['close']:,.2f}",
                f"{b['ret_15m'] * 100:+.2f}%",
                f"{b['ret_24h'] * 100:+.2f}%" if pd.notna(b["ret_24h"]) else "—",
                f"{b['vol_24h'] * 100:.0f}%" if pd.notna(b["vol_24h"]) else "—",
            )
        )
    L.append("\nReasons, verbatim from `blocks_selected.parquet`:\n")
    for _, b in blocks.sort_values(["kind", "rank"]).iterrows():
        L.append(f"- **{b['kind']} {int(b['rank'])}** ({b['iso']}): {b['reason']}")
    return L + [""]


def base_section(costs: pd.DataFrame) -> list[str]:
    L = [
        "## 2. Base — L2 execution prices\n",
        "`eth_feeHistory` over the 30 blocks (one minute) ending at each selected block. Priority "
        "fees are gas-weighted percentiles as the node computes them.\n",
        row(
            "kind",
            "blocks",
            "base fee p50 (gwei)",
            "base fee max",
            "priority p50 (median)",
            "priority p90 (median)",
            "gas used ratio p50",
        ),
        "|---|---|---|---|---|---|---|",
    ]
    for kind, g in costs.groupby("kind", sort=True):
        L.append(
            row(
                kind,
                len(g),
                f"{g['base_fee_wei'].median() / GWEI:.6f}",
                f"{g['base_fee_wei'].max() / GWEI:.6f}",
                f"{g['priority_p50_wei'].median() / GWEI:.6f}",
                f"{g['priority_p90_wei'].median() / GWEI:.6f}",
                f"{g['gas_used_ratio'].median():.3f}",
            )
        )
    L.append("")

    sel = costs[costs["is_selected"]].copy()
    L.append("## 3. Base — L1 data fee of a liquidation transaction\n")
    sizes = ", ".join(
        f"{PAYLOADS[k]} {int(costs[c].iloc[0])} bytes"
        for k, c in (
            ("bagehot_a_liquidate", "payload_bytes_bagehot_a"),
            ("bagehot_b_buy", "payload_bytes_bagehot_b"),
            ("aave_liquidation_call", "payload_bytes_aave"),
        )
    )
    L.append(
        f"`GasPriceOracle.getL1Fee(bytes)` at each selected block for three signed EIP-1559 "
        f"envelopes ({sizes}). USD at that block's ETH-USD close.\n"
    )
    L.append(row("kind", *[f"{v} — median (max), USD" for v in PAYLOADS.values()]))
    L.append("|---|---|---|---|")
    for kind, g in sel.groupby("kind", sort=True):
        cells = []
        for k in PAYLOADS:
            usd = g[f"l1_fee_wei_{k}"].astype("float64") / 1e18 * g["eth_usd"]
            cells.append(f"{usd.median():.4f} ({usd.max():.4f})")
        L.append(row(kind, *cells))
    L.append("")
    return L


def l1_section(l1: pd.DataFrame) -> list[str]:
    L = [
        "## 4. Ethereum L1 — per-gas prices in the named stress windows\n",
        "Per-gas prices only. The gas our liquidation uses is measured at P20; the L1-regime cost "
        "is that gas × these prices, computed there. Before London (EIP-1559, August 2021) there "
        f"is no base fee: every {SAMPLE_EVERY}th block was read in full and the gas-weighted "
        "percentiles of the price paid are shown instead (weights: gas limit, receipts not "
        "read).\n",
        row(
            "window",
            "regime",
            "blocks covered",
            "first – last (UTC, exact bounds)",
            "p50 (gwei)",
            "p90 (gwei)",
            "max (gwei)",
        ),
        "|---|---|---|---|---|---|---|",
    ]
    for wid in L1_WINDOWS:
        g = l1[l1["window"] == wid]
        if g.empty:
            L.append(row(wid, "—", 0, "**missing**", "—", "—", "—"))
            continue
        regime = g["regime"].iloc[0]
        col = "base_fee_wei" if regime == "post_london" else "price_p50_wei"
        span = (
            f"{iso_utc(int(g['block_timestamp_approx'].iloc[0]))} – "
            f"{iso_utc(int(g['block_timestamp_approx'].iloc[-1]))}"
        )
        L.append(
            row(
                wid,
                regime.replace("_", " "),
                f"{len(g):,}",
                span,
                f"{g[col].median() / GWEI:.2f}",
                f"{g[col].quantile(0.9) / GWEI:.2f}",
                f"{g[col].max() / GWEI:.2f}",
            )
        )
    L.append(
        "\nPost-London rows report the base fee; the priority-fee percentiles are in the "
        "parquet (`priority_p*_wei`).\n"
    )
    return L


def write_report() -> None:
    blocks = pd.read_parquet(BLOCKS)
    costs = pd.read_parquet(COSTS_BASE)
    l1 = pd.read_parquet(COSTS_L1) if COSTS_L1.exists() else pd.DataFrame()
    L = [
        "# Cost empirics — Base L2 and Ethereum L1 under stress\n",
        f"Generated by `just costs report` on {datetime.now(tz=UTC).strftime('%Y-%m-%d')}. Kit "
        "correction 10: a Base transaction costs L2 execution plus an L1 data fee. Cards: "
        "`data/cards/blocks_selected.md`, `costs_base.md`, `costs_l1.md`.\n",
    ]
    L += selected_section(blocks)
    L += base_section(costs)
    L += l1_section(l1) if not l1.empty else ["## 4. Ethereum L1\n", "_Not fetched yet._\n"]
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(L) + "\n")
    print(f"wrote {REPORT}")
