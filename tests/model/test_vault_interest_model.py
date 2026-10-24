"""Interest accrual in model/protocol/vault.py (P15) against spec/vectors/interest.json, the accrual
rules of §6.2, and I2 (§10.2) over long horizons. The contract runs the same vectors in
contracts/test/unit/VaultManagerInterestTest."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from model.math import RAY, Overflow
from model.protocol import vault as vm

VECTORS = json.loads(Path("spec/vectors/interest.json").read_text())["vectors"]
RATE = 1_547_125_957_863_212_449
MAX_RATE = 21_979_553_151_239_153_028
MCR, MIN_DEBT, GAS, PRICE = 11 * 10**17, 2_000 * 10**18, 375 * 10**14, 2_000 * 10**18


def vault(
    rate: int = RATE, pool_share: int = 7_500, has_pool: bool = True, deposits: int = 0
) -> vm.Vault:
    v = vm.Vault(
        MCR,
        MIN_DEBT,
        GAS,
        1_000,
        lambda: (PRICE, True),
        rate_per_second=rate,
        pool_share_bps=pool_share,
        has_pool=has_pool,
        accepts_interest=lambda: deposits >= 10**18,
    )
    for who in ("alice", "bob"):
        v.weth[who] = 10**30
    return v


@pytest.mark.parametrize("vec", VECTORS[:3], ids=[v["name"] for v in VECTORS[:3]])
def test_vectors_accrue(vec: dict) -> None:
    i = vec["inputs"]
    b = i["variant"] == "B"
    v = vault(
        int(i["RATE_PER_SECOND"]),
        int(i["POOL_SHARE_BPS"]),
        not b,
        0 if b else int(i["totalDeposits"]),
    )
    v.index, v.last_accrual, v.total_norm_debt = (
        int(i["index"]),
        int(i["lastAccrual"]),
        int(i["totalNormDebt"]),
    )
    step = vec["steps"][0]
    v.now = int(step["t"])
    v.accrue()
    r = step["result"]
    assert v.events[-1] == (
        "InterestAccrued",
        int(r["index"]),
        int(r["interest"]),
        int(r["toPool"]),
        int(r["toReserve"]),
        v.now,
    )
    assert (v.pool_interest, v.ledger_reserve) == (int(r["toPool"]), int(r["toReserve"]))


def test_vector_frequency() -> None:
    e = VECTORS[3]["expected"]
    y = vault()
    y.now = 365 * 86_400
    y.accrue()
    d = vault()
    for day in range(1, 366):
        d.now = day * 86_400
        d.accrue()
    assert (y.index, d.index, y.index - d.index) == (
        int(e["indexYearly"]),
        int(e["indexDaily"]),
        int(e["difference"]),
    )


def test_vector_conversions() -> None:
    vec = VECTORS[4]
    index = int(vec["inputs"]["index"])
    v = vault()
    v.index = index
    v.open_position("alice", 10**27, 2_100 * 10**18, 0, 0)
    for s in vec["steps"]:
        amt, r = int(s["amount"]), s["result"]
        n0 = v.positions[1].norm_debt
        v.borrow("alice", 1, amt, 0, 0)
        up = v.positions[1].norm_debt - n0
        assert up == int(r["normFromBorrow_up"])
        assert -(-up * index // RAY) == int(r["debtOf(normFromBorrow)"])
        n0 = v.positions[1].norm_debt
        v.repay("alice", 1, amt, 0, 0)
        assert n0 - v.positions[1].norm_debt == int(r["normFromRepay_down"])


def test_accrue_rules() -> None:
    v = vault()
    v.now = 365 * 86_400
    v.accrue()  # no debt: the index still grows, nothing minted
    assert v.index == 1_050_000_000_000_000_000_011_578_354 and v.total_supply == 0
    n_events = len(v.events)
    v.accrue()  # same block: no-op
    assert len(v.events) == n_events
    v.open_position("alice", 10 * 10**18, 4_000 * 10**18, 0, 0)
    v.now += 100 * 86_400
    assert v.current_index() > v.index  # the view accrues without writing
    view = v.debt_of(1)
    v.accrue()
    assert v.debt_of(1) == view
    v.on_shutdown("shutdown")
    frozen = v.index
    v.now += 100 * 86_400
    v.accrue()
    assert v.index == frozen == v.current_index()


def test_max_dt_boundaries() -> None:
    for rate, max_dt in ((RATE, 74_509_693_419), (MAX_RATE, 5_244_687_241)):
        v = vault(rate)
        v.now = max_dt
        v.accrue()
        w = vault(rate)
        w.now = max_dt + 1
        with pytest.raises(Overflow):
            w.accrue()


@settings(max_examples=120, deadline=None)
@given(
    st.lists(st.tuples(st.integers(0, 4), st.integers(0, 8), st.integers(0, 2**64)), max_size=30)
)
def test_I2_long_horizon(ops: list[tuple[int, int, int]]) -> None:
    v = vault(deposits=10**19)
    n_cnt = x_cnt = y_cnt = 0
    for op, exp, r in ops:
        v.now += 1 + r % (10**exp)
        before = len(v.events)
        try:
            act = [i for i, p in v.positions.items() if p.status == vm.Status.ACTIVE]
            if op == 0 or not act:
                v.accrue()
                owed_debt = MIN_DEBT + r % (50_000 * 10**18)
                n = -(-owed_debt * RAY // v.index)
                owed = -(-n * v.index // RAY)
                v.open_position("alice", -(-MCR * owed // PRICE) + 10**18, owed_debt, 0, 0)
            elif op == 1:
                v.accrue()
            elif op == 2:
                pid = act[r % len(act)]
                v.borrow(v.positions[pid].owner, pid, 1 + r % (100 * 10**18), 0, 0)
            elif op == 3:
                pid = act[r % len(act)]
                v.accrue()
                room = v.debt_of(pid) - MIN_DEBT
                bal = v.stable.get(v.positions[pid].owner, 0)
                if min(room, bal) > 0:
                    v.repay(v.positions[pid].owner, pid, 1 + r % min(room, bal), 0, 0)
            else:
                pid = act[r % len(act)]
                owner = v.positions[pid].owner
                v.accrue()
                need = v.debt_of(pid) - v.stable.get(owner, 0)
                if need > 0 and v.stable.get("ledger", 0) >= need:
                    v.stable["ledger"] -= need
                    v.stable[owner] = v.stable.get(owner, 0) + need
                v.close(owner, pid)
        except vm.VaultError:
            pass
        for ev in v.events[before:]:
            if ev[0] == "InterestAccrued":
                n_cnt += 1
            elif ev[0] == "PositionUpdated":
                if ev[8] in (vm.OP_OPEN, vm.OP_BORROW, vm.OP_REPAY):
                    x_cnt += 1
                elif ev[8] == vm.OP_CLOSE:
                    y_cnt += 1
        e = v.total_norm_debt * v.index - v.total_supply * RAY
        if e >= 0:
            assert e < x_cnt * v.index + y_cnt * RAY if x_cnt + y_cnt else e == 0
        else:
            assert -e < n_cnt * RAY


def test_pool_share_rounds_down_with_a_remainder() -> None:
    """Review F6: the vectors' interest is divisible by 4, hiding R7 floor vs ceil."""
    v = vault(deposits=10**19)
    v.total_norm_debt = 10**24 + 1  # makes interest·7500 not divisible by 10_000
    v.now = 3_601
    v.accrue()
    _, _, interest, to_pool, to_reserve, _ = v.events[-1]
    assert (interest * 7_500) % 10_000 != 0, "a remainder exists"
    assert to_pool == interest * 7_500 // 10_000  # floor
    assert to_reserve == interest - to_pool
