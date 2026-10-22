"""Transaction costs in the two regimes the report needs: Base L2, and Ethereum L1 in a crash (P09).

    just costs base      # needs BASE_ARCHIVE_RPC and data/processed/blocks_selected.parquet
    just costs l1        # needs ETH_MAINNET_RPC
    just costs report    # reports/cost-empirics.md from the two parquet files

Base (kit correction 10: cost = L2 execution + L1 data fee):
  * L2 execution: the FEE_WINDOW blocks ending at each selected block, read in full with their
    receipts — base fee from the header, priority-fee percentiles weighted by gas used (what
    eth_feeHistory computes, but independent of how far back a provider serves it; P09 found one
    that serves it only for recent blocks). OP Stack deposit transactions pay no fee and are
    excluded.
  * L1 data fee: the OP Stack GasPriceOracle predeploy's `getL1Fee(bytes)` at that block (archive
    eth_call), for three representative signed liquidation transactions: Bagehot A
    `liquidate(uint256)`, Bagehot B `buy(...)`, and Aave v3 `liquidationCall(...)` as a reference.
    The transactions are RLP-encoded EIP-1559 envelopes with deterministic pseudo-random signature
    bytes: the oracle prices the compressed size, and real signatures are incompressible noise.

Ethereum L1, in the named stress windows: per-gas prices only. The gas our own liquidation uses is
measured at P20; total cost = price × that gas is computed there, not guessed here.
  * After London (EIP-1559): `eth_feeHistory` for every block if the provider serves that depth;
    otherwise every SAMPLE_EVERY-th block read in full (column `source` says which).
  * Before London (2020-03, 2021-05): there is no base fee. Every SAMPLE_EVERY-th block is read
    in full and the gas-weighted percentiles of the gas price paid are computed.
"""

from __future__ import annotations

import argparse
import json
import random
import sqlite3
from pathlib import Path

import pandas as pd
from eth_abi import decode, encode
from eth_utils import function_signature_to_4byte_selector

from data.analyze_oracle import day
from data.blocks import CACHE, BlockClock
from data.blocks import OUTPUT as BLOCKS
from data.http import RetryPolicy
from data.rpc import Rpc, RpcError, RpcUnavailable

PATIENT = RetryPolicy(attempts=10, base_delay=2.0, max_delay=120.0)

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


def weighted_percentiles(pairs: list[tuple[int, int]], prefix: str) -> dict[str, int]:
    """Gas-weighted percentiles of (value, gas) pairs, the way eth_feeHistory computes rewards:
    sort by value, walk the cumulative gas, take the value where it crosses p% of the total."""
    if not pairs:
        return {f"{prefix}_p{p}_wei": 0 for p in PERCENTILES}
    pairs = sorted(pairs)
    total = sum(g for _, g in pairs)
    out, acc, k = {}, 0, 0
    for p in PERCENTILES:
        target = total * p / 100
        while k < len(pairs) - 1 and acc + pairs[k][1] < target:
            acc += pairs[k][1]
            k += 1
        out[f"{prefix}_p{p}_wei"] = pairs[k][0]
    return out


def effective_tip(tx: dict, base_fee: int) -> int:
    """What the block producer earned per gas: EIP-1559 capped tip, or gasPrice minus base fee."""
    if "maxFeePerGas" in tx:
        tip = min(int(tx["maxPriorityFeePerGas"], 16), int(tx["maxFeePerGas"], 16) - base_fee)
    else:
        tip = int(tx["gasPrice"], 16) - base_fee
    return max(tip, 0)


def gas_price_percentiles(txs: list[dict], base_fee: int = 0) -> dict[str, int]:
    """Price paid per gas (base fee + tip), weighted by gas limit (no receipts)."""
    return weighted_percentiles(
        [(base_fee + effective_tip(tx, base_fee), int(tx["gas"], 16)) for tx in txs], "price"
    )


OP_DEPOSIT_TX = "0x7e"  # OP Stack system/deposit transaction: carries no fee
CACHE_DB = Path("data/raw/costs/cache.sqlite")
RPS = 3.0  # free-tier archive plans rate-limit full blocks with receipts; be patient, not fast


class ResultCache:
    """Small SQLite cache of computed per-block rows and eth_call results, so a rate-limit stop
    resumes where it left off instead of starting over. Rows only, never raw blocks (too large)."""

    def __init__(self, path: Path = CACHE_DB):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")

    def get_or(self, key: str, compute):
        row = self.db.execute("SELECT value FROM kv WHERE key=?", (key,)).fetchone()
        if row:
            return json.loads(row[0])
        value = compute()
        self.db.execute("INSERT INTO kv VALUES (?, ?)", (key, json.dumps(value)))
        self.db.commit()
        return value


def block_fee_row(rpc: Rpc, number: int, *, with_receipts: bool) -> dict:
    """Fee statistics of one block from the block itself — independent of how far back a provider
    serves eth_feeHistory. Weights are gas used (receipts) when available, else gas limit, and the
    row says which."""
    block = rpc.call("eth_getBlockByNumber", [hex(number), True])
    base_fee = int(block.get("baseFeePerGas") or "0x0", 16)
    used: dict[str, int] = {}
    weight = "gas_limit"
    if with_receipts:
        try:
            receipts = rpc.call("eth_getBlockReceipts", [hex(number)])
            used = {r["transactionHash"]: int(r["gasUsed"], 16) for r in receipts}
            weight = "gas_used"
        except (RpcError, RpcUnavailable):
            pass
    tips, prices = [], []
    for tx in block["transactions"]:
        if tx.get("type") == OP_DEPOSIT_TX:
            continue
        gas = used.get(tx["hash"], int(tx["gas"], 16))
        tip = effective_tip(tx, base_fee)
        tips.append((tip, gas))
        prices.append((base_fee + tip, gas))
    return {
        "block_number": number,
        "block_timestamp": int(block["timestamp"], 16),
        "base_fee_wei": base_fee,
        "gas_used_ratio": int(block["gasUsed"], 16) / int(block["gasLimit"], 16),
        "fee_txs": len(tips),
        "weights": weight,
        **weighted_percentiles(tips, "priority"),
        **weighted_percentiles(prices, "price"),
    }


# ----------------------------------------------------------------------------- base
def call_uint(rpc: Rpc, to: str, data: bytes, block: int) -> int | None:
    try:
        raw = rpc.eth_call(to, "0x" + data.hex(), block)
    except RpcError:
        return None  # e.g. blobBaseFee() before the Ecotone upgrade
    return decode(["uint256"], bytes.fromhex(raw[2:]))[0] if raw not in ("0x", "") else None


def fetch_base(rpc: Rpc, cache: ResultCache | None = None) -> pd.DataFrame:
    blocks = pd.read_parquet(BLOCKS)
    txs = payloads(random.Random(8453))
    cache = cache or ResultCache()
    rows = []
    for _, sel in blocks.iterrows():
        b = int(sel["block_number"])

        def oracle(name: str, data: bytes, blk: int = b):
            return cache.get_or(
                f"base:call:{blk}:{name}", lambda: call_uint(rpc, GAS_PRICE_ORACLE, data, blk)
            )

        l1 = {
            name: oracle(name, selector("getL1Fee(bytes)") + encode(["bytes"], [tx]))
            for name, tx in txs.items()
        }
        l1_base = oracle("l1BaseFee", selector("l1BaseFee()"))
        blob_base = oracle("blobBaseFee", selector("blobBaseFee()"))
        for row in (
            cache.get_or(f"base:row:{n}", lambda n=n: block_fee_row(rpc, n, with_receipts=True))
            for n in range(b - FEE_WINDOW + 1, b + 1)
        ):
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
def fetch_l1(rpc: Rpc, cache: ResultCache | None = None) -> pd.DataFrame:
    cache = cache or ResultCache()
    clock = BlockClock(rpc, "ethereum", CACHE)
    head = rpc.block_number()
    rows, bounds = [], {}
    for wid, (a, b) in L1_WINDOWS.items():
        lo = clock.block_at(day(a), 0, head) + 1
        hi = clock.block_at(day(b), 0, head)
        header = rpc.call("eth_getBlockByNumber", [hex(lo), False])
        post_london = header.get("baseFeePerGas") is not None
        regime = "post_london" if post_london else "pre_london"
        how = f"every {SAMPLE_EVERY}th block in full"
        window_rows = []
        if post_london:
            try:
                cursor = lo
                while cursor <= hi:
                    count = min(FEE_HISTORY_MAX, hi - cursor + 1)
                    window_rows += [
                        {**r, "source": "fee_history"}
                        for r in fee_history_rows(rpc, cursor + count - 1, count)
                    ]
                    cursor += count
                how = "eth_feeHistory, every block"
            except (RpcError, RpcUnavailable):
                window_rows = []  # provider does not serve history this deep: sample blocks
        if not window_rows:
            window_rows = [
                {
                    **cache.get_or(
                        f"l1:row:{n}", lambda n=n: block_fee_row(rpc, n, with_receipts=False)
                    ),
                    "source": "sampled_blocks",
                }
                for n in range(lo, hi + 1, SAMPLE_EVERY)
            ]
        rows += [{**r, "window": wid, "regime": regime} for r in window_rows]
        bounds[wid] = (lo, clock.timestamp(lo), hi, clock.timestamp(hi))
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
        with Rpc.from_env(rps=RPS, policy=PATIENT) as rpc:
            fetch_base(rpc).to_parquet(COSTS_BASE, index=False)
    elif args.part == "l1":
        with Rpc.from_env("ETH_MAINNET_RPC", rps=RPS, policy=PATIENT) as rpc:
            fetch_l1(rpc).to_parquet(COSTS_L1, index=False)
    else:
        from data.analyze_costs import write_report

        write_report()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
