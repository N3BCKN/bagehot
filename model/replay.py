"""State rebuilt from events alone (I14): an indexer in miniature, for deployment A.

`Replay` consumes the run's log entry by entry, `(emitter, event)` with each entry's block
timestamp, and keeps the mutable state of §4 that the events describe: positions and the vault's
counters, the list, the pool's accumulators and deposit records, the ledger, the redemption fee
state, the oracle, and both tokens' balances (from `Transfer`). Starting from the deployment state
(`genesis`), `state()` returns it in the shape of `System.snapshot()`, so I14 is one comparison.

Nothing here reads contract state: every value comes from an event field or follows from earlier
events by the spec's own arithmetic (the pool's `S`/`G` products, a deposit's compounded value, the
sums that define the vault's aggregates). That is the point — a state change with no event, or an
event missing a field, makes the rebuild disagree.

While replaying it also drives the I3 attribution references (`Exact`): offsets and interest
bookings with the `T` they were booked against, and every depositor re-snapshot.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from model.protocol.math import RAY
from model.protocol.stability_pool import P_PRECISION, Deposit, compounded
from model.protocol.vault import Status

ZERO = "0x0"
ACTIVE = int(Status.ACTIVE)


@dataclass
class _Pos:
    owner: str = ""
    coll: int = 0
    norm_debt: int = 0
    stake: int = 0
    snap_l_coll: int = 0
    snap_l_debt: int = 0
    status: int = 0


@dataclass
class _PoolView:
    """What `Exact` reads of the pool before an event: the deposit records and (epoch, scale)."""

    deposits: dict[str, Deposit] = field(default_factory=dict)
    current_epoch: int = 0
    current_scale: int = 0


@dataclass
class Replay:
    t0: int
    exact: object | None = None  # model.invariants.Exact, driven when given
    # vault
    positions: dict[int, _Pos] = field(default_factory=dict)
    index: int = RAY
    last_accrual: int = 0
    l_coll: int = 0
    l_debt: int = 0
    last_error_coll: int = 0
    last_error_debt: int = 0
    pending_coll: int = 0
    pending_norm_debt: int = 0
    total_stakes_snapshot: int = 0
    total_collateral_snapshot: int = 0
    shutdown: bool = False
    settled: bool = False
    frozen: tuple[int, int] | None = None  # (totalStakes, totalNormDebt) at settlement
    # list
    nodes: dict[int, list[int]] = field(default_factory=dict)
    head: int = 0
    tail: int = 0
    # pool
    pool: _PoolView = field(default_factory=_PoolView)
    p: int = P_PRECISION
    total_deposits: int = 0
    s: dict[tuple[int, int], int] = field(default_factory=dict)
    g: dict[tuple[int, int], int] = field(default_factory=dict)
    last_coll_error: int = 0
    last_interest_error: int = 0
    coll_gains_balance: int = 0
    interest_gains_balance: int = 0
    depositor_count: dict[int, int] = field(default_factory=dict)
    # ledger
    reserve: int = 0
    auction_debt: int = 0
    deficit: int = 0
    recovered_coll: int = 0
    ledger_settled: bool = False
    # redemption, oracle
    base_rate: int = 0
    last_fee_operation_time: int = 0
    last_good_price: int = 0
    failure_start: int = 0
    # tokens
    balances: dict[str, dict[str, int]] = field(default_factory=lambda: {"weth": {}, "token": {}})
    supply: dict[str, int] = field(default_factory=lambda: {"weth": 0, "token": 0})

    def __post_init__(self) -> None:
        self.last_accrual = self.t0
        self.last_fee_operation_time = self.t0

    # ---- feeding ----
    def feed(self, entries: list[tuple[str, tuple]], stamps: list[int]) -> None:
        for (src, ev), t in zip(entries, stamps, strict=True):
            self.apply(src, ev, t)

    def apply(self, src: str, ev: tuple, t: int) -> None:
        handler = getattr(self, f"_on_{ev[0]}", None)
        if handler is None:
            raise ValueError(f"replay has no rule for {src}:{ev[0]}")
        if ev[0] == "Transfer":
            handler(src, *ev[1:])
        else:
            handler(t, *ev[1:])

    # ---- tokens ----
    def _on_Transfer(self, token: str, frm: str, to: str, value: int) -> None:  # noqa: N802
        b = self.balances[token]
        if frm == ZERO:
            self.supply[token] += value
        else:
            b[frm] = b.get(frm, 0) - value
        if to == ZERO:
            self.supply[token] -= value
        else:
            b[to] = b.get(to, 0) + value

    # ---- VaultManager ----
    def _on_PositionOpened(self, t: int, pid: int, owner: str, debt: int) -> None:  # noqa: N802
        self.positions[pid] = _Pos(owner=owner)

    def _on_PositionUpdated(  # noqa: N802, PLR0913
        self, t: int, pid: int, coll: int, n: int, stake: int, slc: int, sld: int, st: int, op: int
    ) -> None:
        p = self.positions[pid]
        p.coll, p.norm_debt, p.stake, p.snap_l_coll, p.snap_l_debt, p.status = (
            coll,
            n,
            stake,
            slc,
            sld,
            st,
        )

    def _on_RewardsApplied(self, t: int, pid: int, pc: int, pn: int) -> None:  # noqa: N802
        self.pending_coll -= pc
        self.pending_norm_debt -= pn

    def _on_CollateralAdded(self, t: int, *_: object) -> None:  # noqa: N802
        pass  # the position's new values arrive in PositionUpdated

    _on_CollateralWithdrawn = _on_CollateralAdded
    _on_Borrowed = _on_CollateralAdded
    _on_Repaid = _on_CollateralAdded
    _on_PositionClosed = _on_CollateralAdded
    _on_PositionRedeemed = _on_CollateralAdded
    _on_GasReserveReclaimed = _on_CollateralAdded
    _on_Liquidated = _on_CollateralAdded
    _on_PoolInterestRedirected = _on_CollateralAdded

    def _on_Redistributed(  # noqa: N802, PLR0913
        self, t: int, coll: int, n: int, lc: int, ld: int, ec: int, ed: int, stakes: int
    ) -> None:
        self.pending_coll += coll
        self.pending_norm_debt += n
        self.l_coll, self.l_debt, self.last_error_coll, self.last_error_debt = lc, ld, ec, ed

    def _on_SystemSnapshotsUpdated(self, t: int, ts: int, tc: int) -> None:  # noqa: N802
        self.total_stakes_snapshot, self.total_collateral_snapshot = ts, tc

    def _on_InterestAccrued(  # noqa: N802
        self, t: int, index: int, interest: int, to_pool: int, to_reserve: int, ts: int
    ) -> None:
        self.index, self.last_accrual = index, ts

    def _on_VaultShutdown(self, t: int, index: int) -> None:  # noqa: N802
        self.shutdown, self.index = True, index

    def _on_VaultSettled(self, t: int, coll: int, active: int) -> None:  # noqa: N802
        self.frozen = (self._sum("stake"), self._sum("norm_debt") + self.pending_norm_debt)
        self.settled = True
        self.pending_coll = 0

    def _sum(self, attr: str) -> int:
        return sum(getattr(p, attr) for p in self.positions.values() if p.status == ACTIVE)

    # ---- SortedPositions ----
    def _on_NodeInserted(self, t: int, pid: int, prev: int, nxt: int) -> None:  # noqa: N802
        self.nodes[pid] = [prev, nxt]
        if prev == 0:
            self.head = pid
        else:
            self.nodes[prev][1] = pid
        if nxt == 0:
            self.tail = pid
        else:
            self.nodes[nxt][0] = pid

    def _on_NodeRemoved(self, t: int, pid: int) -> None:  # noqa: N802
        prev, nxt = self.nodes.pop(pid)
        if prev == 0:
            self.head = nxt
        else:
            self.nodes[prev][1] = nxt
        if nxt == 0:
            self.tail = prev
        else:
            self.nodes[nxt][0] = prev

    # ---- StabilityPool ----
    def _key(self) -> tuple[int, int]:
        return self.pool.current_epoch, self.pool.current_scale

    def _on_DepositUpdated(  # noqa: N802, PLR0913
        self, t: int, a: str, initial: int, p: int, epoch: int, scale: int, ss: int, sg: int
    ) -> None:
        prev = self.pool.deposits.get(a, Deposit())
        cur = self.pool.current_epoch
        # totalDeposits moves by exactly what the record moved against its compounded value:
        # deposit +amount, withdraw −w, claim 0 (§5.3.1–5.3.3)
        self.total_deposits += initial - compounded(prev, self.p, cur, self.pool.current_scale)
        was_current = prev.initial > 0 and prev.snap_epoch == cur
        if initial > 0:
            self.pool.deposits[a] = Deposit(initial, p, ss, sg, epoch, scale)
            if not was_current:
                self.depositor_count[cur] = self.depositor_count.get(cur, 0) + 1
        else:
            self.pool.deposits.pop(a, None)
            if was_current:
                self.depositor_count[cur] -= 1
        if self.exact is not None:
            self.exact.snapshot(self.pool, a)

    def _on_GainsPaid(self, t: int, a: str, coll_gain: int, interest_gain: int) -> None:  # noqa: N802
        self.coll_gains_balance -= coll_gain
        self.interest_gains_balance -= interest_gain

    def _on_PoolOffset(  # noqa: N802, PLR0913
        self, t: int, d: int, c: int, per_unit: int, err: int, p: int, e: int, sc: int, total: int
    ) -> None:
        if self.exact is not None:
            self.exact.on_offset(total + d, d, c, self.pool)
        key = self._key()
        self.s[key] = self.s.get(key, 0) + per_unit * self.p  # P before the update (§6.6.2)
        self.last_coll_error = err
        self.coll_gains_balance += c
        self.p, self.pool.current_epoch, self.pool.current_scale = p, e, sc
        self.total_deposits = total

    def _on_PoolInterest(self, t: int, amount: int, per_unit: int, err: int) -> None:  # noqa: N802
        if self.exact is not None:
            self.exact.on_interest(self.total_deposits, amount, self.pool)
        key = self._key()
        self.g[key] = self.g.get(key, 0) + per_unit * self.p
        self.last_interest_error = err
        self.interest_gains_balance += amount

    def _on_PoolLiquidation(self, t: int, *_: object) -> None:  # noqa: N802
        pass  # its effects arrive as PoolOffset and the Transfers

    def _on_PoolDustSwept(self, t: int, amount: int) -> None:  # noqa: N802
        self.total_deposits = 0

    # ---- DeficitLedger ----
    def _on_ReserveIncreased(self, t: int, amount: int, source: int) -> None:  # noqa: N802
        self.reserve += amount

    def _on_ReserveDecreased(self, t: int, amount: int, reason: int) -> None:  # noqa: N802
        self.reserve -= amount

    def _on_AuctionDebtChanged(self, t: int, delta: int, total: int) -> None:  # noqa: N802
        self.auction_debt = total

    def _on_DeficitRecorded(self, t: int, amount: int, coll: int, source: int) -> None:  # noqa: N802
        self.deficit += amount
        self.recovered_coll += coll

    def _on_DeficitCovered(self, t: int, amount: int, reserve: int, deficit: int) -> None:  # noqa: N802
        self.reserve, self.deficit = reserve, deficit

    def _on_LedgerSettled(self, t: int, burned: int, deficit: int, coll: int) -> None:  # noqa: N802
        self.reserve, self.auction_debt, self.deficit, self.recovered_coll = 0, 0, deficit, 0
        self.ledger_settled = True

    # ---- RedemptionModule ----
    def _on_Redeemed(  # noqa: N802, PLR0913
        self, t: int, who: str, req: int, red: int, coll: int, fee: int, it: int, base: int
    ) -> None:
        self.base_rate, self.last_fee_operation_time = base, t

    # ---- OracleAdapter ----
    def _on_LastGoodPriceUpdated(self, t: int, price: int) -> None:  # noqa: N802
        self.last_good_price = price

    def _on_OracleFailure(self, t: int, reason: int, ts: int) -> None:  # noqa: N802
        self.failure_start = ts

    def _on_OracleRecovered(self, t: int, ts: int) -> None:  # noqa: N802
        self.failure_start = 0

    # ---- the rebuilt state, shaped like System.snapshot() (minus `now`) ----
    def state(self) -> dict:
        from model.protocol.system import _canon, _nested  # noqa: PLC0415 — avoid a cycle

        active = [p for p in self.positions.values() if p.status == ACTIVE]
        if self.frozen is None:
            total_stakes = sum(p.stake for p in active)
            total_norm = sum(p.norm_debt for p in active) + self.pending_norm_debt
            total_coll = sum(p.coll for p in active)
        else:
            (total_stakes, total_norm), total_coll = self.frozen, 0
        return _canon(
            {
                "vault": {
                    "index": self.index,
                    "lastAccrual": self.last_accrual,
                    "nextId": max(self.positions, default=0) + 1,
                    "activeCount": len(active),
                    "totalNormDebt": total_norm,
                    "totalCollateral": total_coll,
                    "totalStakes": total_stakes,
                    "totalStakesSnapshot": self.total_stakes_snapshot,
                    "totalCollateralSnapshot": self.total_collateral_snapshot,
                    "LColl": self.l_coll,
                    "LDebt": self.l_debt,
                    "lastErrorColl": self.last_error_coll,
                    "lastErrorDebt": self.last_error_debt,
                    "pendingColl": self.pending_coll,
                    "pendingNormDebt": self.pending_norm_debt,
                    "shutdown": self.shutdown,
                    "settled": self.settled,
                    "positions": {
                        pid: {
                            "owner": p.owner,
                            "coll": p.coll,
                            "normDebt": p.norm_debt,
                            "stake": p.stake,
                            "snapLColl": p.snap_l_coll,
                            "snapLDebt": p.snap_l_debt,
                            "status": p.status,
                        }
                        for pid, p in self.positions.items()
                    },
                },
                "sorted": {
                    "head": self.head,
                    "tail": self.tail,
                    "size": len(self.nodes),
                    "nodes": {i: {"prev": n[0], "next": n[1]} for i, n in self.nodes.items()},
                },
                "pool": {
                    "totalDeposits": self.total_deposits,
                    "P": self.p,
                    "currentScale": self.pool.current_scale,
                    "currentEpoch": self.pool.current_epoch,
                    "epochToScaleToS": _nested(self.s),
                    "epochToScaleToG": _nested(self.g),
                    "lastCollError": self.last_coll_error,
                    "lastInterestError": self.last_interest_error,
                    "collGainsBalance": self.coll_gains_balance,
                    "interestGainsBalance": self.interest_gains_balance,
                    "deposits": {
                        a: {
                            "initial": d.initial,
                            "snapP": d.snap_p,
                            "snapS": d.snap_s,
                            "snapG": d.snap_g,
                            "snapEpoch": d.snap_epoch,
                            "snapScale": d.snap_scale,
                        }
                        for a, d in self.pool.deposits.items()
                    },
                    "depositorCount": {e: c for e, c in self.depositor_count.items() if c},
                },
                "redemption": {
                    "baseRate": self.base_rate,
                    "lastFeeOperationTime": self.last_fee_operation_time,
                },
                "ledger": {
                    "reserve": self.reserve,
                    "auctionDebt": self.auction_debt,
                    "deficit": self.deficit,
                    "recoveredColl": self.recovered_coll,
                    "settled": self.ledger_settled,
                },
                "oracle": {
                    "lastGoodPrice": self.last_good_price,
                    "failureStart": self.failure_start,
                },
                "weth": _token(self.balances["weth"], self.supply["weth"]),
                "token": _token(self.balances["token"], self.supply["token"]),
            }
        )


def _token(balances: dict[str, int], supply: int) -> dict:
    return {"totalSupply": supply, "balances": {a: b for a, b in balances.items() if b}}
