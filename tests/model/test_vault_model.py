"""model/protocol/vault.py: the vector prefixes, error order, atomicity, I9 and identities.

The Solidity VaultManager replays the same vector prefixes in
contracts/test/vectors/VaultVectors.t.sol, and its unit tests mirror the error-order cases here.
"""

from __future__ import annotations

import glob
import json
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from model.protocol import errors as er
from model.protocol import vault as vm
from model.protocol.errors import ProtocolError
from model.protocol.math import RAY

MCR, MIN_DEBT, GAS = 11 * 10**17, 2_000 * 10**18, 375 * 10**14
PRICE = 2_000 * 10**18
POSITION_OPS = ("open", "addCollateral", "borrow", "repay", "close")


def fresh(price: int = PRICE, usable: bool = True, calls: list | None = None) -> vm.Vault:
    def source() -> tuple[int, bool]:
        if calls is not None:
            calls.append(1)
        return state["price"], state["usable"]

    state = {"price": price, "usable": usable}
    v = vm.Vault(MCR, MIN_DEBT, GAS, 30, source)
    v.price_state = state  # type: ignore[attr-defined]
    for who in ("alice", "bob", "carol"):
        v.weth[who] = 10**30
    return v


def min_coll(debt: int, price: int = PRICE) -> int:
    return -(-MCR * debt // price)


# ---------------------------------------------------------------- vectors


def system_vectors() -> list[tuple[str, dict]]:
    out = []
    for f in sorted(glob.glob("spec/vectors/*.json")):
        for v in json.loads(Path(f).read_text())["vectors"]:
            if v["level"] == "system":
                out.append((f"{f.split('/')[-1]}#{v['name']}", v))
    return out


@pytest.mark.parametrize(("name", "vec"), system_vectors(), ids=[n for n, _ in system_vectors()])
def test_vector_position_prefixes(name: str, vec: dict) -> None:
    p = vec["inputs"]["params"]
    price = {"value": PRICE}
    v = vm.Vault(
        int(p["MCR"]),
        int(p["MIN_DEBT"]),
        int(p["GAS_RESERVE"]),
        int(p["MAX_HINT_STEPS"]),
        lambda: (price["value"], True),
    )
    for a in vec["inputs"]["actors"]:
        v.weth[a] = int(vec["inputs"]["actorWeth"])
    steps = 0
    for s in vec["steps"]:
        if s["op"] not in POSITION_OPS:
            break
        if "price" in s:
            price["value"] = int(s["price"])
        hints = (int(s.get("upperHint", 0)), int(s.get("lowerHint", 0)))
        if s["op"] == "open":
            pid = v.open_position(s["caller"], int(s["coll"]), int(s["debt"]), *hints)
            assert pid == int(s["result"]["id"])
        elif s["op"] == "close":
            v.close(s["caller"], int(s["id"]))
        else:
            fn = {"addCollateral": v.add_collateral, "borrow": v.borrow, "repay": v.repay}[s["op"]]
            fn(s["caller"], int(s["id"]), int(s["amount"]), *hints)
        if "drift" in s:
            d = s["drift"]
            assert (v.index, v.total_norm_debt, v.total_supply) == (
                int(d["index"]),
                int(d["totalNormDebt"]),
                int(d["totalSupply"]),
            )
        steps += 1
    assert steps >= 1


def test_vector_prefix_totals() -> None:
    vecs = system_vectors()
    steps = 0
    for _, vec in vecs:
        for s in vec["steps"]:
            if s["op"] not in POSITION_OPS:
                break
            steps += 1
    assert (len(vecs), steps) == (23, 61)  # the same counts the Foundry replay asserts


# ---------------------------------------------------------------- operations and error order


def test_open_close_round_trip_and_events() -> None:
    v = fresh()
    pid = v.open_position("alice", 4 * 10**18, 4_000 * 10**18, 0, 0)
    assert pid == 1
    p = v.positions[1]
    assert (p.coll, p.norm_debt, p.stake, p.status) == (
        4 * 10**18,
        4_000 * 10**18,
        4 * 10**18,
        vm.Status.ACTIVE,
    )
    assert v.weth["vault"] == 4 * 10**18 + GAS
    assert v.total_supply == 4_000 * 10**18
    v.close("alice", 1)
    assert v.weth["vault"] == 0 and v.total_supply == 0 and v.active_count == 0
    assert v.events[-1] == (
        "PositionUpdated",
        1,
        0,
        0,
        0,
        0,
        0,
        int(vm.Status.CLOSED_BY_OWNER),
        vm.OP_CLOSE,
    )


def test_error_order_matches_the_contract() -> None:
    v = fresh()
    with pytest.raises(er.DebtBelowMinimum):
        v.open_position("alice", 2**128, 1, 0, 0)  # debt before the collateral cap
    with pytest.raises(er.CollateralTooLarge):
        v.open_position("alice", 2**128, 4_000 * 10**18, 0, 0)
    v.price_state["usable"] = False  # type: ignore[attr-defined]
    with pytest.raises(er.PriceUnusable):
        v.open_position("alice", 1, 4_000 * 10**18, 0, 0)  # price before the ICR check
    v.price_state["usable"] = True  # type: ignore[attr-defined]
    v.open_position("alice", 4 * 10**18, 4_000 * 10**18, 0, 0)
    with pytest.raises(er.ZeroAmount):
        v.withdraw_collateral("bob", 1, 0, 0, 0)  # a non-owner gets ZeroAmount first (§2.5)
    with pytest.raises(er.NotOwner):
        v.withdraw_collateral("bob", 1, 1, 0, 0)
    with pytest.raises(er.RepayExceedsMaximum):
        v.repay("bob", 1, 4_000 * 10**18, 0, 0)  # before the balance check
    with pytest.raises(er.InsufficientBalance):
        v.repay("bob", 1, 1, 0, 0)
    v.on_shutdown("shutdown")
    with pytest.raises(er.SystemShutdown):
        v.withdraw_collateral("alice", 1, 0, 0, 0)  # mode before ZeroAmount
    v.on_settlement("shutdown")
    with pytest.raises(er.SystemSettled):
        v.add_collateral("bob", 1, 0, 0, 0)
    with pytest.raises(er.NotOwner):
        v.reclaim_gas_reserve("bob", 1)
    v.reclaim_gas_reserve("alice", 1)
    with pytest.raises(er.PositionNotActive):
        v.reclaim_gas_reserve("alice", 1)


def test_icr_boundary_exactly_at_mcr() -> None:
    v = fresh()
    c = min_coll(4_000 * 10**18)
    v.open_position("alice", c, 4_000 * 10**18, 0, 0)
    with pytest.raises(er.IcrBelowMcr):
        v.open_position("bob", c - 1, 4_000 * 10**18, 0, 0)


def test_failed_operations_leave_no_trace() -> None:
    v = fresh()
    v.open_position("alice", 4 * 10**18, 4_000 * 10**18, 0, 0)
    before = (v.total_collateral, v.total_supply, dict(v.weth), len(v.events), v.sorted.order())
    v.weth["bob"] = 1  # cannot pay collateral + gas reserve: the WETH pull fails late
    with pytest.raises(er.WethTransferFailed):
        v.open_position("bob", 4 * 10**18, 4_000 * 10**18, 0, 0)
    assert (v.total_collateral, v.total_supply, len(v.events), v.sorted.order()) == (
        before[0],
        before[1],
        before[3],
        before[4],
    )
    assert v.next_id == 2


def test_I9_rescue_paths_never_read_the_price() -> None:
    calls: list = []
    v = fresh(calls=calls)
    v.open_position("alice", min_coll(4_000 * 10**18), 4_000 * 10**18, 0, 0)
    calls.clear()
    v.price_state.update(price=10**18, usable=False)  # type: ignore[attr-defined]
    v.add_collateral("bob", 1, 10**18, 0, 0)
    v.repay("alice", 1, 1_000 * 10**18, 0, 0)
    v.close("alice", 1)
    assert calls == []


# ---------------------------------------------------------------- identities over random sequences


def check_identities(v: vm.Vault, i2: bool = True) -> None:
    assert (
        v.weth.get("vault", 0) == v.total_collateral + v.pending_coll + v.active_count * GAS
    )  # I1
    if i2:  # exact at index RAY when no debt was added by hand (a real redistribution is backed)
        assert v.total_supply * RAY == v.total_norm_debt * v.index
    act = [p for p in v.positions.values() if p.status == vm.Status.ACTIVE]
    assert v.total_collateral == sum(p.coll for p in act)
    assert v.total_norm_debt == sum(p.norm_debt for p in act) + v.pending_norm_debt
    assert v.total_stakes == sum(p.stake for p in act)
    assert v.active_count == len(act) == v.sorted.size


@settings(max_examples=150, deadline=None)
@given(
    st.lists(st.tuples(st.integers(0, 5), st.integers(0, 2), st.integers(1, 10**30)), max_size=40)
)
def test_random_sequences_keep_I1_I2_and_identities(ops: list[tuple[int, int, int]]) -> None:
    v = fresh()
    who = ("alice", "bob", "carol")
    for op, w, amt in ops:
        caller = who[w]
        mine = [
            i for i, p in v.positions.items() if p.status == vm.Status.ACTIVE and p.owner == caller
        ]
        try:
            if op == 0 or not mine:
                debt = MIN_DEBT + amt % (50_000 * 10**18)
                v.open_position(caller, min_coll(debt) + amt % (20 * 10**18), debt, 0, 0)
            elif op == 1:
                v.add_collateral(who[(w + 1) % 3], mine[0], 1 + amt % (5 * 10**18), 0, 0)
            elif op == 2:
                v.withdraw_collateral(caller, mine[0], 1 + amt % (5 * 10**18), 0, 0)
            elif op == 3:
                v.borrow(caller, mine[0], 1 + amt % (5_000 * 10**18), 0, 0)
            elif op == 4:
                v.repay(caller, mine[0], 1 + amt % (5_000 * 10**18), 0, 0)
            else:
                v.close(caller, mine[0])
        except ProtocolError:
            pass  # an invalid step reverts as a whole
        check_identities(v)


def test_apply_pending_and_stake_after_a_snapshot() -> None:
    """As VaultManagerPendingTest: redistribution state set directly (P20 writes it for real)."""
    v = fresh()
    v.open_position("alice", 4 * 10**18, 4_000 * 10**18, 0, 0)
    v.l_coll, v.l_debt = 10**17, 50 * 10**18
    v.pending_coll, v.pending_norm_debt = 4 * 10**17 + 7, 200 * 10**18 + 9
    v.total_norm_debt += 200 * 10**18 + 9
    v.total_stakes_snapshot, v.total_collateral_snapshot = 4 * 10**18, 44 * 10**17
    v.weth["vault"] += 4 * 10**17 + 7
    assert v.effective(1) == (44 * 10**17, 4_200 * 10**18)
    v.add_collateral("bob", 1, 1, 0, 0)
    p = v.positions[1]
    assert ("RewardsApplied", 1, 4 * 10**17, 200 * 10**18) in v.events
    assert (p.coll, p.norm_debt, p.stake) == (44 * 10**17 + 1, 4_200 * 10**18, 4 * 10**18)
    assert (v.pending_coll, v.pending_norm_debt) == (7, 9)
    assert v.total_norm_debt == 4_200 * 10**18 + 9
    check_identities(v, i2=False)  # the pending debt here was set by hand, without its tokens
    pid = v.open_position("bob", 44 * 10**17, 4_000 * 10**18, 0, 0)
    assert v.positions[pid].stake == 4 * 10**18  # mulDivDown(4.4e18, 4e18, 4.4e18)


def test_checked_arithmetic_raises_overflow_like_the_contract() -> None:
    """Review V-2: where Solidity panics 0x11 the model raises Overflow, not a spec error."""
    from model.protocol.math import Overflow

    v = fresh()
    with pytest.raises(Overflow):
        v.open_position("alice", 10**18, 2**200, 0, 0)  # MCR · debtOf(n)
    v.open_position("alice", 4 * 10**18, 4_000 * 10**18, 0, 0)
    with pytest.raises(Overflow):
        v.add_collateral("bob", 1, 2**256 - 1, 0, 0)  # p.coll + amount
    with pytest.raises(Overflow):
        v.borrow("alice", 1, 2**255, 0, 0)  # MCR · debtOf(normDebt + dn)
    assert v.positions[1].norm_debt == 4_000 * 10**18  # nothing changed


def test_hooks_check_the_caller_before_state() -> None:
    v = fresh()
    with pytest.raises(er.Unauthorized):
        v.on_settlement("alice")  # not NotTriggered
    v.on_shutdown("shutdown")
    with pytest.raises(er.Unauthorized):
        v.on_shutdown("alice")  # not SystemShutdown


INDEX = 1_234_567_890_123_456_789_012_345_679


def test_rounding_directions_at_a_non_round_index() -> None:
    """Review V-1, mirroring VaultManagerRoundingTest: R2 up, R3 down, R1 up."""
    v = fresh()
    v.index = INDEX
    debt = 4_000 * 10**18
    v.open_position("alice", 10 * 10**18, debt, 0, 0)
    assert v.positions[1].norm_debt == debt * RAY // INDEX + 1  # R2 ceil
    n0 = v.positions[1].norm_debt
    v.repay("alice", 1, 1_000 * 10**18 + 7, 0, 0)
    assert n0 - v.positions[1].norm_debt == (1_000 * 10**18 + 7) * RAY // INDEX  # R3 floor
    n1 = v.positions[1].norm_debt
    v.repay("alice", 1, 1, 0, 0)
    assert v.positions[1].norm_debt == n1  # dn == 0 for an amount below index/RAY
    assert v.debt_of(1) == -(-v.positions[1].norm_debt * INDEX // RAY)  # R1 ceil
