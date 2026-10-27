"""Invariant checks on the Python model (docs/invariants.md), deployment A.

Integers for every protocol inequality; `fractions.Fraction` only where the invariant text states a
bound against exact rationals — I3's pro-rata references and I13's hidden keys — which is why those
two are checked here and not (or not fully) in Foundry.

`System.check_invariants()` runs every check that applies to the current phase and returns the
violated clauses (empty when all hold). State checks read the current state: I1, I2, I3, I8, I11,
I13, I14. Per-operation checks read the last recorded `Step` (state before and after, its events,
outcome, the price, oracle reads): I4, I5, I6, I7, I9, I12, I15. Both need the `Ghost` a recording
`System` keeps from deployment on: the I2 counters, the event replay (I14) driving I3's exact
references, I13's insertion records, and the donations.

Not here: I10 (claims need the real ShutdownModule — its prompt) and I16 (deployment B, P34).
`unwind(system)` is I8's procedure, run on a copy; it is expensive, so `check_invariants` runs it
only when asked.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from fractions import Fraction

from model.protocol.math import RAY, WAD, mul_div_down, mul_div_up, rpow
from model.protocol.sorted_list import precedes
from model.protocol.stability_pool import (
    DECIMAL_PRECISION,
    P_MIN,
    P_PRECISION,
    SCALE_SPAN,
    StabilityPool,
)


def check_I3(pool: StabilityPool, depositors: list[str]) -> list[str]:
    """I3's exact inequalities and the `P` range; returns the violated clauses (empty if none)."""
    bad = []
    compounded = sum(pool.compounded_deposit(a) for a in depositors)
    gains = [pool.gains(a) for a in depositors]
    if compounded > pool.total_deposits:
        bad.append("sum of compounded deposits > totalDeposits")
    if sum(g[0] for g in gains) > pool.coll_gains_balance:
        bad.append("sum of collateral gains > collGainsBalance")
    if sum(g[1] for g in gains) > pool.interest_gains_balance:
        bad.append("sum of interest gains > interestGainsBalance")
    if not P_MIN <= pool.p <= P_PRECISION:
        bad.append("P out of range")
    if (
        pool.depositor_count.get(pool.current_epoch, 0) == 0
        and not pool.bank.is_ledger_settled()
        and pool.total_deposits != 0
    ):
        bad.append("no current-epoch depositor but totalDeposits != 0")
    return bad


def check_U4(pool: StabilityPool, depositors: list[str], donated_token: int = 0) -> bool:
    """U4: Σ compounded ≤ token.balanceOf(pool) − interestGainsBalance − donated."""
    compounded = sum(pool.compounded_deposit(a) for a in depositors)
    return (
        compounded <= pool.bank.stable.get("pool", 0) - pool.interest_gains_balance - donated_token
    )


@dataclass
class ExactDepositor:
    """The rational pro-rata reference of one depositor since its last snapshot (I3)."""

    share: Fraction = Fraction(0)  # gExactShare
    coll_gain: Fraction = Fraction(0)  # gExactCollGain
    interest_gain: Fraction = Fraction(0)  # gExactInterestGain
    offsets: int = 0  # offsets since the snapshot (compounded bound)
    coll_bound: Fraction = Fraction(0)  # T_j/DP + Σ (T_k/DP + 1) over offset events
    interest_bound: Fraction = Fraction(0)  # the same over interest events
    # CHG-010: the exact share of gains booked while
    # currentScale > snapScale + SCALE_SPAN, which §6.6.7 ignores
    coll_ignored: Fraction = Fraction(0)
    interest_ignored: Fraction = Fraction(0)


@dataclass
class Exact:
    """Exact accumulators for every depositor, driven event by event alongside the integer model."""

    depositors: dict[str, ExactDepositor] = field(default_factory=dict)
    last_t_coll: int = 0  # T of the latest offset: the divisor that produced the current carry
    last_t_interest: int = 0

    def snapshot(self, pool: StabilityPool, a: str) -> None:
        """deposit / withdraw / claimGains re-snapshot (§6.6.8): the reference restarts from the
        integer deposit, with the carry's leading term T_j / DP for each accumulator."""
        rec = pool.deposits.get(a)
        initial = rec.initial if rec is not None else 0
        self.depositors[a] = ExactDepositor(
            share=Fraction(initial),
            coll_bound=Fraction(self.last_t_coll, DECIMAL_PRECISION),
            interest_bound=Fraction(self.last_t_interest, DECIMAL_PRECISION),
        )

    @staticmethod
    def _ignored(pool: StabilityPool | None, a: str) -> bool:
        """True when a gain booked now falls in a scale §6.6.7 ignores for `a`; call before the
        event."""
        if pool is None:
            return False
        rec = pool.deposits.get(a)
        return (
            rec is not None
            and rec.snap_epoch == pool.current_epoch
            and pool.current_scale > rec.snap_scale + SCALE_SPAN
        )

    def on_offset(self, t: int, d: int, c: int, pool: StabilityPool | None = None) -> None:
        for a, e in self.depositors.items():
            if e.share == 0:
                continue
            if self._ignored(pool, a):
                e.coll_ignored += Fraction(c) * e.share / t
            e.coll_gain += Fraction(c) * e.share / t
            e.share = e.share * (t - d) / t
            e.offsets += 1
            e.coll_bound += Fraction(t, DECIMAL_PRECISION) + 1
        self.last_t_coll = t

    def on_interest(self, t: int, g: int, pool: StabilityPool | None = None) -> None:
        for a, e in self.depositors.items():
            if e.share == 0:
                continue
            if self._ignored(pool, a):
                e.interest_ignored += Fraction(g) * e.share / t
            e.interest_gain += Fraction(g) * e.share / t
            e.interest_bound += Fraction(t, DECIMAL_PRECISION) + 1
        self.last_t_interest = t


def check_I3_attribution(pool: StabilityPool, exact: Exact) -> list[str]:
    """I3's two attribution bounds against the exact references (with CHG-010's ignored-scales term
    on both gain bounds); returns violations."""
    bad = []
    for a, e in exact.depositors.items():
        comp = pool.compounded_deposit(a)
        cg, ig = pool.gains(a)
        gap = e.share - comp
        if gap < 0 or gap > e.share * e.offsets / 10**27 + 1:
            bad.append(f"{a}: compounded {comp} vs exact {float(e.share):.6g}")
        if abs(e.coll_gain - cg) > e.coll_bound + e.coll_ignored:
            bad.append(f"{a}: collateral gain {cg} vs exact {float(e.coll_gain):.6g}")
        if abs(e.interest_gain - ig) > e.interest_bound + e.interest_ignored:
            bad.append(f"{a}: interest gain {ig} vs exact {float(e.interest_gain):.6g}")
    return bad


def check_I3_attribution_pre_chg010(pool: StabilityPool, exact: Exact) -> list[str]:
    """I3's gain bounds as written before CHG-010 (without the ignored-scales term) — kept only to
    pin the counterexample that motivated the change (`tests/model/test_sp_precision.py`)."""
    bad = []
    for a, e in exact.depositors.items():
        cg, ig = pool.gains(a)
        if abs(e.coll_gain - cg) > e.coll_bound:
            bad.append(f"{a}: collateral gain {cg} vs exact {float(e.coll_gain):.6g}")
        if abs(e.interest_gain - ig) > e.interest_bound:
            bad.append(f"{a}: interest gain {ig} vs exact {float(e.interest_gain):.6g}")
    return bad


# ======================================================================================
# Deployment A, the whole system (P22)
# ======================================================================================

CORE = frozenset(
    ("vault", "pool", "ledger", "redemption", "sorted", "oracle", "shutdown", "weth", "token")
)
DP = DECIMAL_PRECISION
STATUS_ACTIVE, STATUS_CLOSED_BY_REDEMPTION = 1, 3
OP_OPEN, OP_BORROW, OP_REPAY, OP_CLOSE = 1, 4, 5, 6
PATH_NONE, PATH_REDISTRIBUTED, PATH_DEFICIT = 0, 1, 2
NO_STAKES = 2


@dataclass
class Counters:
    """I2's sub-effect counters, read from events per the counter table (CHG-011)."""

    n: int = 0  # gN
    x: int = 0  # gX
    y: int = 0  # gY

    def update(self, entries: list[tuple[str, tuple]]) -> None:
        for src, e in entries:
            name = e[0]
            if src == "vault":
                if name == "InterestAccrued":
                    self.n += 1
                elif name == "PositionUpdated":
                    op = e[8]
                    if op in (OP_OPEN, OP_BORROW, OP_REPAY):
                        self.x += 1
                    elif op == OP_CLOSE:
                        self.y += 1
                elif name == "PositionRedeemed":
                    if e[5]:
                        self.y += 1
                    else:
                        self.x += 1
                elif name == "Liquidated":  # by the position: partial X, full Y, none nothing
                    debt, absorbed = e[4], e[6]
                    if 0 < absorbed < debt:
                        self.x += 1
                    elif absorbed > 0:
                        self.y += 1
            elif src == "ledger" and name == "DeficitRecorded" and e[3] == NO_STAKES:
                self.y += 1


@dataclass
class Member:
    """I13: what a list member carries from its last insertion (CHG-009)."""

    h: Fraction  # hidden key
    iota: Fraction  # what it inherited at insertion
    key: tuple[int, int]  # its sort key at insertion
    exact: bool  # every member was exact at that insertion (CHG-005)


class Ghost:
    """What the Foundry handler keeps beside the contracts, for a recording `System`."""

    def __init__(self, system) -> None:  # noqa: ANN001 — System
        from model.replay import Replay  # noqa: PLC0415 — replay imports the system module

        self.counters = Counters()
        self.exact = Exact()
        self.replay = Replay(system.now, exact=self.exact)
        self.members: dict[int, Member] = {}
        self.insertion_violations: list[str] = []
        self.cursor = 0

    def observe(self, system) -> None:  # noqa: ANN001 — System
        """Consume the log entries since the last call (an operation, or setup mints)."""
        log = system.log
        entries, stamps = log.entries[self.cursor :], log.stamps[self.cursor :]
        self.cursor = len(log.entries)
        self.counters.update(entries)
        self.replay.feed(entries, stamps)
        for src, e in entries:
            if src != "sorted":
                continue
            if e[0] == "NodeRemoved":
                self.members.pop(e[1], None)
            else:
                self._inserted(system, e[1], e[2], e[3])

    # ---- I13 records (the post-operation state equals the state at the insertion: nothing
    #      moves the accumulators or the inserted position later in the same operation) ----
    def _inserted(self, system, pid: int, prev: int, nxt: int) -> None:  # noqa: ANN001
        v = system.vault
        q = v.positions[pid]
        h = Fraction(q.norm_debt * (DP + q.snap_l_coll), q.coll) - q.snap_l_debt
        iota = Fraction(0)
        if prev:
            m = self.members[prev]
            iota = max(iota, m.iota + math.ceil(m.h - _h_obs(v, prev)))
        if nxt:
            m = self.members[nxt]
            iota = max(iota, m.iota + math.ceil(_h_obs(v, nxt) - m.h))
        key = v.sort_key(pid)
        if prev and not precedes(v.sort_key(prev), prev, key, pid):
            self.insertion_violations.append(f"I13 condition 2: {prev} does not precede {pid}")
        if nxt and not precedes(key, pid, v.sort_key(nxt), nxt):
            self.insertion_violations.append(f"I13 condition 2: {pid} does not precede {nxt}")
        if q.stake != v._compute_stake(q.coll):
            self.insertion_violations.append(f"I13 condition 3: stake of {pid}")
        all_exact = all(_is_exact(v, i, m) for i, m in self.members.items() if i != pid)
        self.members[pid] = Member(h, iota, key, all_exact)


def _h_obs(v, q: int) -> Fraction:  # noqa: ANN001 — Vault
    c, n = v.sort_key(q)
    return Fraction(n * (DP + v.l_coll), c) - v.l_debt


def _is_exact(v, q: int, m: Member) -> bool:  # noqa: ANN001 — Vault
    return m.exact and v.sort_key(q) == m.key


# ---- helpers on snapshots ----
def _eff(pos: dict, l_coll: int, l_debt: int) -> tuple[int, int]:
    """§6.5.3 (R8): a position's effective (coll, normDebt) from a snapshot record."""
    return (
        pos["coll"] + mul_div_down(pos["stake"], l_coll - pos["snapLColl"], DP),
        pos["normDebt"] + mul_div_down(pos["stake"], l_debt - pos["snapLDebt"], DP),
    )


def _system_coll(snap: dict) -> int:
    v = snap["vault"]
    return v["totalCollateral"] + v["pendingColl"] + snap["ledger"]["recoveredColl"]


def _system_debt(snap: dict, index: int) -> int:
    led = snap["ledger"]
    return (
        mul_div_up(snap["vault"]["totalNormDebt"], index, RAY) + led["auctionDebt"] + led["deficit"]
    )


def _accrued_index(vault: dict, now: int, rate: int) -> int:
    """§6.2: the index an operation at `now` accrues to (frozen once shut down)."""
    if vault["shutdown"]:
        return vault["index"]
    return mul_div_up(vault["index"], rpow(RAY + rate, now - vault["lastAccrual"]), RAY)


def _events(step, src: str, name: str) -> list[tuple]:  # noqa: ANN001 — Step
    return [e for s, e in step.events if s == src and e[0] == name]


def _settled(system) -> bool:  # noqa: ANN001
    return system.vault.settled


# ---- I1 ----
def check_I1(system) -> list[str]:  # noqa: ANN001, N802 — System; the invariant's name
    v, pool, led = system.vault, system.pool, system.ledger
    w, t = system.weth, system.token
    dw, dt = system.donated["weth"], system.donated["token"]
    bad = []

    def row(name: str, actual: int, expected: int) -> None:
        if actual != expected:
            bad.append(f"I1 {name}: {actual} != {expected}")

    gas = v.active_count * v.gas_reserve
    if v.settled:
        row("VaultManager WETH", w.balance_of("vault"), gas + dw.get("vault", 0))
    else:
        row(
            "VaultManager WETH",
            w.balance_of("vault"),
            v.total_collateral + v.pending_coll + gas + dw.get("vault", 0),
        )
    row("StabilityPool WETH", w.balance_of("pool"), pool.coll_gains_balance + dw.get("pool", 0))
    row(
        "StabilityPool token",
        t.balance_of("pool"),
        pool.total_deposits + pool.interest_gains_balance + dt.get("pool", 0),
    )
    if led.settled:
        row("DeficitLedger token", t.balance_of("ledger"), dt.get("ledger", 0))
        row("DeficitLedger WETH", w.balance_of("ledger"), dw.get("ledger", 0))
    else:
        row("DeficitLedger token", t.balance_of("ledger"), led.reserve + dt.get("ledger", 0))
        row("DeficitLedger WETH", w.balance_of("ledger"), led.recovered_coll + dw.get("ledger", 0))
    row("RedemptionModule WETH", w.balance_of("redemption"), dw.get("redemption", 0))
    row("RedemptionModule token", t.balance_of("redemption"), dt.get("redemption", 0))
    row("ShutdownModule WETH", w.balance_of("shutdown"), system.claim_coll + dw.get("shutdown", 0))
    if not v.settled:  # the supporting identities stop at settlement
        active = [q for q in v.positions.values() if q.status == STATUS_ACTIVE]
        row("totalStakes", v.total_stakes, sum(q.stake for q in active))
        row(
            "totalNormDebt",
            v.total_norm_debt,
            sum(q.norm_debt for q in active) + v.pending_norm_debt,
        )
        row("totalCollateral", v.total_collateral, sum(q.coll for q in active))
        row("activeCount", v.active_count, system.sorted.size)
        row("activeCount (statuses)", v.active_count, len(active))
    return bad


# ---- I2 ----
def check_I2(system, counters: Counters) -> list[str]:  # noqa: ANN001, N802
    """E = n·I − (S − A − F)·RAY within [−gN·RAY, gX·I + gY·RAY], strict where §10.2 says; live
    and window only."""
    v, led = system.vault, system.ledger
    if v.settled:
        return []
    e = (
        v.total_norm_debt * v.index
        - (system.token.total_supply - led.auction_debt - led.deficit) * RAY
    )
    lo, hi = -counters.n * RAY, counters.x * v.index + counters.y * RAY
    bad = []
    if e < lo or (counters.n >= 1 and e == lo):
        bad.append(f"I2: E = {e} below −gN·RAY = {lo}")
    if e > hi or (counters.x + counters.y >= 1 and e == hi):
        bad.append(f"I2: E = {e} above gX·I + gY·RAY = {hi}")
    return bad


# ---- I3 (whole system) ----
def check_I3_system(system, exact: Exact) -> list[str]:  # noqa: ANN001, N802
    pool = system.pool
    depositors = sorted(pool.deposits)
    bad = [f"I3 {b}" for b in check_I3(pool, depositors)]
    if not check_U4(pool, depositors, system.donated["token"].get("pool", 0)):
        bad.append("U4: compounded deposits exceed the pool's stablecoin")
    bad += [f"I3 attribution {b}" for b in check_I3_attribution(pool, exact)]
    return bad


# ---- I4, I6, I7: one liquidation (deployment A) ----
def check_liquidation(system, step) -> list[str]:  # noqa: ANN001 — System, Step
    if step.op != "liquidate" or step.error is not None:
        return []
    (liq,) = _events(step, "vault", "Liquidated")
    (pl,) = _events(step, "pool", "PoolLiquidation")
    _, pid, owner, caller, debt, coll, absorbed, coll_rest, norm_rest, path, gas = liq
    _, _, _, _, seized, surplus, d_offset, coll_p, coll_returned = pl
    pre, post = step.pre, step.post
    index = post["vault"]["index"]  # after the call's accrual; the liquidation leaves it
    bad = []
    # I4 (A1–A3)
    c_before, c_after = _system_coll(pre), _system_coll(post)
    d_before, d_after = _system_debt(pre, index), _system_debt(post, index)
    dc, dd = surplus + coll_p, absorbed
    if c_after != c_before - dc:
        bad.append(f"I4 A1: C {c_after} != {c_before} − {dc}")
    if absorbed == debt and (dc != coll or dd != debt):
        bad.append("I4 A2: a full absorption did not remove the whole position")
    if (
        absorbed == debt
        and coll * d_before <= debt * c_before
        and c_after * d_before + c_before < c_before * d_after
    ):
        bad.append("I4 A3: TCR fell by more than one wei of debt")
    # I6
    pos = pre["vault"]["positions"][pid]
    eff_c, eff_n = _eff(pos, pre["vault"]["LColl"], pre["vault"]["LDebt"])
    if (coll, debt) != (eff_c, mul_div_up(eff_n, index, RAY)):
        bad.append("I6: Liquidated.coll/debt are not the position's effective values")
    if coll != coll_p + surplus + coll_returned or coll_returned != coll_rest:
        bad.append("I6: coll != collP + surplus + collReturned")
    norm_absorbed = eff_n if absorbed == debt else mul_div_down(absorbed, RAY, index)  # R34
    if eff_n != norm_absorbed + norm_rest:
        bad.append("I6: n != normAbsorbed + normRest")
    red = _events(step, "vault", "Redistributed")
    rec = [e for e in _events(step, "ledger", "DeficitRecorded") if e[3] == NO_STAKES]
    if path == PATH_REDISTRIBUTED:
        if len(red) != 1 or rec or (red[0][1], red[0][2]) != (coll_returned, norm_rest):
            bad.append("I6: the remainder was not redistributed exactly once")
    elif path == PATH_DEFICIT:
        if (
            len(rec) != 1
            or red
            or (rec[0][1], rec[0][2]) != (mul_div_up(norm_rest, index, RAY), coll_returned)
        ):
            bad.append("I6: the remainder was not recorded as deficit exactly once")
    elif red or rec or coll_returned or norm_rest:
        bad.append("I6: path NONE with a remainder or a remainder event")
    if gas != system.params.gas_reserve or d_offset != absorbed:
        bad.append("I6: gas compensation or the pool's offset disagrees with Liquidated")
    # I7
    cap = mul_div_up(debt, WAD + system.params.liquidation_penalty, step.price)  # R11
    if seized != min(coll, cap) or surplus != coll - seized:
        bad.append("I7: seized or surplus off the cap")
    wb, wa = pre["weth"]["balances"], post["weth"]["balances"]
    for a in (set(wb) | set(wa)) - CORE:
        want = surplus * (a == owner) + system.params.gas_reserve * (a == caller)
        if wa.get(a, 0) - wb.get(a, 0) != want:
            bad.append(f"I7: WETH delta of {a}")
    return bad


# ---- I5: one redemption ----
def check_I5(system, step) -> list[str]:  # noqa: ANN001, N802, C901, PLR0912 — System, Step
    if step.op != "redeem" or step.error is not None:
        return []
    p = system.params
    pre, post = step.pre, step.post
    (red,) = _events(step, "redemption", "Redeemed")
    amount, fee_rate, iterations = red[2], red[5], red[6]
    upper, lower = step.args[3], step.args[4]
    price, index = step.price, post["vault"]["index"]
    lc, ld = pre["vault"]["LColl"], pre["vault"]["LDebt"]
    redeemed = _events(step, "vault", "PositionRedeemed")
    bad = []
    # the positions redeemed from
    for e in redeemed:
        pid = e[1]
        q = post["vault"]["positions"][pid]
        if q["status"] == STATUS_CLOSED_BY_REDEMPTION:
            continue
        c, n = _eff(q, post["vault"]["LColl"], post["vault"]["LDebt"])
        debt = mul_div_up(n, index, RAY)
        if debt < p.min_debt or c * price < p.mcr * debt:
            bad.append(f"I5: position {pid} left below MIN_DEBT or MCR")
    # the visits, rebuilt from the list before the call (nothing redistributes inside it)
    nodes = pre["sorted"]["nodes"]
    visits, cur = [], pre["sorted"]["tail"]
    while cur and len(visits) < iterations:
        visits.append(cur)
        cur = nodes[cur]["prev"]
    partial = [e for e in redeemed if not e[5]]
    if len(partial) > 1 or (partial and (not visits or partial[0][1] != visits[-1])):
        bad.append("I5: more than one partial, or not the last visited")
    by_id = {e[1]: e for e in redeemed}
    if [i for i in visits if i in by_id] != [e[1] for e in redeemed] or len(visits) != iterations:
        bad.append("I5: PositionRedeemed ids are not the visits in order")
        return bad
    remaining = amount
    for j, vid in enumerate(visits):
        c, n = _eff(pre["vault"]["positions"][vid], lc, ld)
        debt = mul_div_up(n, index, RAY)
        below = c * price < p.mcr * debt
        if vid in by_id:
            remaining -= by_id[vid][2]
            continue
        if j < len(visits) - 1:
            if not below:
                bad.append(f"I5: visit {vid} before the last was not below MCR")
            continue
        if below:
            continue  # (a)
        # (b): a cancelled partial for one of three reasons, nothing changed
        if remaining >= debt or post["vault"]["positions"][vid] != pre["vault"]["positions"][vid]:
            bad.append(f"I5: the last visit {vid} stopped illegitimately")
            continue
        d = min(remaining, debt - p.min_debt)
        reason = d == 0
        if not reason:
            dn = mul_div_down(d, RAY, index)
            out = mul_div_down(d, WAD - fee_rate, price)
            reason = (c - out) * price < p.mcr * mul_div_up(n - dn, index, RAY)
            if not reason:
                found = system.sorted.find((c - out, n - dn), vid, vid, upper, lower)[0]
                reason = not found
        if not reason:
            bad.append(f"I5: the last visit {vid} stopped without a legitimate reason")
    return bad


# ---- I8 ----
def check_I8(system) -> list[str]:  # noqa: ANN001, N802
    """§10.3's inequalities (the claims row waits for the ShutdownModule)."""
    v, pool = system.vault, system.pool
    bad = []
    if not v.settled:
        pc = pn = 0
        for pid, q in v.positions.items():
            if q.status == STATUS_ACTIVE:
                c, n = v.effective(pid)
                pc, pn = pc + c - q.coll, pn + n - q.norm_debt
        if pc > v.pending_coll or pn > v.pending_norm_debt:
            bad.append("I8: pending rewards exceed the pending buckets")
    depositors = list(pool.deposits)
    if sum(pool.compounded_deposit(a) for a in depositors) > pool.total_deposits:
        bad.append("I8: compounded deposits exceed totalDeposits")
    gains = [pool.gains(a) for a in depositors]
    if sum(g[0] for g in gains) > pool.coll_gains_balance:
        bad.append("I8: collateral gains exceed collGainsBalance")
    if sum(g[1] for g in gains) > pool.interest_gains_balance:
        bad.append("I8: interest gains exceed interestGainsBalance")
    return bad


def unwind(system) -> list[str]:  # noqa: ANN001, C901 — System
    """I8's unwind procedure on a copy: every claim paid out, each residue named."""
    from model.protocol.errors import ProtocolError  # noqa: PLC0415

    s = system.copy()
    v, pool, led = s.vault, s.pool, s.ledger
    bad = []
    now = s.now
    owners = {pid: q.owner for pid, q in v.positions.items() if q.status == STATUS_ACTIVE}

    def must(what: str, fn) -> None:  # noqa: ANN001
        try:
            fn()
        except ProtocolError as e:
            bad.append(f"I8 unwind: {what} reverted {type(e).__name__}")

    if not v.settled:
        must("accrue", lambda: s.accrue("unwinder", now=now))
        for pid, owner in owners.items():
            s.token.mint(owner, v.debt_of(pid))  # deal
        for a in sorted(pool.deposits):
            must(f"claimGains({a})", lambda a=a: s.claim_gains(a, now=now))
        for a in sorted(pool.deposits):
            must(f"withdraw({a})", lambda a=a: s.withdraw(a, 2**256 - 1, now=now))
        for pid, owner in owners.items():
            must(f"close({pid})", lambda pid=pid, owner=owner: s.close(owner, pid, now=now))
    else:
        for pid, owner in owners.items():
            must(
                f"reclaimGasReserve({pid})",
                lambda pid=pid, owner=owner: s.reclaim_gas_reserve(owner, pid, now=now),
            )
    w, t = s.weth, s.token
    dw, dt = s.donated["weth"], s.donated["token"]
    residue = [
        ("VaultManager WETH", w.balance_of("vault"), dw.get("vault", 0) + v.pending_coll),
        ("StabilityPool WETH", w.balance_of("pool"), dw.get("pool", 0) + pool.coll_gains_balance),
        (
            "StabilityPool token",
            t.balance_of("pool"),
            dt.get("pool", 0)
            + pool.interest_gains_balance
            + (pool.total_deposits if led.settled else 0),
        ),
        ("DeficitLedger WETH", w.balance_of("ledger"), dw.get("ledger", 0) + led.recovered_coll),
        ("DeficitLedger token", t.balance_of("ledger"), dt.get("ledger", 0) + led.reserve),
        ("ShutdownModule WETH", w.balance_of("shutdown"), dw.get("shutdown", 0) + s.claim_coll),
    ]
    bad += [f"I8 unwind {n}: {a} != {e}" for n, a, e in residue if a != e]
    if any(q.status == STATUS_ACTIVE for q in v.positions.values()):
        bad.append("I8 unwind: a position is still active")
    if pool.deposits and not v.settled:  # the pool step belongs to the live and window phases
        bad.append("I8 unwind: a deposit is still open")
    return bad


# ---- I9, I12: what an operation may do with the oracle ----
PRICE_REQUIRED = {
    # op -> the errors §5 checks before the price fetch
    "open": {"SystemShutdown", "DebtBelowMinimum", "CollateralTooLarge"},
    "borrow": {"SystemShutdown", "ZeroAmount", "PositionNotActive", "NotOwner"},
    "withdrawCollateral": {"SystemShutdown", "ZeroAmount", "PositionNotActive", "NotOwner"},
    "liquidate": {"SystemShutdown", "PositionNotActive"},
    "redeem": {"SystemShutdown", "ZeroAmount", "ZeroIterations"},
}
PRICE_NOT_USED = frozenset(
    (
        "repay",
        "addCollateral",
        "close",
        "deposit",
        "withdraw",
        "claimGains",
        "cover",
        "accrue",
        "reclaimGasReserve",
    )
)


def check_I12(step) -> list[str]:  # noqa: ANN001, N802 — Step
    err = type(step.error).__name__ if step.error is not None else None
    if step.op in PRICE_NOT_USED:
        if step.oracle_reads or err == "PriceUnusable":
            return [f"I12: {step.op} read the oracle"]
        return []
    allowed = PRICE_REQUIRED.get(step.op)
    if allowed is None or step.usable:
        return []
    if err is None:
        return [f"I12: {step.op} executed on an unusable price"]
    if err != "PriceUnusable" and err not in allowed:
        return [f"I12: {step.op} reverted {err} instead of PriceUnusable"]
    return []


def check_I9_liveness(system, step) -> list[str]:  # noqa: ANN001, N802, C901, PLR0911
    """A rescue call reverts only for a precondition it did not meet (live and window)."""
    if step.op not in ("repay", "addCollateral", "close") or step.error is None:
        return []
    err = type(step.error).__name__
    pre, p = step.pre, system.params
    v = pre["vault"]
    pid = step.args[0]
    q = v["positions"].get(pid)
    if err == "SystemSettled":
        return [] if v["settled"] else ["I9: SystemSettled before settlement"]
    if err == "ZeroAmount":
        return [] if step.op != "close" and step.args[1] == 0 else ["I9: ZeroAmount"]
    if err == "PositionNotActive":
        return [] if q is None or q["status"] != STATUS_ACTIVE else ["I9: PositionNotActive"]
    if err == "NotOwner":
        return [] if step.op == "close" and q["owner"] != step.caller else ["I9: NotOwner"]
    if err in ("StaleHint", "CollateralTooLarge"):
        return []  # hints not exact, or the 2^128 − 1 cap
    if err == "WethTransferFailed":  # "caller holds the tokens": addCollateral pulls WETH
        held = pre["weth"]["balances"].get(step.caller, 0)
        if step.op == "addCollateral" and held < step.args[1]:
            return []
        return ["I9: WethTransferFailed with the WETH held"]
    _, n = _eff(q, v["LColl"], v["LDebt"])
    debt = mul_div_up(n, _accrued_index(v, step.now, p.rate_per_second), RAY)
    have = pre["token"]["balances"].get(step.caller, 0)
    if err == "RepayExceedsMaximum":
        return [] if step.op == "repay" and step.args[1] > debt - p.min_debt else ["I9: repay cap"]
    if err == "InsufficientBalance":
        need = step.args[1] if step.op == "repay" else debt
        return [] if have < need else ["I9: InsufficientBalance with the tokens held"]
    return [f"I9: {step.op} reverted {err}"]


# ---- I11 ----
def check_I11(system) -> list[str]:  # noqa: ANN001, N802
    p, v, pool, r, o = system.params, system.vault, system.pool, system.redemption, system.oracle
    got = {
        "MCR": v.mcr,
        "MIN_DEBT": v.min_debt,
        "GAS_RESERVE": v.gas_reserve,
        "RATE_PER_SECOND": v.rate_per_second,
        "POOL_SHARE_BPS": v.pool_share_bps,
        "POOL_HOOK_GAS": v.pool_hook_gas,
        "MAX_HINT_STEPS": system.sorted.max_hint_steps,
        "LIQUIDATION_PENALTY": pool.liquidation_penalty,
        "MIN_DEPOSIT": pool.min_deposit,
        "REDEMPTION_FEE_FLOOR": r.fee_floor,
        "BETA": r.beta,
        "BASE_RATE_DECAY": r.base_rate_decay,
        "STALENESS": o.staleness,
        "GRACE_PERIOD": o.grace_period,
        "MIN_PRICE": o.min_price,
        "MAX_PRICE": o.max_price,
        "ORACLE_GAS": o.oracle_gas,
        "ORACLE_POST_FAILURE_GAS": o.oracle_post_failure_gas,
        "FEED_DECIMALS": o.feed_decimals,
    }
    bad = [f"I11: {k} changed" for k, x in got.items() if x != getattr(p, k.lower())]
    wired = (
        v.strategy is pool
        and v.has_pool
        and r.vault is v
        and pool.bank is v
        and system.ledger.bank is v
        and v.sorted is system.sorted
    )
    if not wired:
        bad.append("I11: the wiring changed")
    return bad


# ---- I13 ----
def check_I13(system, ghost: Ghost) -> list[str]:  # noqa: ANN001, N802
    v, srt = system.vault, system.sorted
    bad = list(ghost.insertion_violations)
    order = srt.order()
    if set(order) != set(ghost.members):
        return [*bad, "I13: the insertion records do not match the list"]
    for pid in order:  # condition 1
        q = v.positions[pid]
        want = (
            q.coll + mul_div_down(q.stake, v.l_coll - q.snap_l_coll, DP),
            q.norm_debt + mul_div_down(q.stake, v.l_debt - q.snap_l_debt, DP),
        )
        if v.sort_key(pid) != want:
            bad.append(f"I13 condition 1: sortKey({pid})")
    exact = all(_is_exact(v, i, ghost.members[i]) for i in order)
    for a, b in zip(order, order[1:], strict=False):
        if exact:
            if not precedes(v.sort_key(a), a, v.sort_key(b), b):
                bad.append(f"I13: exact regime, {a} does not precede {b}")
        else:
            ma, mb = ghost.members[a], ghost.members[b]
            if ma.h - ma.iota > mb.h + mb.iota:
                bad.append(f"I13: pair ({a}, {b}) outside the hidden-key tolerance")
    return bad


# ---- I14 ----
def check_I14(system, ghost: Ghost) -> list[str]:  # noqa: ANN001, N802
    snap = system.snapshot()
    rebuilt = ghost.replay.state()
    bad = []
    for section in rebuilt:
        if rebuilt[section] != snap[section]:
            fields_ = rebuilt[section]
            diff = sorted(
                k
                for k in set(fields_) | set(snap[section])
                if fields_.get(k) != snap[section].get(k)
            )
            bad.append(f"I14: {section} rebuilt from events differs in {diff}")
    return bad


# ---- I15: one redemption ----
def check_I15(system, step) -> list[str]:  # noqa: ANN001, N802
    if step.op != "redeem":
        return []
    err = type(step.error).__name__ if step.error is not None else None
    before_gate = ("SystemShutdown", "ZeroAmount", "ZeroIterations", "PriceUnusable")
    if err in before_gate or err == "AuctionCallbackActive":
        return []
    pre, p = step.pre, system.params
    v = pre["vault"]
    index = _accrued_index(v, step.now, p.rate_per_second)  # the call's accrual
    live = v["activeCount"] > 0
    c, d = _system_coll(pre), _system_debt(pre, index)
    gate = live and d > 0 and c * step.price < p.critical_tcr * d
    if gate != (err == "TCRBelowCritical"):
        return [f"I15: gate {gate} but the call {'reverted ' + err if err else 'passed it'}"]
    return []


# ---- everything ----
def check_invariants(system, *, with_unwind: bool = False) -> list[str]:  # noqa: ANN001
    ghost = system.ghost
    if ghost is None:
        raise ValueError("check_invariants needs a System built with record=True")
    bad = check_I1(system) + check_I2(system, ghost.counters)
    bad += check_I3_system(system, ghost.exact) + check_I8(system) + check_I11(system)
    bad += check_I13(system, ghost) + check_I14(system, ghost)
    step = system.last
    if step is not None:
        bad += check_liquidation(system, step) + check_I5(system, step) + check_I12(step)
        bad += check_I9_liveness(system, step) + check_I15(system, step)
    if with_unwind:
        bad += unwind(system)
    return bad
