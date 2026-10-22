"""P08: Kaplan–Meier, onset search, Aave decoding, the call cache and its budget, windows."""

from __future__ import annotations

import pandas as pd
import pytest
from eth_abi import encode

from data import analyze_liquidations as al
from data import fetch_liquidations as fl

AAVE = fl.Aave(
    pool="0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
    oracle="0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156",
    weth="0x4200000000000000000000000000000000000006",
    stables={
        "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913": "USDC (native)",
        "0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA": "USDbC (bridged)",
    },
)
USDC, USDBC = list(AAVE.stables)
OTHER = "0x0000000000000000000000000000000000000Bad"


# --------------------------------------------------------------------------- Kaplan–Meier
def test_kaplan_meier_matches_a_hand_computed_example():
    # durations 1,2,2,3,4 with the 2nd "2" and the 4 censored.
    km = al.kaplan_meier([1, 2, 2, 3, 4], [1, 1, 0, 1, 0])
    assert list(km["time"]) == [1, 2, 3]
    assert list(km["at_risk"]) == [5, 4, 2]
    assert km["survival"].tolist() == pytest.approx([0.8, 0.6, 0.3])
    # Greenwood at t=1: S^2 * 1/(5*4); the log-log interval brackets S.
    first = km.iloc[0]
    assert first["lo"] < 0.8 < first["hi"]


def test_median_and_restricted_mean():
    km = al.kaplan_meier([1, 2, 2, 3, 4], [1, 1, 0, 1, 0])
    assert al.median_time(km) == 3
    assert al.rmst(km, 4) == pytest.approx(1.0 + 0.8 + 0.6 + 0.3)


def test_survival_is_one_before_the_first_event_and_steps_after():
    km = al.kaplan_meier([10, 20], [1, 1])
    assert al.survival_at(km, 5)[0] == 1.0
    assert al.survival_at(km, 10)[0] == pytest.approx(0.5)
    assert al.survival_at(km, 25)[0] == pytest.approx(0.0)


def test_median_not_reached_when_most_positions_are_censored():
    km = al.kaplan_meier([5, 100, 100, 100], [1, 0, 0, 0])
    assert al.median_time(km) is None


def test_censoring_is_what_makes_the_naive_view_optimistic():
    """Fast liquidations observed, slow ones censored: the naive median ignores the slow ones."""
    frame = pd.DataFrame(
        {"latency": [2.0, 4.0, 6.0, 600.0, 600.0, 600.0, 600.0], "event": [1, 1, 1, 0, 0, 0, 0]}
    )
    naive = frame[frame["event"] == 1]["latency"].median()
    km = al.kaplan_meier(frame["latency"], frame["event"])

    assert naive == 4.0
    # S bottoms out at 6/7 * 5/6 * 4/5 = 4/7 > 0.5: most positions were never liquidated, so the
    # censoring-aware median is not reached at all, while the naive one says "4 seconds".
    assert km["survival"].iloc[-1] == pytest.approx(4 / 7)
    assert al.median_time(km) is None


def test_median_is_the_first_time_survival_reaches_one_half():
    km = al.kaplan_meier([2.0, 4.0, 6.0, 600.0, 600.0, 600.0], [1, 1, 1, 0, 0, 0])
    assert km["survival"].iloc[-1] == pytest.approx(0.5)
    assert al.median_time(km) == 6.0


def test_empty_input_gives_an_empty_curve():
    assert al.kaplan_meier([], []).empty


# --------------------------------------------------------------------------- onset search
class Counter:
    def __init__(self, onset: int | None):
        self.onset, self.calls = onset, 0

    def __call__(self, i: int) -> bool:
        self.calls += 1
        return self.onset is not None and i >= self.onset


def test_a_correct_prediction_costs_two_calls():
    below = Counter(onset=7)
    assert fl.walk_to_onset(below, 20, 7) == 7
    assert below.calls == 2


def test_an_early_prediction_walks_forward_and_a_late_one_walks_back():
    early = Counter(onset=7)
    assert fl.walk_to_onset(early, 20, 5) == 7
    late = Counter(onset=7)
    assert fl.walk_to_onset(late, 20, 10) == 7


def test_without_forward_walk_a_false_start_means_no_onset():
    below = Counter(onset=None)
    assert fl.walk_to_onset(below, 20, 12, forward=False) is None
    assert below.calls == 1


def test_onset_start_uses_the_prediction_when_there_is_one():
    assert fl.onset_start([100, 95, 90, 85], 92, liquidated=False) == (2, True)


def test_onset_start_without_prediction_checks_one_index():
    prices = [100, 96, 94, 97]
    assert fl.onset_start(prices, 50, liquidated=False) == (2, False)  # the lowest price
    assert fl.onset_start(prices, 50, liquidated=True) == (3, False)  # just before liquidation


def test_liquidation_price_scales_inversely_with_health_factor():
    assert fl.liquidation_price(2_000 * 10**8, 2 * fl.WAD) == 1_000 * 10**8
    assert fl.liquidation_price(2_000 * 10**8, fl.WAD) == 2_000 * 10**8


def test_falling_keeps_only_updates_below_the_previous_answer():
    updates = [(1, 100), (2, 99), (3, 101), (4, 100), (5, 100)]
    assert fl.falling(updates) == [(2, 99), (4, 100)]


# --------------------------------------------------------------------------- Aave decoding
def test_single_weth_collateral_reads_the_configuration_bitmap():
    reserves = [AAVE.weth, USDC, OTHER, USDBC]

    def bits(collateral=(), borrowing=()):
        value = 0
        for i in collateral:
            value |= 1 << (2 * i + 1)
        for i in borrowing:
            value |= 1 << (2 * i)
        return value

    assert fl.single_weth_collateral(bits((0,), (1,)), reserves, AAVE) == (True, "")
    assert fl.single_weth_collateral(bits((0,), (1, 3)), reserves, AAVE) == (True, "")
    assert (
        fl.single_weth_collateral(bits((0, 2), (1,)), reserves, AAVE)[1]
        == "not_weth_only_collateral"
    )
    assert fl.single_weth_collateral(bits((0,), ()), reserves, AAVE)[1] == "no_debt"
    assert fl.single_weth_collateral(bits((0,), (2,)), reserves, AAVE)[1] == "non_stable_debt"


def test_decode_liquidation_labels_native_and_bridged_usdc():
    user = "0x1111111111111111111111111111111111111111"
    liquidator = "0x2222222222222222222222222222222222222222"
    log = {
        "topics": [
            fl.LIQUIDATION_CALL,
            fl.address_topic(AAVE.weth),
            fl.address_topic(USDBC),
            fl.address_topic(user),
        ],
        "data": "0x"
        + encode(
            ["uint256", "uint256", "address", "bool"],
            [5_000 * 10**6, 2 * 10**18, liquidator, False],
        ).hex(),
        "blockNumber": hex(18_000_000),
        "transactionHash": "0xabc",
        "logIndex": "0x3",
    }
    row = fl.decode_liquidation(log, AAVE)
    assert row["user"].lower() == user
    assert row["debt_label"] == "USDbC (bridged)"
    assert row["debt_to_cover"] == str(5_000 * 10**6)  # exact, as a string
    assert row["liquidator"].lower() == liquidator
    assert row["block_number"] == 18_000_000 and row["log_index"] == 3


def test_decode_account_reads_six_words():
    raw = "0x" + encode(["uint256"] * 6, [1, 2, 3, 8_250, 8_000, fl.WAD + 5]).hex()
    acct = fl.decode_account(raw)
    assert acct["liq_threshold"] == 8_250 and acct["hf"] == fl.WAD + 5


def test_event_topics_are_the_aave_v3_signatures():
    assert fl.LIQUIDATION_CALL == (
        "0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286"
    )
    assert fl.SUPPLY == "0x2b627736bca15cd5381dcf80b0bf11fd197d01a037c52b927a881a10fb73ba61"


# --------------------------------------------------------------------------- cache and budget
class FakeRpc:
    def __init__(self):
        self.calls = 0

    def eth_call(self, to, data, block):
        self.calls += 1
        return "0x" + encode(["uint256"], [block]).hex()


def test_cache_hits_are_free_and_misses_spend_budget(tmp_path):
    rpc = FakeRpc()
    caller = fl.CachedCaller(rpc, tmp_path / "c.sqlite", budget=2)
    caller.call("m", "0xto", "0x01", 10, "u")
    caller.call("m", "0xto", "0x01", 10, "u")  # hit
    caller.call("m", "0xto", "0x01", 11, "u")
    assert rpc.calls == 2 and caller.spent == 2 and caller.hits == 1
    with pytest.raises(fl.BudgetExhausted):
        caller.call("m", "0xto", "0x01", 12, "u")


def test_spend_is_cumulative_across_runs(tmp_path):
    rpc = FakeRpc()
    first = fl.CachedCaller(rpc, tmp_path / "c.sqlite", budget=3)
    first.call("m", "0xto", "0x01", 1, "u")
    first.call("m", "0xto", "0x01", 2, "u")
    second = fl.CachedCaller(rpc, tmp_path / "c.sqlite", budget=3)
    assert second.spent == 2
    second.call("m", "0xto", "0x01", 3, "u")
    with pytest.raises(fl.BudgetExhausted):  # a restart does not reset the approved budget
        second.call("m", "0xto", "0x01", 4, "u")


def test_approval_must_match_the_plan_exactly_the_first_time():
    fl.check_approval(500, 500, 0)
    with pytest.raises(SystemExit, match="does not match"):
        fl.check_approval(600, 500, 0)
    with pytest.raises(SystemExit, match="does not match"):
        fl.check_approval(400, 500, 0)
    fl.check_approval(650, 500, 500)  # extension once the plan's calls are spent


# --------------------------------------------------------------------------- windows
def test_ts_to_block_rounds_inwards():
    assert fl.ts_to_block(1_000, 1_000, ceil=True) == 0
    assert fl.ts_to_block(1_003, 1_000, ceil=True) == 2
    assert fl.ts_to_block(1_003, 1_000, ceil=False) == 1


def test_build_windows_adds_drops_that_do_not_overlap_the_named_window():
    start = 1_722_729_600  # 2024-08-04
    ts = [start + 60 * i for i in range(60 * 24 * 40)]
    price = [3_000.0] * len(ts)
    for i in range(60 * 24 * 20, 60 * 24 * 21):  # a 30% drop on day 20
        price[i] = 2_100.0
    market = pd.Series(price, index=ts)
    windows = fl.build_windows(market, start, genesis_ts=start - 2 * 10_000_000, head=10**9)

    ids = [w.id for w in windows]
    assert "2024-08-05" in ids
    spans = [(w.start_ts, w.end_ts - fl.WINDOW_TAIL) for w in windows]
    for i, (a, b) in enumerate(spans):
        for c, d in spans[i + 1 :]:
            assert not (a < d and c < b), "chosen windows overlap"
    assert all(w.end_ts - w.start_ts >= 86_400 + fl.WINDOW_TAIL for w in windows)
