"""Transaction costs in the two regimes the report needs: Base L2, and Ethereum L1 in a crash (P09).

    just costs base      # needs BASE_ARCHIVE_RPC and data/processed/blocks_selected.parquet
    just costs l1        # needs ETH_MAINNET_RPC
    just costs report    # reports/cost-empirics.md from the two parquet files

Base (kit correction 10: cost = L2 execution + L1 data fee):
  * L2 execution: `eth_feeHistory` over FEE_WINDOW blocks ending at each selected block — base fee
    and gas-weighted priority-fee percentiles, one row per block.
  * L1 data fee: the OP Stack GasPriceOracle predeploy's `getL1Fee(bytes)` at that block (archive
    eth_call), for three representative signed liquidation transactions: Bagehot A
    `liquidate(uint256)`, Bagehot B `buy(...)`, and Aave v3 `liquidationCall(...)` as a reference.
    The transactions are RLP-encoded EIP-1559 envelopes with deterministic pseudo-random signature
    bytes: the oracle prices the compressed size, and real signatures are incompressible noise.

Ethereum L1, in the named stress windows: per-gas prices only. The gas our own liquidation uses is
measured at P20; total cost = price × that gas is computed there, not guessed here.
  * After London (EIP-1559): `eth_feeHistory` — base fee and priority percentiles.
  * Before London (2020-03, 2021-05): there is no base fee. Every SAMPLE_EVERY-th block is read
    with its transactions and the gas-weighted percentiles of the gas price paid are computed.
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path

import pandas as pd
from eth_abi import decode, encode
from eth_utils import function_signature_to_4byte_selector

from data.analyze_oracle import day
from data.blocks import CACHE, BlockClock
from data.blocks import OUTPUT as BLOCKS
from data.rpc import Rpc, RpcError

PROCESSED = Path("data/processed")
COSTS_BASE = PROCESSED / "costs_base.parquet"
COSTS_L1 = PROCESSED / "costs_l1.parquet"
REPORT = Path("reports/cost-empirics.md")

GAS_PRICE_ORACLE = "0x420000000000000000000000000000000000000F"  # OP Stack predeploy
FEE_WINDOW = 30  # blocks per selected block: one minute of Base
PERCENTILES = [10, 25, 50, 75, 90]
FEE_HISTORY_MAX = 1024
SAMPLE_EVERY = 10  # pre-London L1 blocks read in full

L1_WINDOWS = {
    "2020-03-12/13": ("2020-03-12", "2020-03-14"),
    "2021-05-19": ("2021-05-19", "2021-05-20"),
    "2022-05-09..12": ("2022-05-09", "2022-05-13"),
    "2024-08-05": ("2024-08-05", "2024-08-06"),
}


def selector(signature: str) -> bytes:
    return function_signature_to_4byte_selector(signature)


# ----------------------------------------------------------------------------- payloads
def rlp_encode(item) -> bytes:
    """Minimal RLP (Ethereum yellow paper, appendix B) for bytes, ints and lists."""
    if isinstance(item, int):
        item = item.to_bytes((item.bit_length() + 7) // 8, "big") if item else b""
    if isinstance(item, bytes):
        if len(item) == 1 and item[0] < 0x80:
            return item
        return _rlp_length(len(item), 0x80) + item
    payload = b"".join(rlp_encode(x) for x in item)
    return _rlp_length(len(payload), 0xC0) + payload


def _rlp_length(n: int, offset: int) -> bytes:
    if n < 56:
        return bytes([offset + n])
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(raw)]) + raw


def signed_1559(to: str, data: bytes, rng: random.Random, chain_id: int = 8453) -> bytes:
    """EIP-1559 envelope: 0x02 || rlp([chainId, nonce, tip, maxFee, gas, to, value, data,
    accessList, yParity, r, s])."""
    r = rng.getrandbits(256) | (1 << 255)
    s = rng.getrandbits(255) | (1 << 250)  # low-s range, as real signatures are
    fields = [
        chain_id,
        1_234,
        1_000_000,
        50_000_000,
        600_000,
        bytes.fromhex(to[2:]),
        0,
        data,
        [],
        1,
        r,
        s,
    ]
    return b"\x02" + rlp_encode(fields)


def payloads(rng: random.Random) -> dict[str, bytes]:
    weth = "0x4200000000000000000000000000000000000006"
    usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    aave_pool = "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5"
    user = "0x" + rng.randbytes(20).hex()
    keeper = "0x" + rng.randbytes(20).hex()
    vault = "0x" + rng.randbytes(20).hex()
    house = "0x" + rng.randbytes(20).hex()
    return {
        "bagehot_a_liquidate": signed_1559(
            vault, selector("liquidate(uint256)") + encode(["uint256"], [4_217]), rng
        ),
        "bagehot_b_buy": signed_1559(
            house,
            selector("buy(uint256,uint256,uint256,address,bytes)")
            + encode(
                ["uint256", "uint256", "uint256", "address", "bytes"],
                [57, 2**256 - 1, 3_100 * 10**18, keeper, b""],
            ),
            rng,
        ),
        "aave_liquidation_call": signed_1559(
            aave_pool,
            selector("liquidationCall(address,address,address,uint256,bool)")
            + encode(
                ["address", "address", "address", "uint256", "bool"],
                [weth, usdc, user, 2**256 - 1, False],
            ),
            rng,
        ),
    }


# ----------------------------------------------------------------------------- fee history
def fee_history_rows(rpc: Rpc, newest: int, count: int) -> list[dict]:
    """One row per block: base fee and gas-weighted priority-fee percentiles (wei)."""
    fh = rpc.call("eth_feeHistory", [hex(count), hex(newest), PERCENTILES])
    oldest = int(fh["oldestBlock"], 16)
    rows = []
    for i, ratio in enumerate(fh["gasUsedRatio"]):
        row = {
            "block_number": oldest + i,
            "base_fee_wei": int(fh["baseFeePerGas"][i], 16),
            "gas_used_ratio": float(ratio),
        }
        rewards = fh.get("reward") or []
        for p, value in zip(PERCENTILES, rewards[i] if i < len(rewards) else [], strict=False):
            row[f"priority_p{p}_wei"] = int(value, 16)
        rows.append(row)
    return rows


def gas_price_percentiles(txs: list[dict], base_fee: int = 0) -> dict[str, int]:
    """Gas-weighted percentiles of the price paid per gas, as eth_feeHistory weights them.

    Weights are the gas *limit* here because receipts are not fetched; the report says so.
    """
    paid = []
    for tx in txs:
        if "maxFeePerGas" in tx:
            tip = min(int(tx["maxPriorityFeePerGas"], 16), int(tx["maxFeePerGas"], 16) - base_fee)
            price = base_fee + tip
        else:
            price = int(tx["gasPrice"], 16)
        paid.append((price, int(tx["gas"], 16)))
    if not paid:
        return {f"price_p{p}_wei": 0 for p in PERCENTILES}
    paid.sort()
    total = sum(g for _, g in paid)
    out, acc, k = {}, 0, 0
    for p in PERCENTILES:
        target = total * p / 100
        while k < len(paid) - 1 and acc + paid[k][1] < target:
            acc += paid[k][1]
            k += 1
        out[f"price_p{p}_wei"] = paid[k][0]
    return out


# ----------------------------------------------------------------------------- base
def call_uint(rpc: Rpc, to: str, data: bytes, block: int) -> int | None:
    try:
        raw = rpc.eth_call(to, "0x" + data.hex(), block)
    except RpcError:
        return None  # e.g. blobBaseFee() before the Ecotone upgrade
    return decode(["uint256"], bytes.fromhex(raw[2:]))[0] if raw not in ("0x", "") else None


def fetch_base(rpc: Rpc) -> pd.DataFrame:
    blocks = pd.read_parquet(BLOCKS)
    txs = payloads(random.Random(8453))
    rows = []
    for _, sel in blocks.iterrows():
        b = int(sel["block_number"])
        l1 = {
            name: call_uint(
                rpc, GAS_PRICE_ORACLE, selector("getL1Fee(bytes)") + encode(["bytes"], [tx]), b
            )
            for name, tx in txs.items()
        }
        l1_base = call_uint(rpc, GAS_PRICE_ORACLE, selector("l1BaseFee()"), b)
        blob_base = call_uint(rpc, GAS_PRICE_ORACLE, selector("blobBaseFee()"), b)
        for row in fee_history_rows(rpc, b, FEE_WINDOW):
            row.update(
                {
                    "selected_block": b,
                    "kind": sel["kind"],
                    "rank": int(sel["rank"]),
                    "eth_usd": float(sel["close"]),
                    "is_selected": row["block_number"] == b,
                }
            )
            if row["block_number"] == b:  # L1 fee is evaluated at the selected block itself
                row.update({f"l1_fee_wei_{k}": v for k, v in l1.items()})
                row.update({"l1_base_fee_wei": l1_base, "blob_base_fee_wei": blob_base})
            rows.append(row)
    frame = pd.DataFrame(rows)
    frame["payload_bytes_bagehot_a"] = len(txs["bagehot_a_liquidate"])
    frame["payload_bytes_bagehot_b"] = len(txs["bagehot_b_buy"])
    frame["payload_bytes_aave"] = len(txs["aave_liquidation_call"])
    print(f"base: {len(blocks)} selected blocks, {len(frame)} rows, {rpc.requests} requests")
    return frame


# ----------------------------------------------------------------------------- l1
def fetch_l1(rpc: Rpc) -> pd.DataFrame:
    clock = BlockClock(rpc, "ethereum", CACHE)
    head = rpc.block_number()
    rows, bounds = [], {}
    for wid, (a, b) in L1_WINDOWS.items():
        lo = clock.block_at(day(a), 0, head) + 1
        hi = clock.block_at(day(b), 0, head)
        header = rpc.call("eth_getBlockByNumber", [hex(lo), False])
        post_london = header.get("baseFeePerGas") is not None
        if post_london:
            cursor = lo
            while cursor <= hi:
                count = min(FEE_HISTORY_MAX, hi - cursor + 1)
                for r in fee_history_rows(rpc, cursor + count - 1, count):
                    rows.append({**r, "window": wid, "regime": "post_london"})
                cursor += count
        else:
            for blk in range(lo, hi + 1, SAMPLE_EVERY):
                full = rpc.call("eth_getBlockByNumber", [hex(blk), True])
                rows.append(
                    {
                        "block_number": blk,
                        "base_fee_wei": 0,
                        "gas_used_ratio": int(full["gasUsed"], 16) / int(full["gasLimit"], 16),
                        **gas_price_percentiles(full["transactions"]),
                        "window": wid,
                        "regime": "pre_london",
                    }
                )
        bounds[wid] = (lo, clock.timestamp(lo), hi, clock.timestamp(hi))
        how = "feeHistory" if post_london else f"every {SAMPLE_EVERY}th block in full"
        print(f"l1 {wid}: blocks {lo:,}..{hi:,} ({how})")
    frame = pd.DataFrame(rows)
    frame["block_timestamp_approx"] = interpolate_timestamps(frame, bounds)
    print(f"l1: {len(frame)} rows, {rpc.requests} requests")
    return frame


def interpolate_timestamps(frame: pd.DataFrame, bounds: dict) -> pd.Series:
    """Linear in block number between each window's two exact boundary headers.

    Approximate by construction (pre-merge block times vary), hence the column name; the exact
    timestamps of the boundaries are what the window coverage rests on.
    """
    out = pd.Series(0, index=frame.index, dtype="int64")
    for wid, (lo, ts_lo, hi, ts_hi) in bounds.items():
        sel = frame["window"] == wid
        span = max(1, hi - lo)
        out[sel] = ts_lo + ((frame.loc[sel, "block_number"] - lo) * (ts_hi - ts_lo) // span)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("part", choices=["base", "l1", "report"])
    args = ap.parse_args(argv)
    PROCESSED.mkdir(parents=True, exist_ok=True)
    if args.part == "base":
        with Rpc.from_env() as rpc:
            fetch_base(rpc).to_parquet(COSTS_BASE, index=False)
    elif args.part == "l1":
        with Rpc.from_env("ETH_MAINNET_RPC") as rpc:
            fetch_l1(rpc).to_parquet(COSTS_L1, index=False)
    else:
        from data.analyze_costs import write_report

        write_report()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
