"""model/protocol/oracle.py against spec/vectors/oracle.json, the reason values, and properties.

The Solidity adapter is checked against the same vectors in
contracts/test/vectors/OracleVectors.t.sol, so passing both suites means the two sides agree.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from hypothesis import given
from hypothesis import strategies as st

from model.protocol import oracle as o

VECTORS = json.loads(Path("spec/vectors/oracle.json").read_text())["vectors"]
START = {"staleness": 3_600, "grace_period": 3_600, "min_price": 10 * 10**18, "max_price": 10**24}


def adapter(**overrides) -> o.OracleAdapter:
    kw = dict(
        price_feed=1,
        sequencer_feed=2,
        oracle_gas=100_000,
        oracle_post_failure_gas=3_175,
        feed_decimals=8,
        **START,
    )
    kw.update(overrides)
    return o.OracleAdapter.deploy(**kw)


def reader(rnd: o.FeedRound | None, calls: list | None = None):
    def read():
        if calls is not None:
            calls.append(1)
        return rnd

    return read


def test_reason_values_match_the_spec_and_solidity_by_value() -> None:
    # same literal table as OracleAdapterTest.test_reasonCodes_matchTheSpecByValue
    assert {r.name: r.value for r in o.Reason} == {
        "OK": 0,
        "SEQUENCER_CALL_FAILED": 1,
        "SEQUENCER_DOWN": 2,
        "SEQUENCER_INVALID": 3,
        "GRACE_PERIOD": 4,
        "PRICE_CALL_FAILED": 5,
        "NON_POSITIVE": 6,
        "INVALID_TIMESTAMP": 7,
        "STALE": 8,
        "OUT_OF_BOUNDS": 9,
    }


@pytest.mark.parametrize("vec", VECTORS, ids=[v["name"] for v in VECTORS])
def test_vectors(vec: dict) -> None:
    inp, exp = vec["inputs"], vec["expected"]
    p = inp["params"]
    a = adapter(
        staleness=int(p["STALENESS"]),
        grace_period=int(p["GRACE_PERIOD"]),
        min_price=int(p["MIN_PRICE"]),
        max_price=int(p["MAX_PRICE"]),
        feed_decimals=int(p["FEED_DECIMALS"]),
    )
    s, f = inp["sequencer"], inp["priceFeed"]
    seq = (
        None
        if s is None
        else o.FeedRound(int(s["answer"]), int(s["startedAt"]), int(s["startedAt"]))
    )
    feed = (
        None
        if f is None
        else o.FeedRound(int(f["answer"]), int(f["updatedAt"]), int(f["updatedAt"]))
    )
    calls: list = []
    now = int(inp["now"])
    usable, price, reason = a.decide(now, reader(seq), reader(feed, calls))
    assert usable is exp["usable"]
    assert price == int(exp["price"])
    assert reason.name == exp["reason"]
    if vec["name"] == "lazy_sequencer_down_price_feed_failing":
        assert calls == [], "the price feed is never read when the sequencer decides"
    fp, fu = a.fetch_price(now, reader(seq), reader(feed))
    assert (fu, fp) == (exp["usable"], int(exp["price"]))
    assert a.failure_start == (0 if usable else now)


def test_vector_count() -> None:
    assert len(VECTORS) == 20


@pytest.mark.parametrize(
    ("overrides", "index"),
    [
        ({"price_feed": 0}, 0),
        ({"sequencer_feed": 0}, 1),
        ({"staleness": 0}, 2),
        ({"min_price": 2 * 10**18 - 1}, 4),
        ({"min_price": 2 * 10**18, "max_price": 2 * 10**18}, 5),
        ({"max_price": 10**30 + 1}, 5),
        ({"oracle_gas": 49_999}, 6),
        ({"oracle_gas": 1_000_001}, 6),
        ({"oracle_gas": 50_000, "oracle_post_failure_gas": 1_587}, 7),
        ({"oracle_gas": 1_000_000, "oracle_post_failure_gas": 31_746}, 7),
        ({"oracle_gas": 50_000, "oracle_post_failure_gas": 50_001}, 7),
        (
            {"oracle_gas": 100_000, "oracle_post_failure_gas": 1_588},
            7,
        ),  # the pre-CHG-004 start value
    ],
)
def test_constructor_invalid_parameter(overrides: dict, index: int) -> None:
    with pytest.raises(o.InvalidParameter) as e:
        adapter(**overrides)
    assert e.value.index == index


def test_constructor_floor_bounds_are_inclusive() -> None:
    assert (
        adapter(oracle_gas=50_000, oracle_post_failure_gas=1_588).oracle_post_failure_gas == 1_588
    )
    assert (
        adapter(oracle_gas=50_000, oracle_post_failure_gas=50_000).oracle_post_failure_gas == 50_000
    )
    assert adapter(oracle_gas=1_000_000, oracle_post_failure_gas=31_747).oracle_gas == 1_000_000


def test_constructor_invalid_feed_decimals() -> None:
    for d in (None, 19):
        with pytest.raises(o.InvalidFeedDecimals):
            adapter(feed_decimals=d)
    assert adapter(feed_decimals=18).feed_decimals == 18
    assert adapter(feed_decimals=0).feed_decimals == 0


def test_failure_clock_and_events_follow_the_contract() -> None:
    a = adapter()
    up = o.FeedRound(0, 1, 1)
    now = 10_000_000
    good = o.FeedRound(2_000 * 10**8, now - 60, now - 60)
    assert a.fetch_price(now, reader(up), reader(good)) == (2_000 * 10**18, True)
    assert a.fetch_price(now, reader(up), reader(good)) == (2_000 * 10**18, True)
    stale = o.FeedRound(2_000 * 10**8, now - 3_601, now - 3_601)
    assert a.fetch_price(now, reader(up), reader(stale)) == (2_000 * 10**18, False)
    down = o.FeedRound(1, now, now)
    assert a.fetch_price(now + 500, reader(down), reader(good)) == (2_000 * 10**18, False)
    assert a.failure_start == now
    assert a.fetch_price(now + 600, reader(up), reader(good)) == (2_000 * 10**18, True)
    assert a.events == [
        ("LastGoodPriceUpdated", 2_000 * 10**18),
        ("OracleFailure", int(o.Reason.STALE), now),
        ("OracleRecovered", now + 600),
    ]


I256 = st.integers(min_value=-(2**255), max_value=2**255 - 1)
U64 = st.integers(min_value=1, max_value=2**64 - 1)


@given(
    seq_answer=I256,
    started_at=st.integers(min_value=0, max_value=2**256 - 1),
    answer=I256,
    updated_at=st.integers(min_value=0, max_value=2**256 - 1),
    now=U64,
    decimals=st.integers(min_value=0, max_value=18),
)
def test_peek_and_fetch_price_agree_and_peek_writes_nothing(
    seq_answer: int, started_at: int, answer: int, updated_at: int, now: int, decimals: int
) -> None:
    a = adapter(feed_decimals=decimals)
    seq, feed = (
        o.FeedRound(seq_answer, started_at, started_at),
        o.FeedRound(answer, updated_at, updated_at),
    )
    p, u, r = a.peek(now, reader(seq), reader(feed))
    assert (a.last_good_price, a.failure_start, a.events) == (0, 0, [])
    fp, fu = a.fetch_price(now, reader(seq), reader(feed))
    assert (fp, fu) == (p, u)
    assert (r == o.Reason.OK) is u
    if u:
        assert START["min_price"] <= p <= START["max_price"]
