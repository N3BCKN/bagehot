"""The differential state machine (P23): random operations on the model and the chain in lockstep.

Every operation of deployment A has a rule. Arguments are drawn mostly from the model's current
state (an active position, its owner, an amount the caller holds) so runs go deep — liquidations on
every path, redemptions, pool offsets, settlement — and sometimes blind, so the revert paths are
compared too. After every rule `Pair.step` has already required the same outcome, the same events,
the same snapshot and the model's invariants (pair.py); a failure raises `Mismatch` with the first
difference.

`DiffMachine.pair` is set by the test before the run (one anvil per session); each example starts
from the same base state (`Pair.reset`: `evm_revert` on chain, a copy of the base model).

Deliberately absent, each with its reason in `differential/allowed.py` (the single list):
- wiring — no rule calls `wire`, calls before wiring, or calls a wiring function as the deployer
  (P22-DIFF-WIRED). The model builds the wired graph whole, as `BagehotFactory` does, so `NotWired`,
  `AlreadyWired` and `NotDeployer` on chain would be false mismatches; Foundry covers them.
- `Approval` events — actors approve the vault once, during setup; the model has no allowances, so
  the event is filtered from the comparison (`EXCLUDED_EVENTS`) and nothing else is.
- gas starvation, a failing pool hook, non-ABI feed replies, `StaleHint`, the §9 restrictions
  on components the model calls internally, the real ShutdownModule and bad deployments
  (`NOT_GENERATED`).
"""

from __future__ import annotations

from hypothesis import strategies as st
from hypothesis.stateful import (
    Bundle,
    RuleBasedStateMachine,
    initialize,
    multiple,
    precondition,
    rule,
)

from differential.chain import ACTORS
from differential.pair import Pair
from model.protocol.system import System
from model.protocol.vault import Status

WAD = 10**18
FEED = 10**10
MIN_DEBT = 2_000 * WAD
wild = st.one_of(st.integers(0, 3), st.integers(1, 10**24))


class DiffMachine(RuleBasedStateMachine):
    pair: Pair  # set by the test

    actors = Bundle("actors")
    positions = Bundle("positions")

    def __init__(self) -> None:
        super().__init__()
        self.pair.reset()
        self.price = 2_000 * WAD
        self.pending: list = []  # environment transactions for the next block

    @property
    def m(self):  # noqa: ANN201 — the model System
        return self.pair.model

    def _step(self, op: str, caller: str, *args: object) -> object:
        env, self.pending = self.pending, []
        return self.pair.step(op, caller, *args, env=tuple(env))

    def _upto(self, data, top: int) -> int:  # noqa: ANN001
        if data.draw(st.integers(0, 9)) == 0:
            return data.draw(wild)
        return data.draw(st.integers(1, max(1, top)))

    def _caller(self, data, pid: int, who: str) -> str:  # noqa: ANN001
        q = self.m.vault.positions.get(pid)
        return q.owner if q is not None and data.draw(st.integers(0, 9)) else who

    @initialize(target=actors)
    def start(self):  # noqa: ANN201
        return multiple(*ACTORS)

    @initialize(target=positions, data=st.data())
    def opening(self, data):  # noqa: ANN001, ANN201
        """Most runs start with a few positions and a funded pool, so liquidations offset."""
        pids = []
        for who in ACTORS[: data.draw(st.integers(1, 4))]:
            debt = data.draw(st.integers(MIN_DEBT, 30_000 * WAD))
            coll = -(-debt * data.draw(st.integers(110, 300)) // (100 * self.price)) * WAD
            pid = self._step("open_position", who, coll, debt, *self._hints(data))
            if pid is not None:
                pids.append(pid)
        for who in ACTORS:
            have = self.m.token.balance_of(who)
            if have and data.draw(st.integers(0, 3)):
                self._step("deposit", who, have * data.draw(st.integers(30, 100)) // 100)
        return multiple(*pids)

    def _holder(self, data, who: str) -> str:  # noqa: ANN001
        """Mostly the actor holding the most stablecoin, so pool and redemption calls can pay."""
        if data.draw(st.integers(0, 4)):
            return max(ACTORS, key=self.m.token.balance_of)
        return who

    def _hints(self, data) -> tuple[int, int]:  # noqa: ANN001
        """Insert/reinsert hints (§6.6): often none; otherwise an adjacent pair from the model's
        list in either order, one side only, or ids that may be closed or never opened."""
        kind = data.draw(st.integers(0, 4))
        nodes = self.m.sorted.nodes
        if kind == 0 or (kind == 1 and not nodes):
            return 0, 0
        ids = st.integers(0, self.m.vault.next_id + 1)
        if kind == 1:
            x = data.draw(st.sampled_from(sorted(nodes)))
            pair = (nodes[x][0], x) if data.draw(st.booleans()) else (x, nodes[x][1])
            return pair if data.draw(st.booleans()) else pair[::-1]
        if kind == 2:
            return data.draw(ids), 0
        if kind == 3:
            return 0, data.draw(ids)
        return data.draw(ids), data.draw(ids)

    # ---- environment: time, price, oracle health ----
    @rule(dt=st.one_of(st.integers(0, 600), st.integers(601, 86_400)), refresh=st.integers(0, 9))
    def warp(self, dt: int, refresh: int) -> None:
        self.pair.now += dt
        if refresh:  # the feed posts a fresh round; sometimes it goes stale
            self.pending += self.pair.feed_change("price", self.price)

    @rule(pct=st.integers(50, 130), odd=st.integers(0, FEED - 1))
    def move_price(self, pct: int, odd: int) -> None:
        self.price = min(max(self.price * pct // 100 + odd, 100 * WAD), 100_000 * WAD)
        self.pending += self.pair.feed_change("price", self.price)

    @rule(pct=st.integers(50, 85))
    def crash(self, pct: int) -> None:
        """A sharp fall, so positions go under MCR and liquidations happen."""
        self.price = max(self.price * pct // 100, 100 * WAD)
        self.pending += self.pair.feed_change("price", self.price)

    @rule(data=st.data(), pct=st.integers(80, 99))
    def undercut(self, data, pct: int) -> None:  # noqa: ANN001
        """The price just below one active position's MCR threshold (`coll · price < MCR · debt`),
        so liquidations — pool offsets, redistributions, deficits — are reached, not hoped for."""
        v = self.m.vault
        active = sorted(i for i in v.positions if v.positions[i].status == Status.ACTIVE)
        if not active:
            return
        pid = data.draw(st.sampled_from(active))
        threshold = v.mcr * v.debt_of(pid) // max(1, v.effective(pid)[0])
        self.price = min(max(threshold * pct // 100, 100 * WAD), 100_000 * WAD)
        self.pending += self.pair.feed_change("price", self.price)

    @rule(
        change=st.sampled_from(
            ["sequencer_down", "sequencer_reverts", "feed_reverts", "negative", *["heal"] * 4]
        )
    )
    def toggle_oracle(self, change: str) -> None:
        """§6.10.1 rows 1, 2, 5, 6; a heal brings the sequencer back up — `startedAt` = now after
        downtime, so the grace period (row 4) follows — and posts a fresh round."""
        if change == "heal":
            f = self.pair.feeds
            for c in ("sequencer_works", "feed_works", "sequencer_up"):
                self.pending += self.pair.feed_change(c)
            if not 0 < f.sequencer_started <= self.pair.now:
                self.pending += self.pair.feed_change("sequencer_start", self.pair.now)
            self.pending += self.pair.feed_change("price", self.price)
        else:
            self.pending += self.pair.feed_change(change)

    @rule(data=st.data(), row=st.sampled_from(["sequencer_start", "feed_time", "bounds"]))
    def odd_round(self, data, row: str) -> None:  # noqa: ANN001
        """§6.10.1 rows 3 and 7 (a timestamp of 0 or in the future) and row 9 (a price outside
        [MIN_PRICE, MAX_PRICE]); the next heal or price move repairs it."""
        p = self.m.params
        if row == "bounds":
            low = data.draw(st.integers(1, p.min_price - 1))
            high = data.draw(st.integers(p.max_price + 1, 10 * p.max_price))
            self.pending += self.pair.feed_change("price", data.draw(st.sampled_from([low, high])))
        else:
            ts = data.draw(
                st.one_of(st.just(0), st.integers(1, 3_600).map(lambda d: self.pair.now + d))
            )
            self.pending += self.pair.feed_change(row, ts)

    # ---- VaultManager ----
    @rule(target=positions, data=st.data(), who=actors)
    def open(self, data, who: str):  # noqa: ANN001, ANN201
        if data.draw(st.integers(0, 9)) == 0:
            coll, debt = data.draw(wild), data.draw(wild)
        else:
            debt = data.draw(st.integers(MIN_DEBT, 30_000 * WAD))
            coll = -(-debt * data.draw(st.integers(108, 300)) // (100 * self.price)) * WAD
        pid = self._step("open_position", who, coll, debt, *self._hints(data))
        return pid if pid is not None else multiple()

    @rule(data=st.data(), pid=positions, who=actors)
    def add_collateral(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        caller = self._caller(data, pid, who)
        self._step("add_collateral", caller, pid, self._upto(data, 5 * WAD), *self._hints(data))

    @rule(data=st.data(), pid=positions, who=actors)
    def withdraw_collateral(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        top = self.m.vault.effective(pid)[0] // 4
        caller = self._caller(data, pid, who)
        self._step("withdraw_collateral", caller, pid, self._upto(data, top), *self._hints(data))

    @rule(data=st.data(), pid=positions, who=actors)
    def borrow(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        top = self.m.vault.debt_of(pid) // 3
        caller = self._caller(data, pid, who)
        self._step("borrow", caller, pid, self._upto(data, top), *self._hints(data))

    @rule(data=st.data(), pid=positions, who=actors)
    def repay(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        top = self.m.vault.debt_of(pid) - MIN_DEBT
        caller = self._caller(data, pid, who)
        self._step("repay", caller, pid, self._upto(data, top), *self._hints(data))

    @rule(data=st.data(), pid=positions, who=actors)
    def close(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        self._step("close", self._caller(data, pid, who), pid)

    @rule(data=st.data(), pid=positions, who=actors)
    def liquidate(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        v = self.m.vault
        low = [i for i in v.positions if v.is_liquidatable(i, self.price)]
        if low and data.draw(st.integers(0, 4)):  # mostly a liquidatable one, sometimes blind
            pid = data.draw(st.sampled_from(low))
        self._step("liquidate", who, pid)

    @rule(who=actors)
    def accrue(self, who: str) -> None:
        self._step("accrue", who)

    @rule(data=st.data(), pid=positions, who=actors)
    def claim(self, data, pid: int, who: str) -> None:  # noqa: ANN001
        """`reclaimGasReserve`, the settled phase's claim of a position (§5.1.10)."""
        self._step("reclaim_gas_reserve", self._caller(data, pid, who), pid)

    # ---- RedemptionModule ----
    @rule(
        data=st.data(),
        who=actors,
        iterations=st.integers(0, 6),
        fee=st.sampled_from([0, WAD, WAD, WAD]),
    )
    def redeem(self, data, who: str, iterations: int, fee: int) -> None:  # noqa: ANN001
        who = self._holder(data, who)
        have = self.m.token.balance_of(who)
        x = have if data.draw(st.booleans()) else self._upto(data, have)
        self._step("redeem", who, x, iterations, fee, *self._hints(data))

    # ---- StabilityPool ----
    @rule(data=st.data(), who=actors)
    def deposit(self, data, who: str) -> None:  # noqa: ANN001
        who = self._holder(data, who)
        self._step("deposit", who, self._upto(data, self.m.token.balance_of(who)))

    @rule(data=st.data(), who=actors, everything=st.booleans())
    def withdraw_pool(self, data, who: str, everything: bool) -> None:  # noqa: ANN001
        held = sorted(self.m.pool.deposits)
        if held and data.draw(st.integers(0, 9)):
            who = data.draw(st.sampled_from(held))
        top = self.m.pool.compounded_deposit(who)
        self._step("withdraw", who, 2**256 - 1 if everything else self._upto(data, top))

    @rule(data=st.data(), who=actors)
    def claim_gains(self, data, who: str) -> None:  # noqa: ANN001
        held = sorted(self.m.pool.deposits)
        if held and data.draw(st.integers(0, 9)):
            who = data.draw(st.sampled_from(held))
        self._step("claim_gains", who)

    # ---- DeficitLedger, OracleAdapter, ERC-20 ----
    @rule(who=actors)
    def cover(self, who: str) -> None:
        self._step("cover", who)

    @rule(who=actors)
    def fetch_price(self, who: str) -> None:
        self._step("fetch_price", who)

    @rule(
        data=st.data(),
        who=actors,
        to=st.sampled_from([*ACTORS, *ACTORS, "vault", "pool", "ledger", "redemption"]),
        weth=st.booleans(),
    )
    def transfer(self, data, who: str, to: str, weth: bool) -> None:  # noqa: ANN001
        tok = self.m.weth if weth else self.m.token
        x = self._upto(data, tok.balance_of(who) // 4)
        self._step("transfer_weth" if weth else "transfer", who, to, x)

    # ---- the stand-in ShutdownModule, rarely ----
    @precondition(lambda self: not self.m.vault.shutdown)
    @rule(roll=st.integers(0, 24))
    def trigger_shutdown(self, roll: int) -> None:
        if roll == 0:
            self._step("trigger_shutdown", "shutdown")

    @precondition(lambda self: self.m.vault.shutdown and not self.m.vault.settled)
    @rule()
    def settle(self) -> None:
        self._step("settle", "shutdown")

    # ---- wired-only calls made directly (§9) ----
    @rule(data=st.data(), who=actors, name=st.sampled_from(System.HOOKS))
    def intrude(self, data, who: str, name: str) -> None:  # noqa: ANN001
        """An actor calls a hook only the wired caller may call: `Unauthorized` on both sides."""
        args: tuple = ()
        if name == "redeemCollateral":
            args = (who, self._upto(data, 10_000 * WAD), WAD // 200, self.price, 3, 0, 0)
        self._step("hook", who, name, *args)

    @rule(name=st.sampled_from(["onShutdown", "onSettlement", "ledgerOnSettlement"]))
    def hook_out_of_phase(self, name: str) -> None:
        """The stand-in calls one hook out of phase: `SystemShutdown`, `NotTriggered` or
        `AlreadySettled`. In phase the hooks run only in pairs (`trigger_shutdown`, `settle`)."""
        v = self.m.vault
        late = {
            "onShutdown": v.shutdown,
            "onSettlement": not v.shutdown or v.settled,
            "ledgerOnSettlement": self.m.ledger.settled,
        }
        if late[name]:
            self._step("hook", "shutdown", name)
