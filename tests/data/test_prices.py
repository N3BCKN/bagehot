"""P06 price pipeline: planning, parsing, resume, processing and validation.

Everything here runs offline against recorded fixtures in `data/tests/fixtures/` (data-pipeline
skill). The single live check is marked `network` and is excluded from `just py-test`.
"""

from __future__ import annotations

import gzip
import json
from datetime import UTC, datetime
from pathlib import Path

import pandas as pd
import pytest

from data import fetch_prices as fp
from data import process_prices as pp
from data import validate as val
from data.sources import BITSTAMP, COINBASE, MINUTE, Candle

FIXTURES = Path("data/tests/fixtures")


def ts(text: str) -> int:
    """`2024-08-05T00:00:00Z` as UTC seconds."""
    return int(datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp())


# --------------------------------------------------------------------------- chunk planning
def test_month_windows_cover_the_range_exactly_and_do_not_overlap():
    start, end = fp.parse_day("2019-11-01"), fp.parse_day("2020-03-01")
    windows = fp.month_windows(start, end)

    assert [fp.month_key(w.start) for w in windows] == ["2019-11", "2019-12", "2020-01", "2020-02"]
    assert windows[0].start == start and windows[-1].end == end
    for earlier, later in zip(windows[:-1], windows[1:], strict=True):
        assert earlier.end == later.start  # no gap, no overlap
    # February 2020 is a leap February: 29 days of minutes.
    assert windows[-1].minutes == 29 * 24 * 60


def test_month_windows_clip_to_a_partial_month():
    windows = fp.month_windows(fp.parse_day("2021-05-10"), fp.parse_day("2021-05-20"))
    assert len(windows) == 1
    assert windows[0].minutes == 10 * 24 * 60


def test_page_windows_are_page_sized_with_a_short_last_page():
    month = fp.Window(fp.parse_day("2019-01-01"), fp.parse_day("2019-02-01"))
    pages = list(fp.page_windows(month, 300))

    assert all(p.minutes == 300 for p in pages[:-1])
    assert pages[-1].minutes == month.minutes - 300 * (len(pages) - 1)
    assert pages[0].start == month.start and pages[-1].end == month.end
    assert sum(p.minutes for p in pages) == month.minutes


def test_plan_counts_requests_per_month():
    start, end = fp.parse_day("2019-01-01"), fp.parse_day("2019-03-01")
    counted = fp.plan(COINBASE, start, end)
    assert [n for _, n in counted] == [149, 135]  # 31 and 28 days at 300 minutes a request


def test_last_complete_month_end_is_the_first_second_of_this_month():
    now = datetime(2026, 10, 22, 13, 45, tzinfo=UTC)
    assert fp.last_complete_month_end(now) == fp.parse_day("2026-10-01")


# --------------------------------------------------------------------------- request building
def test_coinbase_window_asks_for_an_inclusive_range_of_300_candles():
    start = ts("2024-08-05T00:00:00Z")
    params = COINBASE.params(start, start + 300 * MINUTE)
    assert params["granularity"] == 60
    assert params["start"] == "2024-08-05T00:00:00Z"
    # Both ends are inclusive at Coinbase, so the last candle we want opens one minute early.
    assert params["end"] == "2024-08-05T04:59:00Z"


def test_bitstamp_window_uses_end_and_limit_because_end_wins_over_start():
    start = ts("2024-08-05T00:00:00Z")
    params = BITSTAMP.params(start, start + 1000 * MINUTE)
    assert params == {
        "step": 60,
        "limit": 1000,
        "end": start + 999 * MINUTE,
        "exclude_current_candle": "true",
    }


# --------------------------------------------------------------------------- parsing
def test_coinbase_fixture_parses_newest_first_into_ascending_candles():
    payload = json.loads((FIXTURES / "coinbase_candles_20240805.json").read_text())
    assert payload[0][0] > payload[-1][0], "fixture should still be newest-first"

    candles = COINBASE.parse(payload)

    assert [c.ts for c in candles] == sorted(c.ts for c in candles)
    assert all(c.ts % MINUTE == 0 for c in candles)
    # Element order is [time, low, high, open, close, volume]: check against the raw row.
    newest_raw = payload[0]
    newest = candles[-1]
    assert newest.ts == newest_raw[0]
    assert (newest.low, newest.high, newest.open, newest.close, newest.volume) == tuple(
        newest_raw[1:]
    )
    assert all(c.low <= c.open <= c.high and c.low <= c.close <= c.high for c in candles)


def test_bitstamp_fixture_parses_strings_into_numbers():
    payload = json.loads((FIXTURES / "bitstamp_ohlc_20240805.json").read_text())
    raw = payload["data"]["ohlc"]
    assert isinstance(raw[0]["timestamp"], str), "fixture should still carry string fields"

    candles = BITSTAMP.parse(payload)

    assert [c.ts for c in candles] == sorted(c.ts for c in candles)
    assert all(isinstance(c.ts, int) and isinstance(c.close, float) for c in candles)
    assert candles[0].ts == int(raw[0]["timestamp"])
    assert candles[0].close == float(raw[0]["close"])


def test_the_two_fixtures_describe_the_same_minutes():
    """Both were recorded for 2024-08-05 00:00 UTC: a sanity check on timestamp semantics."""
    cb = COINBASE.parse(json.loads((FIXTURES / "coinbase_candles_20240805.json").read_text()))
    bs = BITSTAMP.parse(json.loads((FIXTURES / "bitstamp_ohlc_20240805.json").read_text()))
    assert bs[0].ts == ts("2024-08-05T00:00:00Z")
    assert cb[-1].ts == ts("2024-08-05T04:59:00Z")  # newest of the 300-minute page


# --------------------------------------------------------------------------- fetching, resume
class FakeApi:
    """Serves synthetic candles and counts requests, so resume logic can be tested offline."""

    def __init__(self, source):
        self.source = source
        self.calls = 0

    def __call__(self, client, url, params, *, limiter, **kwargs):
        self.calls += 1
        if self.source is COINBASE:
            start = ts(params["start"])
            end = ts(params["end"]) + MINUTE
            return [
                [t, 10.0, 12.0, 11.0, 11.5, 1.0]
                for t in range(end - MINUTE, start - MINUTE, -MINUTE)
            ]
        end = params["end"]
        start = end - (params["limit"] - 1) * MINUTE
        return {
            "data": {
                "pair": "ETH/USD",
                "ohlc": [
                    {
                        "timestamp": str(t),
                        "open": "11.0",
                        "high": "12.0",
                        "low": "10.0",
                        "close": "11.5",
                        "volume": "1.0",
                    }
                    for t in range(start, end + MINUTE, MINUTE)
                ],
            }
        }


@pytest.fixture
def raw_root(tmp_path: Path) -> Path:
    return tmp_path / "raw"


def test_fetch_writes_pages_with_their_request_and_a_checked_meta(raw_root: Path):
    api = FakeApi(COINBASE)
    start, end = fp.parse_day("2019-01-01"), fp.parse_day("2019-01-02")

    result = fp.fetch_source(COINBASE, start, end, fetch=api, client=object(), root=raw_root)

    assert result["sent"] == api.calls == 5  # 1440 minutes / 300, rounded up
    data_path, meta_path = fp.month_paths(COINBASE, "2019-01", root=raw_root)
    with gzip.open(data_path, "rt") as handle:
        pages = [json.loads(line) for line in handle]
    assert len(pages) == 5
    assert pages[0]["params"]["granularity"] == 60  # the request is stored with its reply
    assert pages[0]["url"] == COINBASE.url

    meta = json.loads(meta_path.read_text())
    assert meta["rows"] == 1440 and meta["complete"] is True
    assert meta["sha256"] == fp.sha256_file(data_path)
    assert meta["window_start"] == start and meta["window_end"] == end


def test_second_run_over_the_same_range_sends_nothing_and_rewrites_nothing(raw_root: Path):
    start, end = fp.parse_day("2019-01-01"), fp.parse_day("2019-01-02")
    first = FakeApi(COINBASE)
    fp.fetch_source(COINBASE, start, end, fetch=first, client=object(), root=raw_root)
    data_path, _ = fp.month_paths(COINBASE, "2019-01", root=raw_root)
    before = (data_path.read_bytes(), data_path.stat().st_mtime_ns)

    second = FakeApi(COINBASE)
    result = fp.fetch_source(COINBASE, start, end, fetch=second, client=object(), root=raw_root)

    assert second.calls == 0 and result["sent"] == 0
    assert (data_path.read_bytes(), data_path.stat().st_mtime_ns) == before


def test_a_partial_month_is_refetched_when_the_full_month_is_asked_for(raw_root: Path):
    """A `--start/--end` run must not mark a half-filled month as done for ever."""
    partial = FakeApi(COINBASE)
    fp.fetch_source(
        COINBASE,
        fp.parse_day("2019-01-01"),
        fp.parse_day("2019-01-02"),
        fetch=partial,
        client=object(),
        root=raw_root,
    )

    full = FakeApi(COINBASE)
    fp.fetch_source(
        COINBASE,
        fp.parse_day("2019-01-01"),
        fp.parse_day("2019-02-01"),
        fetch=full,
        client=object(),
        root=raw_root,
    )

    assert full.calls == 149  # the whole month, not the 144 pages still missing
    meta = json.loads(fp.month_paths(COINBASE, "2019-01", root=raw_root)[1].read_text())
    assert meta["window_end"] == fp.parse_day("2019-02-01")
    assert meta["rows"] == 31 * 24 * 60


def test_a_truncated_raw_file_is_not_treated_as_complete(raw_root: Path):
    start, end = fp.parse_day("2019-01-01"), fp.parse_day("2019-01-02")
    fp.fetch_source(COINBASE, start, end, fetch=FakeApi(COINBASE), client=object(), root=raw_root)
    data_path, _ = fp.month_paths(COINBASE, "2019-01", root=raw_root)
    data_path.write_bytes(data_path.read_bytes()[:-20])  # a half-written file

    again = FakeApi(COINBASE)
    fp.fetch_source(COINBASE, start, end, fetch=again, client=object(), root=raw_root)
    assert again.calls == 5


def test_dry_run_sends_no_requests_and_reports_the_budget(raw_root: Path, capsys):
    api = FakeApi(COINBASE)
    result = fp.fetch_source(
        COINBASE,
        fp.parse_day("2019-01-01"),
        fp.parse_day("2019-03-01"),
        fetch=api,
        client=object(),
        dry_run=True,
        root=raw_root,
    )
    assert api.calls == 0 and result["sent"] == 0 and result["pending"] == 284
    assert "284 requests to send" in capsys.readouterr().out


def test_a_budget_over_the_limit_stops_instead_of_fetching(raw_root: Path):
    api = FakeApi(COINBASE)
    with pytest.raises(SystemExit, match="stop and ask the human"):
        fp.fetch_source(
            COINBASE,
            fp.parse_day("2019-01-01"),
            fp.parse_day("2020-01-01"),
            fetch=api,
            client=object(),
            ask_above=100,
            root=raw_root,
        )
    assert api.calls == 0


def test_bitstamp_pages_a_month_at_its_own_size(raw_root: Path):
    api = FakeApi(BITSTAMP)
    result = fp.fetch_source(
        BITSTAMP,
        fp.parse_day("2019-01-01"),
        fp.parse_day("2019-02-01"),
        fetch=api,
        client=object(),
        root=raw_root,
    )
    assert result["sent"] == 45  # 44640 minutes / 1000, rounded up
    meta = json.loads(fp.month_paths(BITSTAMP, "2019-01", root=raw_root)[1].read_text())
    assert meta["rows"] == 31 * 24 * 60


# --------------------------------------------------------------------------- processing
def make_candles(start: int, closes: list[float], volumes: list[float] | None = None):
    volumes = volumes if volumes is not None else [1.0] * len(closes)
    return [
        Candle(start + i * MINUTE, c, c, c, c, v)
        for i, (c, v) in enumerate(zip(closes, volumes, strict=True))
    ]


def test_processing_keeps_gaps_and_zero_volume_minutes():
    start = ts("2024-08-05T00:00:00Z")
    kept = make_candles(start, [10.0, 11.0], volumes=[1.0, 0.0])
    after_gap = make_candles(start + 5 * MINUTE, [12.0])
    frame, report = pp.candles_to_frame(kept + after_gap, COINBASE)

    assert list(frame["ts"]) == [start, start + MINUTE, start + 5 * MINUTE]
    assert report["rows_out"] == 3
    # The zero-volume minute survives as a row; the missing minutes stay missing.
    assert list(frame["volume"]) == [1.0, 0.0, 1.0]
    assert frame["ts"].diff().iloc[2] == 4 * MINUTE


def test_padded_no_trade_bars_become_gaps_for_venues_that_emit_them():
    """Bitstamp returns a zero-volume bar at the previous close for every no-trade minute."""
    start = ts("2024-08-05T00:00:00Z")
    candles = make_candles(start, [10.0, 10.0, 10.0, 11.0], volumes=[1.0, 0.0, 0.0, 2.0])

    padded, report = pp.candles_to_frame(candles, BITSTAMP)
    kept, _ = pp.candles_to_frame(candles, COINBASE)

    assert list(padded["ts"]) == [start, start + 3 * MINUTE]  # the two padded minutes are gaps
    assert report["empty_minutes_dropped"] == 2
    assert len(kept) == 4  # a venue that does not pad keeps a real zero-volume row as a row


def test_processing_deduplicates_overlapping_pages_and_counts_conflicts():
    start = ts("2024-08-05T00:00:00Z")
    original = make_candles(start, [10.0, 11.0])
    repeat_same = make_candles(start, [10.0, 11.0])
    revised = [Candle(start + MINUTE, 11.0, 11.0, 11.0, 99.0, 1.0)]

    frame, report = pp.candles_to_frame(original + repeat_same + revised, COINBASE)

    assert report["rows_in"] == 5 and report["rows_out"] == 2
    assert report["duplicate_rows"] == 3
    assert report["conflicting_duplicates"] == 1
    assert frame.loc[frame["ts"] == start + MINUTE, "close"].item() == 99.0  # last write wins


def test_processing_rejects_timestamps_that_are_not_minute_aligned():
    bad = [Candle(ts("2024-08-05T00:00:00Z") + 7, 1.0, 1.0, 1.0, 1.0, 1.0)]
    with pytest.raises(ValueError, match="not minute-aligned"):
        pp.candles_to_frame(bad, COINBASE)


def test_parquet_round_trip_has_the_declared_schema(tmp_path: Path):
    frame, _ = pp.candles_to_frame(make_candles(ts("2024-08-05T00:00:00Z"), [10.0, 11.0]), COINBASE)
    path = tmp_path / "prices.parquet"
    digest = pp.write_parquet(frame, path)

    back = pd.read_parquet(path)
    assert len(digest) == 64
    assert str(back["ts"].dtype) == "int64"
    assert all(str(back[c].dtype) == "float64" for c in ("open", "high", "low", "close", "volume"))
    assert set(back["source"]) == {"coinbase"}
    assert list(back.columns) == [f.name for f in pp.SCHEMA]


def test_build_reads_every_stored_page(raw_root: Path):
    fp.fetch_source(
        COINBASE,
        fp.parse_day("2019-01-01"),
        fp.parse_day("2019-01-02"),
        fetch=FakeApi(COINBASE),
        client=object(),
        root=raw_root,
    )
    frame, report = pp.build(COINBASE, root=raw_root)
    assert report["pages"] == 5
    assert len(frame) == 1440
    assert frame["ts"].is_monotonic_increasing


# --------------------------------------------------------------------------- validation
def frame_from(start: int, closes: list[float], source: str = "coinbase", step: int = MINUTE):
    return pd.DataFrame(
        {
            "ts": [start + i * step for i in range(len(closes))],
            "open": closes,
            "high": closes,
            "low": closes,
            "close": closes,
            "volume": [1.0] * len(closes),
            "source": source,
        }
    )


def test_find_gaps_reports_each_hole_with_its_duration():
    start = ts("2024-08-05T00:00:00Z")
    series = pd.Series([start, start + MINUTE, start + 10 * MINUTE, start + 11 * MINUTE])
    gaps = val.find_gaps(series)

    assert len(gaps) == 1
    assert gaps[0].start == start + MINUTE
    assert gaps[0].end == start + 10 * MINUTE
    assert gaps[0].minutes == 8


def test_find_gaps_is_empty_on_a_contiguous_series():
    start = ts("2024-08-05T00:00:00Z")
    assert val.find_gaps(pd.Series([start + i * MINUTE for i in range(50)])) == []


def test_outlier_flagging_catches_a_spike_and_spares_the_quiet_minutes():
    start = ts("2024-08-05T00:00:00Z")
    closes = [100.0 + (i % 2) * 0.05 for i in range(2000)]
    closes[1500] = 160.0  # a 60% minute
    frame = frame_from(start, closes)

    returns, flagged = val.flag_outliers(frame, k=8.0, window=1440)

    assert bool(flagged.iloc[1500])
    assert returns.iloc[1500] > 0.4
    assert flagged.sum() < 10  # the ordinary minutes are not flagged


def test_outliers_are_not_computed_across_a_gap():
    start = ts("2024-08-05T00:00:00Z")
    frame = pd.concat(
        [frame_from(start, [100.0] * 800), frame_from(start + 5000 * MINUTE, [150.0] * 800)],
        ignore_index=True,
    )
    returns, _ = val.flag_outliers(frame, k=8.0, window=400)
    assert pd.isna(returns.iloc[800])  # the step across the gap is not a return


def test_divergence_uses_only_shared_minutes():
    start = ts("2024-08-05T00:00:00Z")
    a = frame_from(start, [100.0, 100.0, 100.0])
    b = frame_from(start, [100.0, 101.0])  # one minute short, one minute 1% apart

    d = val.divergence(a, b)

    assert d["minutes"] == 2
    assert d["max_bps"] == pytest.approx(99.0099, rel=1e-3)
    assert d["max_at"] == "2024-08-05T00:01:00Z"


def test_divergence_handles_no_overlap():
    a = frame_from(ts("2024-08-05T00:00:00Z"), [100.0])
    b = frame_from(ts("2024-08-06T00:00:00Z"), [100.0])
    assert val.divergence(a, b) == {"minutes": 0}


def test_stress_windows_slice_on_utc_day_boundaries():
    start = ts("2020-03-11T23:58:00Z")
    frame = frame_from(start, [100.0] * 10)
    inside = val.slice_window(frame, *val.STRESS_WINDOWS["2020-03-12/13 covid crash"])
    assert list(inside["ts"]) == [start + i * MINUTE for i in range(2, 10)]


def test_card_checksum_mismatch_is_detected(tmp_path: Path, monkeypatch):
    processed = tmp_path / "prices_coinbase_1m.parquet"
    processed.write_bytes(b"not really parquet")
    cards = tmp_path / "cards"
    cards.mkdir()
    (cards / "prices_coinbase.md").write_text("| sha256 | `" + "0" * 64 + "` |\n")
    monkeypatch.setattr(val, "CARD_ROOT", cards)
    monkeypatch.setattr(val, "processed_path", lambda source: processed)

    ok, detail = val.card_checksum_ok(COINBASE)
    assert ok is False and "file" in detail


# --------------------------------------------------------------------------- live smoke test
@pytest.mark.network
def test_both_venues_still_answer_the_documented_way():
    from data.http import RateLimiter, get_json, make_client

    limiter = RateLimiter(rps=2)
    start = ts("2024-08-05T00:00:00Z")
    with make_client() as client:
        for source, size in ((COINBASE, 300), (BITSTAMP, 1000)):
            payload = get_json(
                client, source.url, source.params(start, start + size * MINUTE), limiter=limiter
            )
            candles = source.parse(payload)
            assert len(candles) == size
            assert candles[0].ts == start
            assert candles[-1].ts == start + (size - 1) * MINUTE
