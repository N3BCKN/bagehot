"""Hypothesis state machine over the whole deployment-A `System` (P22).

Random operations by a few actors — every external entry point, price moves, time jumps, oracle
failures, donations, and a rare shutdown and settlement through the stand-in hooks — with
`check_invariants()` after every step and I8's unwind at the end of each run. Reverts are allowed:
whether a revert was legitimate is itself judged by I9, I12 and I15 on the recorded step.

Profiles: `TestSystemQuick` (100 runs) runs in `just py-test`; `TestSystemNightly` (2,000 runs) is
marked slow.
"""

from __future__ import annotations

import contextlib

import pytest
from hypothesis import HealthCheck, settings
from hypothesis import strategies as st
from hypothesis.stateful import (
    RuleBasedStateMachine,
    initialize,
    invariant,
    precondition,
    rule,
)

from model.protocol.errors import ProtocolError
from model.protocol.math import WAD
from model.protocol.oracle_adapter import FeedRound
from model.protocol.system import System

ACTORS = ("alice", "bob", "carol", "dave")
CORE = ("vault", "pool", "ledger", "redemption", "shutdown")
FEED = 10**10  # one feed unit (8 decimals) in WAD
MIN_DEBT = 2_000 * WAD
actor = st.sampled_from(ACTORS)
wild = st.one_of(st.integers(0, 3), st.integers(1, 10**24))  # arguments drawn blind


class SystemMachine(RuleBasedStateMachine):
    """Arguments are mostly drawn from the current state (an active id, its owner, an amount the
    caller can afford) so that runs go deep — liquidations, redemptions, pool offsets — and
    sometimes blind, so that the revert paths are exercised too."""

    def __init__(self) -> None:
        super().__init__()
        self.s = System(record=True)
        self.now = self.s.now
        self.price = 2_000 * WAD
        self.s.set_price(self.price, self.now)
        for a in ACTORS:
            self.s.fund(a, 10**24)

    @initialize(data=st.data())
    def start(self, data) -> None:  # noqa: ANN001
        for who in ACTORS[: data.draw(st.integers(1, 4))]:
            self.open(data, who)
        for who in ACTORS:  # mostly a funded pool, often deep enough to absorb a whole debt
            if self.s.token.balance_of(who) and data.draw(st.integers(0, 3)):
                share = data.draw(st.integers(30, 100))
                self._do(self.s.deposit, who, self.s.token.balance_of(who) * share // 100)

    # ---- helpers ----
    def _do(self, fn, *args, **kw) -> None:  # noqa: ANN001
        with contextlib.suppress(ProtocolError):  # reverts are judged by I9, I12 and I15
            fn(*args, now=self.now, **kw)

    def _pid(self, data) -> int:  # noqa: ANN001
        v = self.s.vault
        active = [i for i, q in v.positions.items() if q.status == 1]
        pool = active if active and data.draw(st.integers(0, 9)) else list(v.positions) or [1]
        return data.draw(st.sampled_from(pool))

    def _caller(self, data, pid: int) -> str:  # noqa: ANN001
        q = self.s.vault.positions.get(pid)
        if q is not None and data.draw(st.integers(0, 9)):
            return q.owner
        return data.draw(actor)

    def _holder(self, data) -> str:  # noqa: ANN001
        """Mostly the actor with the most stablecoin, so pool and redemption calls can pay."""
        if data.draw(st.integers(0, 4)):
            return max(ACTORS, key=self.s.token.balance_of)
        return data.draw(actor)

    def _upto(self, data, top: int) -> int:  # noqa: ANN001
        if data.draw(st.integers(0, 9)) == 0:
            return data.draw(wild)
        return data.draw(st.integers(1, max(1, top)))

    # ---- environment ----
    @rule(dt=st.one_of(st.integers(0, 600), st.integers(601, 86_400)), refresh=st.integers(0, 9))
    def advance(self, dt: int, refresh: int) -> None:
        self.now += dt
        if refresh:  # the feed posts a fresh round; sometimes it is left to go stale
            self.s.set_price(self.price, self.now)

    @rule(pct=st.integers(70, 130), odd=st.integers(0, FEED - 1))
    def move_price(self, pct: int, odd: int) -> None:
        # a price finer than the feed is truncated, as in the Foundry harness
        self.price = min(max(self.price * pct // 100 + odd, 100 * WAD), 100_000 * WAD)
        self.s.set_price(self.price, self.now)

    @rule(pct=st.integers(50, 85))
    def crash(self, pct: int) -> None:
        """A sharp fall, so that positions go under MCR and liquidations happen."""
        self.price = max(self.price * pct // 100, 100 * WAD)
        self.s.set_price(self.price, self.now)

    @rule(mode=st.sampled_from(["seq_down", "seq_fail", "feed_fail", "negative", *["ok"] * 4]))
    def oracle_mode(self, mode: str) -> None:
        s = self.s
        if mode == "seq_down":
            s.set_sequencer(FeedRound(1, 1, 1))
        elif mode == "seq_fail":
            s.set_sequencer(None)
        elif mode == "feed_fail":
            s.set_feed(None)
        elif mode == "negative":
            s.set_feed(FeedRound(-1, self.now, self.now))
        else:
            s.set_sequencer(FeedRound(0, 1, 1))
            s.set_price(self.price, self.now)

    # ---- VaultManager ----
    @rule(data=st.data(), who=actor)
    def open(self, data, who: str) -> None:  # noqa: ANN001
        if data.draw(st.integers(0, 9)) == 0:
            coll, debt = data.draw(wild), data.draw(wild)
        else:
            debt = data.draw(st.integers(MIN_DEBT, 30_000 * WAD))
            icr = data.draw(st.integers(108, 300))  # percent; a few below MCR on purpose
            coll = -(-debt * icr // (100 * self.price)) * WAD
        self._do(self.s.open_position, who, coll, debt)

    @rule(data=st.data())
    def add_collateral(self, data) -> None:  # noqa: ANN001
        pid = self._pid(data)
        self._do(self.s.add_collateral, self._caller(data, pid), pid, self._upto(data, 5 * WAD))

    @rule(data=st.data())
    def withdraw_collateral(self, data) -> None:  # noqa: ANN001
        pid = self._pid(data)
        coll = self.s.vault.effective(pid)[0]
        self._do(
            self.s.withdraw_collateral, self._caller(data, pid), pid, self._upto(data, coll // 4)
        )

    @rule(data=st.data())
    def borrow(self, data) -> None:  # noqa: ANN001
        pid = self._pid(data)
        debt = self.s.vault.debt_of(pid)
        self._do(self.s.borrow, self._caller(data, pid), pid, self._upto(data, debt // 3))

    @rule(data=st.data())
    def repay(self, data) -> None:  # noqa: ANN001
        pid = self._pid(data)
        room = self.s.vault.debt_of(pid) - MIN_DEBT
        self._do(self.s.repay, self._caller(data, pid), pid, self._upto(data, room))

    @rule(data=st.data())
    def close(self, data) -> None:  # noqa: ANN001
        pid = self._pid(data)
        who = self._caller(data, pid)
        debt, have = self.s.vault.debt_of(pid), self.s.token.balance_of(who)
        if have < debt and data.draw(st.booleans()):  # find the shortfall from another actor
            for a in ACTORS:
                give = min(self.s.token.balance_of(a), debt - have) if a != who else 0
                if give:
                    self._do(self.s.transfer, a, who, give)
                    have += give
        self._do(self.s.close, who, pid)

    @rule(data=st.data(), who=actor)
    def liquidate(self, data, who: str) -> None:  # noqa: ANN001
        v = self.s.vault
        low = [i for i in v.positions if v.is_liquidatable(i, self.price)]
        pid = (
            data.draw(st.sampled_from(low)) if low and data.draw(st.booleans()) else self._pid(data)
        )
        self._do(self.s.liquidate, who, pid)

    @rule(who=actor)
    def accrue(self, who: str) -> None:
        self._do(self.s.accrue, who)

    @rule(data=st.data())
    def reclaim_gas_reserve(self, data) -> None:  # noqa: ANN001
        pid = self._pid(data)
        self._do(self.s.reclaim_gas_reserve, self._caller(data, pid), pid)

    # ---- RedemptionModule ----
    @rule(
        data=st.data(),
        iterations=st.integers(0, 6),
        max_fee=st.sampled_from([0, 10**16, WAD, WAD]),
    )
    def redeem(self, data, iterations: int, max_fee: int) -> None:  # noqa: ANN001
        who = self._holder(data)
        have = self.s.token.balance_of(who)
        x = have if data.draw(st.booleans()) else self._upto(data, have)  # all of it: full ones
        self._do(self.s.redeem, who, x, iterations, max_fee)

    # ---- StabilityPool and DeficitLedger ----
    @rule(data=st.data())
    def deposit(self, data) -> None:  # noqa: ANN001
        who = self._holder(data)
        self._do(self.s.deposit, who, self._upto(data, self.s.token.balance_of(who)))

    def _depositor(self, data) -> str:  # noqa: ANN001
        held = sorted(self.s.pool.deposits)
        if held and data.draw(st.integers(0, 9)):
            return data.draw(st.sampled_from(held))
        return data.draw(actor)

    @rule(data=st.data(), everything=st.booleans())
    def withdraw(self, data, everything: bool) -> None:  # noqa: ANN001
        who = self._depositor(data)
        top = self.s.pool.compounded_deposit(who)
        self._do(self.s.withdraw, who, 2**256 - 1 if everything else self._upto(data, top))

    @rule(data=st.data())
    def claim_gains(self, data) -> None:  # noqa: ANN001
        self._do(self.s.claim_gains, self._depositor(data))

    @rule(who=actor)
    def cover(self, who: str) -> None:
        self._do(self.s.cover, who)

    # ---- ERC-20: payments between actors and donations to core contracts ----
    @rule(data=st.data(), who=actor, to=st.sampled_from(ACTORS + ACTORS + CORE), weth=st.booleans())
    def transfer(self, data, who: str, to: str, weth: bool) -> None:  # noqa: ANN001
        tok = self.s.weth if weth else self.s.token
        x = self._upto(data, tok.balance_of(who) // 4)
        self._do(self.s.transfer_weth if weth else self.s.transfer, who, to, x)

    # ---- the stand-in ShutdownModule, rarely ----
    @precondition(lambda self: not self.s.vault.shutdown)
    @rule(roll=st.integers(0, 40))
    def trigger_shutdown(self, roll: int) -> None:
        if roll == 0:
            self._do(self.s.trigger_shutdown)

    @precondition(lambda self: self.s.vault.shutdown and not self.s.vault.settled)
    @rule()
    def settle(self) -> None:
        self._do(self.s.settle)

    # ---- the checks ----
    @invariant()
    def invariants_hold(self) -> None:
        bad = self.s.check_invariants()
        assert bad == [], bad

    def teardown(self) -> None:
        bad = self.s.check_invariants(with_unwind=True)
        assert bad == [], bad


TestSystemQuick = SystemMachine.TestCase
TestSystemQuick.settings = settings(
    max_examples=100,
    stateful_step_count=60,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)


@pytest.mark.slow
class TestSystemNightly(SystemMachine.TestCase):
    settings = settings(
        max_examples=2_000,
        stateful_step_count=80,
        deadline=None,
        suppress_health_check=[HealthCheck.too_slow],
    )
