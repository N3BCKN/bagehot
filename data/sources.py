"""Price-source adapters: how to ask each venue for one-minute candles, and how to read the reply.

Every adapter is pure apart from `endpoint`/`params`: the fetcher does the I/O, the adapter only
plans windows and parses pages. That is what lets the tests run against recorded fixtures with no
network (data-pipeline skill).

Quote currency is part of the adapter and travels with every row. USD series and the USDT series
are never mixed: `validate.py` compares only sources whose `quote` matches.

Documentation consulted 2026-10-22 (cited again in each data card):
  Coinbase Exchange, Get product candles —
    https://docs.cdp.coinbase.com/exchange/reference/exchangerestapi_getproductcandles
    granularity 60 allowed; at most 300 candles per request; `start`/`end` bound the range.
  Bitstamp HTTP API v2, OHLC data — https://www.bitstamp.net/api/
    step 60 allowed; limit 1..1000; `start`/`end` are Unix seconds and "if both are given, the
    end timestamp will be used"; `exclude_current_candle` drops the open candle.
  Binance Spot, Klines — https://developers.binance.com/docs/binance-spot-api-docs/rest-api
    interval 1m; limit up to 1000; `startTime`/`endTime` in milliseconds.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

MINUTE = 60


def iso_utc(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass(frozen=True)
class Candle:
    """One minute of trading. `ts` is the candle's **open** time, UTC seconds, aligned to 60."""

    ts: int
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class Source:
    name: str
    venue: str
    symbol: str
    quote: str  # "USD" or "USDT" — never compared across values
    url: str
    max_candles: int
    doc_url: str
    terms_url: str
    # True for venues that return a candle for every minute, filling no-trade minutes with a
    # zero-volume bar at the previous close. Those bars carry no trade, so processing turns them
    # back into gaps instead of storing a forward-filled price (P06: never forward-fill).
    emits_empty_minutes: bool = False

    def params(self, start: int, end: int) -> dict[str, Any]:
        """Query parameters for the window [start, end), both UTC seconds, end exclusive."""
        raise NotImplementedError

    def parse(self, payload: Any) -> list[Candle]:
        """Rows from one response, ascending by `ts`. Order in the payload is never trusted."""
        raise NotImplementedError


class Coinbase(Source):
    def params(self, start: int, end: int) -> dict[str, Any]:
        # Coinbase treats both ends as inclusive, so the last candle we want opens at end - 60.
        return {
            "granularity": MINUTE,
            "start": iso_utc(start),
            "end": iso_utc(end - MINUTE),
        }

    def parse(self, payload: Any) -> list[Candle]:
        # Documented element order: [time, low, high, open, close, volume]. The endpoint page does
        # not state the sort order (it is newest-first in practice), so we sort ourselves.
        out = [
            Candle(
                ts=int(row[0]),
                low=float(row[1]),
                high=float(row[2]),
                open=float(row[3]),
                close=float(row[4]),
                volume=float(row[5]),
            )
            for row in payload
        ]
        return sorted(out, key=lambda c: c.ts)


class Bitstamp(Source):
    def params(self, start: int, end: int) -> dict[str, Any]:
        # The docs say that when start and end are both given, end wins — so we ask only for a
        # window ending at `end` and sized by `limit`, which is deterministic.
        return {
            "step": MINUTE,
            "limit": (end - start) // MINUTE,
            "end": end - MINUTE,
            "exclude_current_candle": "true",
        }

    def parse(self, payload: Any) -> list[Candle]:
        rows = payload["data"]["ohlc"]
        out = [
            Candle(
                ts=int(row["timestamp"]),
                open=float(row["open"]),
                high=float(row["high"]),
                low=float(row["low"]),
                close=float(row["close"]),
                volume=float(row["volume"]),
            )
            for row in rows
        ]
        return sorted(out, key=lambda c: c.ts)


class BinanceUsdt(Source):
    def params(self, start: int, end: int) -> dict[str, Any]:
        return {
            "symbol": self.symbol,
            "interval": "1m",
            "startTime": start * 1000,
            "endTime": (end - MINUTE) * 1000,
            "limit": self.max_candles,
        }

    def parse(self, payload: Any) -> list[Candle]:
        out = [
            Candle(
                ts=int(row[0]) // 1000,
                open=float(row[1]),
                high=float(row[2]),
                low=float(row[3]),
                close=float(row[4]),
                volume=float(row[5]),
            )
            for row in payload
        ]
        return sorted(out, key=lambda c: c.ts)


COINBASE = Coinbase(
    name="coinbase",
    venue="Coinbase Exchange",
    symbol="ETH-USD",
    quote="USD",
    url="https://api.exchange.coinbase.com/products/ETH-USD/candles",
    max_candles=300,
    doc_url="https://docs.cdp.coinbase.com/exchange/reference/exchangerestapi_getproductcandles",
    terms_url="https://www.coinbase.com/legal/market_data",
)

BITSTAMP = Bitstamp(
    name="bitstamp",
    venue="Bitstamp",
    symbol="ethusd",
    quote="USD",
    url="https://www.bitstamp.net/api/v2/ohlc/ethusd/",
    max_candles=1000,
    doc_url="https://www.bitstamp.net/api/",
    terms_url="https://www.bitstamp.net/terms-of-use/",
    emits_empty_minutes=True,
)

# Third series, opt-in only, and labelled USDT. Never merged with the USD sources: an ETHUSDT
# print is a price in tethers, and during a tether depeg that is a different number (kit
# correction 7).
BINANCE_USDT = BinanceUsdt(
    name="binance_usdt",
    venue="Binance Spot",
    symbol="ETHUSDT",
    quote="USDT",
    url="https://api.binance.com/api/v3/klines",
    max_candles=1000,
    doc_url="https://developers.binance.com/docs/binance-spot-api-docs/rest-api",
    terms_url="https://www.binance.com/en/terms",
)

SOURCES: dict[str, Source] = {s.name: s for s in (COINBASE, BITSTAMP, BINANCE_USDT)}

# What `just data` fetches. Binance stays out until someone asks for it by name.
DEFAULT_SOURCES = ("coinbase", "bitstamp")
