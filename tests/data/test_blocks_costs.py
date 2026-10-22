"""P09: block selection, timestamp → block search, RLP payloads, fee parsing, L1 percentiles."""

from __future__ import annotations

import random

import numpy as np
import pandas as pd
import pytest

from data import blocks as bl
from data import fetch_costs as fc


# --------------------------------------------------------------------------- RLP vectors
@pytest.mark.parametrize(
    ("item", "expected"),
    [
        (b"dog", "83646f67"),
        ([b"cat", b"dog"], "c88363617483646f67"),
        (b"", "80"),
        ([], "c0"),
        (0, "80"),
        (15, "0f"),
        (1024, "820400"),
        ([[], [[]], [[], [[]]]], "c7c0c1c0c3c0c1c0"),
    ],
)
def test_rlp_matches_the_published_examples(item, expected):
    assert fc.rlp_encode(item).hex() == expected


def test_rlp_long_strings_use_a_length_prefix():
    data = b"Lorem ipsum dolor sit amet, consectetur adipisicing elit"  # 56 bytes
    assert fc.rlp_encode(data)[:2] == bytes([0xB8, 56])


def test_payloads_are_type2_envelopes_with_the_expected_selectors():
    txs = fc.payloads(random.Random(1))
    assert set(txs) == {"bagehot_a_liquidate", "bagehot_b_buy", "aave_liquidation_call"}
    assert all(tx[0] == 0x02 for tx in txs.values())
    # liquidationCall(address,address,address,uint256,bool) selector 0x00a718a9
    assert bytes.fromhex("00a718a9") in txs["aave_liquidation_call"]
    # The B purchase carries five words of arguments, A one: B is the longer transaction.
    assert (
        len(txs["bagehot_b_buy"])
        > len(txs["aave_liquidation_call"])
        > len(txs["bagehot_a_liquidate"])
    )


def test_payloads_are_deterministic_for_a_seed():
    assert fc.payloads(random.Random(8453)) == fc.payloads(random.Random(8453))


# --------------------------------------------------------------------------- fee history parsing
class FakeRpc:
    def __init__(self, fee_history=None, timestamps=None):
        self.fee_history = fee_history
        self.timestamps = timestamps or {}
        self.requests = 0

    def call(self, method, params):
        self.requests += 1
        assert method == "eth_feeHistory"
        return self.fee_history

    def get_block_timestamp(self, block):
        self.requests += 1
        return self.timestamps[block]


def test_fee_history_rows_align_blocks_fees_and_rewards():
    fh = {
        "oldestBlock": hex(100),
        "baseFeePerGas": [hex(10), hex(11), hex(12)],  # n + 1 entries: the last is the next block
        "gasUsedRatio": [0.5, 0.25],
        "reward": [[hex(v) for v in (1, 2, 3, 4, 5)], [hex(v) for v in (6, 7, 8, 9, 10)]],
    }
    rows = fc.fee_history_rows(FakeRpc(fh), newest=101, count=2)
    assert [r["block_number"] for r in rows] == [100, 101]
    assert [r["base_fee_wei"] for r in rows] == [10, 11]
    assert rows[1]["priority_p50_wei"] == 8 and rows[0]["priority_p90_wei"] == 5


def test_gas_weighted_percentiles_of_price_paid():
    txs = [
        {"gasPrice": hex(10), "gas": hex(100)},
        {"gasPrice": hex(20), "gas": hex(100)},
        {"gasPrice": hex(30), "gas": hex(800)},  # dominates by gas
    ]
    p = fc.gas_price_percentiles(txs)
    assert p["price_p10_wei"] == 10
    assert p["price_p25_wei"] == 30  # 20% of gas sits at 10 or 20, the rest at 30
    assert p["price_p50_wei"] == 30


def test_eip1559_price_paid_is_base_plus_capped_tip():
    txs = [{"maxFeePerGas": hex(100), "maxPriorityFeePerGas": hex(5), "gas": hex(1)}]
    assert fc.gas_price_percentiles(txs, base_fee=97)["price_p50_wei"] == 100  # tip capped at 3


def test_interpolated_timestamps_hit_the_exact_bounds():
    frame = pd.DataFrame({"window": ["w"] * 3, "block_number": [100, 150, 200]})
    ts = fc.interpolate_timestamps(frame, {"w": (100, 1_000, 200, 2_000)})
    assert ts.tolist() == [1_000, 1_500, 2_000]


# --------------------------------------------------------------------------- timestamp → block
def chain(genesis=1_000, n=1_000, step=2):
    return {b: genesis + step * b for b in range(n)}


def test_block_at_finds_the_last_block_at_or_before_a_timestamp(tmp_path):
    rpc = FakeRpc(timestamps=chain())
    clock = bl.BlockClock(rpc, "base", tmp_path / "c.sqlite")
    assert clock.block_at(1_000 + 2 * 345, 0, 999) == 345
    assert clock.block_at(1_000 + 2 * 345 + 1, 0, 999) == 345  # between blocks: the earlier one


def test_a_good_guess_costs_two_headers_and_the_cache_makes_repeats_free(tmp_path):
    rpc = FakeRpc(timestamps=chain())
    clock = bl.BlockClock(rpc, "base", tmp_path / "c.sqlite")
    assert clock.block_at(1_000 + 2 * 345, 0, 999, guess=345) == 345
    assert rpc.requests == 2
    clock.block_at(1_000 + 2 * 345, 0, 999, guess=345)
    assert rpc.requests == 2


def test_a_wrong_guess_still_converges(tmp_path):
    irregular = {b: 1_000 + 2 * b + (5 if b > 500 else 0) for b in range(1_000)}
    clock = bl.BlockClock(FakeRpc(timestamps=irregular), "base", tmp_path / "c.sqlite")
    target = irregular[700]
    assert clock.block_at(target, 0, 999, guess=(target - 1_000) // 2) == 700


def test_timestamps_before_the_range_are_rejected(tmp_path):
    clock = bl.BlockClock(FakeRpc(timestamps=chain()), "base", tmp_path / "c.sqlite")
    with pytest.raises(ValueError):
        clock.block_at(10, 0, 999)


# --------------------------------------------------------------------------- selection
def synthetic_minutes(days=60, start=1_722_384_000):
    rng = np.random.default_rng(3)
    n = days * 1440
    r = rng.normal(0, 0.0005, n)
    r[30 * 1440 : 30 * 1440 + 15] -= 0.01  # a sharp drop on day 30
    close = 3_000 * np.exp(np.cumsum(r))
    return pd.DataFrame({"ts": start + 60 * np.arange(n), "close": close})


def test_pick_separated_keeps_the_best_and_spaces_them():
    cand = pd.DataFrame({"ts": [0, 100, 10_000, 20_000], "v": [5.0, 4.0, 3.0, 1.0]})
    out = bl.pick_separated(cand, k=3, separation=1_000, order_col="v", ascending=False)
    assert out["ts"].tolist() == [0, 10_000, 20_000]  # 100 is too close to 0


def test_selection_includes_the_named_day_and_spaces_every_pick(tmp_path, monkeypatch):
    minutes = synthetic_minutes()
    path = tmp_path / "prices.parquet"
    minutes.assign(source="coinbase").to_parquet(path)
    f = bl.minute_frame(path)
    monkeypatch.setattr(bl, "STRESS_K", 5)
    monkeypatch.setattr(bl, "CALM_K", 3)
    t = bl.select_times(f, random.Random(1))

    assert (t["kind"] == "named").sum() == 1
    assert (t["kind"] == "stress").sum() == 5 and (t["kind"] == "calm").sum() == 3
    ts = sorted(t["ts"])
    assert min(np.diff(ts)) >= bl.STRESS_SEPARATION
    drop_end = int(minutes["ts"].iloc[30 * 1440 + 14])
    top = t[(t["kind"] == "stress") & (t["rank"] == 1)]["ts"].item()
    assert abs(top - drop_end) <= 15 * 60  # the engineered drop is the top stress pick
    assert t["reason"].str.len().min() > 20 and t["close"].notna().all()


def test_ret_24h_tolerates_a_missing_minute(tmp_path):
    minutes = synthetic_minutes(days=3)
    gap_at = int(minutes["ts"].iloc[2 * 1440 + 100 - 1440])  # exactly 24 h before row 2*1440+100
    path = tmp_path / "prices.parquet"
    minutes[minutes["ts"] != gap_at].assign(source="coinbase").to_parquet(path)
    f = bl.minute_frame(path)
    assert pd.notna(f["ret_24h"].iloc[2 * 1440 + 100])


# --------------------------------------------------------------------------- fees from full blocks
class BlockRpc:
    def __init__(self, block, receipts=None):
        self.block, self.receipts = block, receipts

    def call(self, method, params):
        if method == "eth_getBlockByNumber":
            return self.block
        if method == "eth_getBlockReceipts":
            if self.receipts is None:
                raise fc.RpcError(-32601, "method not found")
            return self.receipts
        raise AssertionError(method)


def base_block():
    return {
        "timestamp": hex(1_722_816_001),
        "baseFeePerGas": hex(100),
        "gasUsed": hex(600),
        "gasLimit": hex(1_200),
        "transactions": [
            {"hash": "0xdep", "type": "0x7e", "gas": hex(1_000_000), "gasPrice": hex(0)},
            {
                "hash": "0xa",
                "type": "0x2",
                "gas": hex(500),
                "maxFeePerGas": hex(200),
                "maxPriorityFeePerGas": hex(5),
            },
            {"hash": "0xb", "type": "0x0", "gas": hex(500), "gasPrice": hex(150)},
        ],
    }


def test_block_fee_row_skips_op_deposits_and_weights_by_gas_used():
    receipts = [
        {"transactionHash": "0xa", "gasUsed": hex(100)},
        {"transactionHash": "0xb", "gasUsed": hex(400)},
    ]
    row = fc.block_fee_row(BlockRpc(base_block(), receipts), 7, with_receipts=True)
    assert row["fee_txs"] == 2 and row["weights"] == "gas_used"  # the deposit is not counted
    assert row["base_fee_wei"] == 100 and row["gas_used_ratio"] == 0.5
    # tips: 5 (EIP-1559, 100 gas) and 50 (legacy 150 - 100, 400 gas): the median is 50
    assert row["priority_p10_wei"] == 5 and row["priority_p50_wei"] == 50
    assert row["price_p50_wei"] == 150


def test_block_fee_row_falls_back_to_gas_limit_weights_without_receipts():
    row = fc.block_fee_row(BlockRpc(base_block(), None), 7, with_receipts=True)
    assert row["weights"] == "gas_limit"
    assert row["priority_p50_wei"] == 5  # equal gas limits: the lower tip reaches 50% first


def test_pre_london_blocks_have_zero_base_fee_and_tip_equals_gas_price():
    block = {
        **base_block(),
        "baseFeePerGas": None,
        "transactions": [{"hash": "0xc", "type": "0x0", "gas": hex(21_000), "gasPrice": hex(90)}],
    }
    row = fc.block_fee_row(BlockRpc(block), 7, with_receipts=False)
    assert row["base_fee_wei"] == 0 and row["price_p50_wei"] == 90 and row["priority_p50_wei"] == 90
