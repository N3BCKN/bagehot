"""P07 oracle pipeline: RPC redaction, log decoding, phase search, scanning, checks, inference.

Offline. Payloads are ABI-encoded exactly as a node returns them, so decoding is tested against
the real wire format; recorded archive responses are added as fixtures once the live fetch runs.
"""

from __future__ import annotations

import json

import httpx
import pandas as pd
import pytest
from eth_abi import encode

from data import analyze_oracle as ao
from data import fetch_oracle as fo
from data import process_oracle as po
from data.rpc import RangeTooLarge, Rpc, RpcError, RpcUnavailable

SECRET_URL = "https://base-mainnet.example.invalid/v2/SECRET-KEY-123"
AGG = "0x00000000000000000000000000000000000000aa"


def word(value: int, kind: str = "uint256") -> str:
    return "0x" + encode([kind], [value]).hex()


def answer_log(answer: int, round_id: int, updated_at: int, block: int, index: int = 0) -> dict:
    return {
        "address": AGG,
        "topics": [fo.ANSWER_UPDATED, word(answer, "int256"), word(round_id)],
        "data": word(updated_at),
        "blockNumber": hex(block),
        "transactionHash": "0x" + f"{block:064x}",
        "logIndex": hex(index),
    }


# --------------------------------------------------------------------------- rpc redaction
def rpc_with(handler) -> Rpc:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return Rpc(SECRET_URL, client=client, sleep=lambda _s: None)


def test_rpc_repr_never_shows_the_endpoint():
    assert "SECRET" not in repr(rpc_with(lambda r: httpx.Response(200, json={"result": "0x1"})))


def test_node_error_messages_are_scrubbed_of_the_url():
    def handler(request):
        msg = f"upstream {SECRET_URL} refused: execution reverted"
        return httpx.Response(
            200, json={"jsonrpc": "2.0", "id": 1, "error": {"code": 3, "message": msg}}
        )

    with pytest.raises(RpcError) as err:
        rpc_with(handler).call("eth_call", [])
    assert "SECRET" not in str(err.value) and "example.invalid" not in str(err.value)
    assert err.value.__cause__ is None and err.value.__suppress_context__


def test_transport_failures_report_no_url():
    def handler(request):
        raise httpx.ConnectError(f"could not connect to {SECRET_URL}")

    with pytest.raises(RpcUnavailable) as err:
        rpc_with(handler).call("eth_blockNumber", [])
    assert "SECRET" not in str(err.value) and "ConnectError" in str(err.value)


def test_http_errors_report_no_url():
    with pytest.raises(RpcUnavailable) as err:
        rpc_with(lambda r: httpx.Response(401, text=SECRET_URL)).call("eth_blockNumber", [])
    assert "SECRET" not in str(err.value) and "401" in str(err.value)


@pytest.mark.parametrize(
    "message",
    [
        "query returned more than 10000 results",
        "Log response size exceeded. You can make eth_getLogs requests with up to a 2K block range",
        "eth_getLogs is limited to a 10,000 range",
        "block range too large",
    ],
)
def test_range_errors_from_known_providers_are_recognised(message):
    def handler(request):
        return httpx.Response(200, json={"error": {"code": -32602, "message": message}})

    with pytest.raises(RangeTooLarge):
        rpc_with(handler).get_logs(AGG, [fo.ANSWER_UPDATED], 0, 10)


def test_rate_limits_are_retried_then_succeed():
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        if calls["n"] < 3:
            return httpx.Response(429)
        return httpx.Response(200, json={"result": "0x10"})

    rpc = rpc_with(handler)
    assert rpc.block_number() == 16
    assert rpc.requests == 3


def test_from_env_refuses_to_run_without_the_variable(monkeypatch):
    monkeypatch.delenv("BASE_ARCHIVE_RPC", raising=False)
    with pytest.raises(SystemExit, match="not set"):
        Rpc.from_env()


# --------------------------------------------------------------------------- decoding
def test_answer_updated_topic_is_the_documented_signature():
    assert fo.ANSWER_UPDATED == (
        "0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f"
    )


def test_decode_log_reads_signed_answers_and_round_ids():
    log = answer_log(answer=-5, round_id=18446744073709551999, updated_at=1_722_816_000, block=42)
    row = fo.decode_log(log)
    assert row["answer"] == -5
    assert row["aggregator_round_id"] == 18446744073709551999
    assert row["updated_at"] == 1_722_816_000
    assert row["block_number"] == 42


def test_decode_log_rejects_other_events():
    log = answer_log(1, 1, 1, 1)
    log["topics"][0] = "0x" + "11" * 32
    with pytest.raises(ValueError):
        fo.decode_log(log)


def test_phase_encoded_round_ids_exceed_int64():
    rid = fo.encode_round(3, 12)
    assert rid == (3 << 64) | 12
    assert rid > 2**63 - 1  # hence stored as strings


def test_selectors_match_the_aggregator_interface():
    assert fo.SEL["phaseId()"] == "0x58303b10"
    assert fo.SEL["latestRoundData()"] == "0xfeaf968c"
    assert fo.SEL_GET_ROUND_DATA == "0x9a6fc8f5"
    assert fo.SEL_PHASE_AGGREGATORS == "0xc1597304"


# --------------------------------------------------------------------------- phase search
def test_first_block_where_finds_the_boundary():
    assert fo.first_block_where(lambda b: b >= 777, 0, 10_000) == 777
    assert fo.first_block_where(lambda b: True, 5, 9) == 5


class FakeChain:
    """Proxy with two phases: created at 100, phase 2 from block 5_000. Head 10_000."""

    def __init__(self, cap: int = 10_000_000):
        self.cap = cap
        self.requests = 0
        self.logs = {
            "0x00000000000000000000000000000000000000a1": [
                answer_log(10, r, 1000 + r, 150 + r * 10) for r in range(1, 6)
            ],
            "0x00000000000000000000000000000000000000a2": [
                answer_log(20, r, 9000 + r, 4_700 + r * 100) for r in range(1, 30)
            ],
        }

    def get_code(self, address, block):
        self.requests += 1
        return "0x60" if block >= 100 else "0x"

    def eth_call(self, to, data, block):
        self.requests += 1
        if data == fo.SEL["phaseId()"]:
            return "0x" if block < 100 else word(1 if block < 5_000 else 2)
        if data.startswith(fo.SEL_PHASE_AGGREGATORS):
            phase = int(data[10:], 16)
            return word(int(f"a{phase}", 16), "uint256")
        raise AssertionError(data)

    def get_logs(self, address, topics, lo, hi):
        self.requests += 1
        if hi - lo + 1 > self.cap:
            raise RangeTooLarge(-32602, "block range too large")
        return [
            lg
            for lg in self.logs.get(address.lower(), [])
            if lo <= int(lg["blockNumber"], 16) <= hi
        ]


def test_read_phases_recovers_creation_and_boundaries():
    created, phases = fo.read_phases(FakeChain(), "0xproxy", head=10_000)
    assert created == 100
    assert [(p.phase, p.start_block, p.end_block) for p in phases] == [
        (1, 100, 4_999),
        (2, 5_000, 10_000),
    ]
    assert phases[1].aggregator.lower().endswith("a2")


# --------------------------------------------------------------------------- scanning, resume
def test_scan_halves_on_a_capped_provider_and_resumes_without_requests(tmp_path):
    chain = FakeChain(cap=300)
    phase = fo.Phase(2, "0x00000000000000000000000000000000000000A2", 5_000, 10_000)
    state = fo.ScanState(chunk=4_000, max_chunk=4_000)

    found = fo.scan_phase(chain, "eth_usd", phase, state, root=tmp_path)

    in_range = [
        lg for lg in chain.logs[phase.aggregator.lower()] if int(lg["blockNumber"], 16) >= 5_000
    ]
    assert found == len(in_range)
    assert state.halvings >= 1 and state.chunk <= 300 * 2
    meta = fo.load_phase_meta("eth_usd", 2, tmp_path)
    assert meta["scanned_to"] == 10_000 and meta["complete"]

    before = chain.requests
    assert fo.scan_phase(chain, "eth_usd", phase, state, root=tmp_path) == 0
    assert chain.requests == before  # nothing left to fetch


def test_stored_logs_round_trip_in_block_order(tmp_path):
    chain = FakeChain()
    phase = fo.Phase(2, "0x00000000000000000000000000000000000000A2", 5_000, 10_000)
    fo.scan_phase(chain, "eth_usd", phase, fo.ScanState(chunk=1_000), root=tmp_path)
    blocks = [int(lg["blockNumber"], 16) for lg in fo.iter_phase_logs("eth_usd", 2, tmp_path)]
    assert blocks == sorted(blocks) and all(b >= 5_000 for b in blocks)


def test_pre_phase_log_is_the_last_one_before_the_phase_start():
    chain = FakeChain()
    phase = fo.Phase(2, "0x00000000000000000000000000000000000000A2", 5_000, 10_000)
    pre = fo.find_pre_phase_log(chain, phase, fo.ScanState(chunk=50), floor=100)
    # a2 publishes round r at block 4_700 + 100 r: rounds 1 and 2 precede the phase start.
    assert int(pre["blockNumber"], 16) == 4_900
    assert fo.decode_log(pre)["aggregator_round_id"] == 2


def test_pre_phase_log_is_none_when_the_aggregator_starts_with_its_phase():
    chain = FakeChain()
    phase = fo.Phase(1, "0x00000000000000000000000000000000000000A1", 100, 4_999)
    assert fo.find_pre_phase_log(chain, phase, fo.ScanState(chunk=50), floor=100) is None


def test_scan_refuses_a_changed_aggregator(tmp_path):
    fo.save_phase_meta("eth_usd", 1, {"aggregator": "0xother", "scanned_to": 10}, tmp_path)
    phase = fo.Phase(1, "0x00000000000000000000000000000000000000A1", 100, 200)
    with pytest.raises(SystemExit, match="differs"):
        fo.scan_phase(FakeChain(), "eth_usd", phase, fo.ScanState(chunk=100), root=tmp_path)


def test_probe_chunk_halves_to_the_cap():
    chain = FakeChain(cap=70_000)
    assert fo.probe_chunk(chain, AGG, 0, 10_000_000, 500_000) == 62_500


# --------------------------------------------------------------------------- processing checks
def rows(ids, phase=1, in_phase=None):
    in_phase = in_phase or [True] * len(ids)
    return [
        {
            "phase": phase,
            "aggregator_round_id": i,
            "answer": 2_000 * 10**8 + i,
            "updated_at": 1000 + i,
            "block_number": 10 + i,
            "tx_hash": "0x",
            "log_index": 0,
            "aggregator": AGG,
            "in_phase": ip,
        }
        for i, ip in zip(ids, in_phase, strict=True)
    ]


def test_check_rounds_accepts_consecutive_ids_with_a_pre_phase_round():
    frame = po.build_frame(rows([3, 7, 8, 9], in_phase=[False, True, True, True]), 8, 0)
    assert po.check_rounds(frame) == []


def test_check_rounds_reports_gaps_and_disorder():
    gap = po.build_frame(rows([1, 2, 5]), 8, 0)
    assert po.check_rounds(gap) == ["phase 1: gap between rounds 2 and 5"]
    disorder = po.build_frame(rows([1, 3, 2]), 8, 0)
    assert any("not strictly increasing" in p for p in po.check_rounds(disorder))


def test_build_frame_keeps_integers_exact_and_encodes_round_ids():
    frame = po.build_frame(rows([1], phase=2), 8, genesis_ts=1_686_789_347)
    assert frame["answer"].iloc[0] == str(2_000 * 10**8 + 1)
    assert frame["round_id"].iloc[0] == str((2 << 64) | 1)
    assert frame["block_timestamp"].iloc[0] == 1_686_789_347 + 2 * 11


def test_sequencer_frame_needs_started_at_for_every_round():
    with pytest.raises(SystemExit, match="startedAt"):
        po.build_frame(rows([1]), 0, 0, started={})


# --------------------------------------------------------------------------- inference
def synthetic_feed(n=400, heartbeat=1200, threshold_bps=15.0):
    """Alternating heartbeat updates (tiny moves) and deviation updates (moves at the threshold)."""
    ts, price, out = 1_700_000_000, 2_000.0, []
    for i in range(n):
        if i % 2:
            ts += heartbeat + 2
            price *= 1.00002
        else:
            ts += 90
            price *= 1 + (threshold_bps + (i % 7)) / 10_000
        out.append({"updated_at": ts, "price": price})
    f = pd.DataFrame(out)
    f["dt"] = f["updated_at"].diff()
    f["rel_change"] = (f["price"] / f["price"].shift() - 1.0).abs()
    return f


def test_heartbeat_is_inferred_from_the_quiet_updates():
    hb = ao.infer_heartbeat(synthetic_feed(), documented=1200, threshold_pct=0.15)
    assert hb["quiet_dt_mode_10s"] == 1200
    assert hb["share_quiet_within_60s_of_doc"] == pytest.approx(1.0)


def test_threshold_is_the_floor_of_early_updates():
    th = ao.infer_threshold(synthetic_feed(), heartbeat=1200, threshold_pct=0.15)
    assert 15.0 <= th["p1_bps"] < 16.0
    assert th["share_below_doc"] == 0.0


def test_downtime_episodes_pair_down_and_up_rounds():
    seq = pd.DataFrame(
        {
            "phase": [1, 1, 1],
            "aggregator_round_id": ["1", "2", "3"],
            "answer": ["0", "1", "0"],
            "started_at": [1_000, 5_000, 5_900],
            "block_number": [1, 2, 3],
            "in_phase": [True, True, True],
        }
    )
    eps = ao.downtime_episodes(seq)
    assert eps.to_dict("records") == [
        {"down_from": 5_000, "up_again": 5_900, "duration_s": 900, "reported_in_block": 2}
    ]


def test_time_weighted_gap_uses_the_answer_in_force():
    f = pd.DataFrame({"updated_at": [1_000_020, 1_000_200], "price": [100.0, 110.0]})
    # Minutes opening at 1_000_000 + 60 i, closing 60 s later.
    market = pd.Series([100.0, 105.0, 110.0, 110.0], index=[1_000_000 + 60 * i for i in range(4)])

    vm = ao.oracle_vs_market(f, market)

    # Minutes closing at 1_000_120 and 1_000_180 still see the 100.0 answer; the one closing at
    # 1_000_240 sees 110.0. The first minute opens before the first update and is excluded.
    assert list(vm["gap_ts"]) == [1_000_060, 1_000_120, 1_000_180]
    assert vm["gap_bps"].tolist() == pytest.approx(
        [abs(100 / 105 - 1) * 10_000, abs(100 / 110 - 1) * 10_000, 0.0]
    )


def test_json_manifest_round_trips(tmp_path):
    m = fo.FeedManifest("eth_usd", "0xp", "ETH / USD", 8, 10, 1, [{"phase": 1}], {}, {"checked": 0})
    fo.save_manifest(m, tmp_path)
    assert fo.load_manifest("eth_usd", tmp_path) == m
    assert json.loads(fo.manifest_path("eth_usd", tmp_path).read_text())["head"] == 10
