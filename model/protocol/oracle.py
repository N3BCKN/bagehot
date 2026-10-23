"""OracleAdapter's decision and failure clock, bit-for-bit with the Solidity contract.

Mirrors `contracts/src/core/OracleAdapter.sol`.

Spec §4.8, §5.7, §6.10. Integers only (python-model skill). A feed read is either a `FeedRound`
or `None` — `None` is a *failed call* (reverted, ran out of gas, or returned fewer than 160 bytes).
The gas rule (§6.10.3) is a property of the EVM call and is tested in Foundry only; the model has
no gas, so it never raises `InsufficientGasForOracle`.

Reason codes are ABI values (spec §11.1) and must equal the Solidity enum by *value*:
`tests/model/test_oracle_model.py` and `OracleAdapterTest.test_reasonCodes_matchTheSpecByValue`
each assert the same literal table.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from enum import IntEnum

UINT256_MAX = 2**256 - 1


class Reason(IntEnum):
    OK = 0
    SEQUENCER_CALL_FAILED = 1
    SEQUENCER_DOWN = 2
    SEQUENCER_INVALID = 3
    GRACE_PERIOD = 4
    PRICE_CALL_FAILED = 5
    NON_POSITIVE = 6
    INVALID_TIMESTAMP = 7
    STALE = 8
    OUT_OF_BOUNDS = 9


class InvalidParameter(Exception):  # noqa: N818 — the spec's error name
    """Constructor argument out of range (spec §3.4); `index` is the 0-based argument position."""

    def __init__(self, index: int) -> None:
        super().__init__(index)
        self.index = index


class InvalidFeedDecimals(Exception):  # noqa: N818 — the spec's error name
    """`priceFeed.decimals()` failed or exceeds 18."""


@dataclass(frozen=True)
class FeedRound:
    """The three words of `latestRoundData()` the adapter reads (words 1–3, full 256-bit)."""

    answer: int
    started_at: int
    updated_at: int


FeedRead = Callable[[], FeedRound | None]


@dataclass
class OracleAdapter:
    """Mirrors the contract: immutables, `last_good_price`, `failure_start`, and its events."""

    staleness: int
    grace_period: int
    min_price: int
    max_price: int
    oracle_gas: int
    oracle_post_failure_gas: int
    feed_decimals: int
    last_good_price: int = 0
    failure_start: int = 0
    events: list[tuple] = field(default_factory=list)

    @classmethod
    def deploy(
        cls,
        *,
        price_feed: int,
        sequencer_feed: int,
        staleness: int,
        grace_period: int,
        min_price: int,
        max_price: int,
        oracle_gas: int,
        oracle_post_failure_gas: int,
        feed_decimals: int | None,
    ) -> OracleAdapter:
        """Constructor checks in argument order, first failure wins (§3.4); then decimals.

        Feeds are given as addresses (ints, 0 = zero address); `feed_decimals` is what
        `decimals()` returned, or `None` for a failed call.
        """
        if price_feed == 0:
            raise InvalidParameter(0)
        if sequencer_feed == 0:
            raise InvalidParameter(1)
        if staleness == 0:
            raise InvalidParameter(2)
        if min_price < 2 * 10**18:
            raise InvalidParameter(4)
        if max_price <= min_price or max_price > 10**30:
            raise InvalidParameter(5)
        if not 50_000 <= oracle_gas <= 1_000_000:
            raise InvalidParameter(6)
        if oracle_post_failure_gas < -(-oracle_gas // 63):  # ceil(oracle_gas / 63)
            raise InvalidParameter(7)
        if feed_decimals is None or feed_decimals > 18:
            raise InvalidFeedDecimals()
        return cls(
            staleness,
            grace_period,
            min_price,
            max_price,
            oracle_gas,
            oracle_post_failure_gas,
            feed_decimals,
        )

    @property
    def _scale(self) -> int:
        return 10 ** (18 - self.feed_decimals)

    @property
    def _max_answer(self) -> int:
        return self.max_price // self._scale  # floor (Rounding.mulDivDown(MAX_PRICE, 1, scale))

    def decide(
        self, now: int, read_sequencer: FeedRead, read_price: FeedRead
    ) -> tuple[bool, int, Reason]:
        """§6.10.1, first matching row wins; reads the price feed only if rows 1–4 don't decide."""
        seq = read_sequencer()
        if seq is None:
            return False, 0, Reason.SEQUENCER_CALL_FAILED
        if seq.answer != 0:
            return False, 0, Reason.SEQUENCER_DOWN
        if seq.started_at == 0 or seq.started_at > now:
            return False, 0, Reason.SEQUENCER_INVALID
        if now - seq.started_at <= self.grace_period:
            return False, 0, Reason.GRACE_PERIOD
        feed = read_price()
        if feed is None:
            return False, 0, Reason.PRICE_CALL_FAILED
        if feed.answer <= 0:
            return False, 0, Reason.NON_POSITIVE
        if feed.updated_at == 0 or feed.updated_at > now:
            return False, 0, Reason.INVALID_TIMESTAMP
        if now - feed.updated_at > self.staleness:
            return False, 0, Reason.STALE
        if feed.answer > self._max_answer:
            return False, 0, Reason.OUT_OF_BOUNDS
        price = feed.answer * self._scale
        if price < self.min_price:
            return False, 0, Reason.OUT_OF_BOUNDS
        return True, price, Reason.OK

    def peek(
        self, now: int, read_sequencer: FeedRead, read_price: FeedRead
    ) -> tuple[int, bool, Reason]:
        """`peek()`: the decision, no writes; `price = last_good_price` when not usable."""
        usable, price, reason = self.decide(now, read_sequencer, read_price)
        return (price if usable else self.last_good_price), usable, reason

    def fetch_price(
        self, now: int, read_sequencer: FeedRead, read_price: FeedRead
    ) -> tuple[int, bool]:
        """`fetchPrice()` (§6.10.2): records the decision; events only on each transition."""
        usable, price, reason = self.decide(now, read_sequencer, read_price)
        if usable:
            if price != self.last_good_price:
                self.last_good_price = price
                self.events.append(("LastGoodPriceUpdated", price))
            if self.failure_start != 0:
                self.failure_start = 0
                self.events.append(("OracleRecovered", now))
            return price, True
        if self.failure_start == 0:
            self.failure_start = now
            self.events.append(("OracleFailure", int(reason), now))
        return self.last_good_price, False
