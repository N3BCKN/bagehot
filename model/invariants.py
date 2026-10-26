"""Invariant checks on the Python model's state (docs/invariants.md). Integers for the protocol
inequalities; `fractions.Fraction` only for the exact pro-rata references I3's attribution bounds
are stated against (the invariant text keeps those out of Foundry for exactly that reason).

So far: I3 and U4 for the stability pool (P19). The other checks named in docs/invariants.md arrive
with the model parts they cover.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from fractions import Fraction

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
    # CHG-010 (proposed): the exact share of gains booked while
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
    """I3's two attribution bounds against the exact references; returns violations."""
    bad = []
    for a, e in exact.depositors.items():
        comp = pool.compounded_deposit(a)
        cg, ig = pool.gains(a)
        gap = e.share - comp
        if gap < 0 or gap > e.share * e.offsets / 10**27 + 1:
            bad.append(f"{a}: compounded {comp} vs exact {float(e.share):.6g}")
        if abs(e.coll_gain - cg) > e.coll_bound:
            bad.append(f"{a}: collateral gain {cg} vs exact {float(e.coll_gain):.6g}")
        if abs(e.interest_gain - ig) > e.interest_bound:
            bad.append(f"{a}: interest gain {ig} vs exact {float(e.interest_gain):.6g}")
    return bad


def check_I3_attribution_chg010(pool: StabilityPool, exact: Exact) -> list[str]:
    """CHG-010 (proposed, awaiting the human): I3's gain bounds plus the depositor's exact share of
    gains booked in scales §6.6.7 ignores. The compounded bound is unchanged."""
    bad = []
    for a, e in exact.depositors.items():
        cg, ig = pool.gains(a)
        if abs(e.coll_gain - cg) > e.coll_bound + e.coll_ignored:
            bad.append(f"{a}: collateral gain {cg} vs exact {float(e.coll_gain):.6g}")
        if abs(e.interest_gain - ig) > e.interest_bound + e.interest_ignored:
            bad.append(f"{a}: interest gain {ig} vs exact {float(e.interest_gain):.6g}")
    return bad
