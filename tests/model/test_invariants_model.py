"""`System.check_invariants()` (P22): every check holds on a correct run, and each one reports the
violation it exists for — the state or the recorded step is corrupted on purpose, the way a buggy
implementation would leave it."""

from __future__ import annotations

import dataclasses

import pytest

from model import invariants as inv
from model.protocol import errors as er
from model.protocol.math import RAY, WAD
from model.protocol.oracle_adapter import FeedRound
from model.protocol.system import System


def _run() -> System:
    """Opens, a pool deposit, a partial-offset liquidation with redistribution, a redemption."""
    s = System(record=True)
    t = s.now
    s.set_price(2_000 * WAD, t)
    for a in ("alice", "bob", "carol", "liq"):
        s.fund(a, 10**24)
    s.open_position("alice", 3 * WAD, 3_333 * WAD, now=t)
    s.open_position("bob", 10 * WAD, 5_000 * WAD, now=t + 60)
    s.open_position("carol", 20 * WAD, 5_000 * WAD, now=t + 60)
    s.deposit("bob", 3_000 * WAD, now=t + 60)
    s.set_price(1_200 * WAD, t + 120)
    s.liquidate("liq", 1, now=t + 120)
    assert s.check_invariants() == []
    return s


def _has(bad: list[str], prefix: str) -> bool:
    return any(b.startswith(prefix) for b in bad)


def test_a_correct_run_holds_everything_including_the_unwind_in_both_phases() -> None:
    s = _run()
    t = s.now
    s.redeem("carol", 1_000 * WAD, 10, WAD, now=t + 80)
    assert s.check_invariants() == []
    s.claim_gains("bob", now=t + 100)
    s.cover("x", now=t + 100)
    assert s.check_invariants(with_unwind=True) == []
    s.trigger_shutdown(now=t + 200)
    s.settle(now=t + 300)
    s.reclaim_gas_reserve("bob", 2, now=t + 400)
    assert s.check_invariants(with_unwind=True) == []


def test_check_invariants_needs_a_recording_system() -> None:
    with pytest.raises(ValueError, match="record=True"):
        inv.check_invariants(System())


def test_donations_are_inert_and_tracked() -> None:
    s = _run()
    s.transfer_weth("carol", "vault", 5, now=s.now)
    s.transfer("bob", "pool", 7, now=s.now)
    assert s.check_invariants() == []
    assert s.donated == {"weth": {"vault": 5}, "token": {"pool": 7}}


def test_I1_reports_an_untracked_balance_change() -> None:
    s = _run()
    s.weth.balances["vault"] += 1  # WETH appears with no claim and no donation
    s.token.balances["ledger"] = s.token.balances.get("ledger", 0) + 1
    bad = inv.check_I1(s)
    assert _has(bad, "I1 VaultManager WETH") and _has(bad, "I1 DeficitLedger token")


def test_I1_supporting_identities() -> None:
    s = _run()
    s.vault.total_stakes += 1
    s.vault.total_collateral += 1
    assert _has(inv.check_I1(s), "I1 totalStakes") and _has(inv.check_I1(s), "I1 totalCollateral")


def test_I2_reports_supply_outside_the_drift_bound_on_both_sides() -> None:
    s = _run()
    s.token.mint("eve", 10**6)  # supply backed by nothing, beyond −gN·RAY
    assert _has(inv.check_I2(s, s.ghost.counters), "I2: E = ")
    s.token.burn("eve", 10**6)
    s.vault.total_norm_debt += 10**9  # debt with no supply
    assert _has(inv.check_I2(s, s.ghost.counters), "I2: E = ")


def test_I2_is_not_defined_after_settlement() -> None:
    s = _run()
    s.trigger_shutdown(now=s.now)
    s.settle(now=s.now)
    s.token.mint("eve", 10**30)
    assert inv.check_I2(s, s.ghost.counters) == []


def test_I2_counters_follow_chg011() -> None:
    c = inv.Counters()
    c.update(
        [
            ("vault", ("InterestAccrued", 0, 0, 0, 0, 0)),
            ("vault", ("PositionUpdated", 1, 0, 0, 0, 0, 0, 1, 1)),  # open: X
            ("vault", ("PositionUpdated", 1, 0, 0, 0, 0, 0, 1, 2)),  # addCollateral: nothing
            ("vault", ("PositionUpdated", 1, 0, 0, 0, 0, 0, 2, 6)),  # close: Y
            ("vault", ("PositionRedeemed", 2, 1, 1, 0, False)),  # partial: X
            ("vault", ("PositionRedeemed", 3, 1, 1, 0, True)),  # full: Y
            ("vault", ("Liquidated", 4, "o", "l", 10, 1, 5, 0, 0, 1, 1)),  # partial offset: X
            ("vault", ("Liquidated", 5, "o", "l", 10, 1, 10, 0, 0, 0, 1)),  # full offset: Y
            ("vault", ("Liquidated", 6, "o", "l", 10, 1, 0, 1, 1, 2, 1)),  # no offset: nothing
            ("ledger", ("DeficitRecorded", 1, 1, 2)),  # no stakes: Y
            ("ledger", ("DeficitRecorded", 1, 0, 1)),  # auction shortfall: nothing
        ]
    )
    assert (c.n, c.x, c.y) == (1, 3, 4)


def test_I3_system_reports_pool_insolvency() -> None:
    s = _run()
    s.pool.total_deposits -= 1
    assert _has(inv.check_I3_system(s, s.ghost.exact), "I3 sum of compounded deposits")


def test_I4_I6_I7_report_a_corrupted_liquidation() -> None:
    s = _run()
    step = s.last
    assert step.op == "liquidate" and inv.check_liquidation(s, step) == []

    def with_event(name: str, fn) -> list[str]:  # noqa: ANN001
        events = [(src, fn(e) if e[0] == name else e) for src, e in step.events]
        return inv.check_liquidation(s, dataclasses.replace(step, events=events))

    bad = with_event("PoolLiquidation", lambda e: (*e[:5], e[5] + 1, *e[6:]))  # surplus + 1
    assert _has(bad, "I4 A1") and _has(bad, "I6: coll") and _has(bad, "I7: seized")
    bad = with_event("Liquidated", lambda e: (*e[:8], e[8] + 1, *e[9:]))  # normRest + 1
    assert _has(bad, "I6: n != normAbsorbed")
    bad = with_event("Liquidated", lambda e: (*e[:9], 2, e[10]))  # claims the deficit path
    assert _has(bad, "I6: the remainder was not recorded")
    post = dataclasses.replace(step).post
    moved = {**post, "weth": {**post["weth"], "balances": {**post["weth"]["balances"]}}}
    moved["weth"]["balances"]["liq"] += 1  # the liquidator got more than GAS_RESERVE
    assert _has(inv.check_liquidation(s, dataclasses.replace(step, post=moved)), "I7: WETH delta")


def test_I4_A3_full_absorption_cannot_lower_tcr() -> None:
    s = System(record=True)
    t = s.now
    s.set_price(2_000 * WAD, t)
    for a in ("alice", "bob", "liq"):
        s.fund(a, 10**24)
    s.open_position("alice", 3 * WAD, 3_333 * WAD, now=t)
    s.open_position("bob", 30 * WAD, 20_000 * WAD, now=t)
    s.deposit("bob", 10_000 * WAD, now=t)
    s.set_price(1_200 * WAD, t + 1)
    s.liquidate("liq", 1, now=t + 1)
    step = s.last
    assert inv.check_liquidation(s, step) == []
    post = {**step.post, "vault": {**step.post["vault"]}}
    post["vault"]["totalNormDebt"] += 10**23  # D after the call jumps: TCR fell
    post["vault"]["totalCollateral"] = step.pre["vault"]["totalCollateral"] - 3 * WAD
    bad = inv.check_liquidation(s, dataclasses.replace(step, post=post))
    assert _has(bad, "I4 A3")


def test_I5_reports_an_unhealthy_redeemed_position_and_an_early_stop() -> None:
    s = _run()
    s.redeem("carol", 1_000 * WAD, 10, WAD, now=s.now + 80)
    step = s.last
    assert inv.check_I5(s, step) == []
    post = {
        **step.post,
        "vault": {**step.post["vault"], "positions": {**step.post["vault"]["positions"]}},
    }
    pid = next(e[1] for _, e in step.events if e[0] == "PositionRedeemed")
    post["vault"]["positions"][pid] = {**post["vault"]["positions"][pid], "coll": 1}
    assert _has(inv.check_I5(s, dataclasses.replace(step, post=post)), f"I5: position {pid}")
    # the same call reported as visiting one node more: its partial is no longer the last visit
    events = [
        (src, (*e[:6], e[6] + 1, e[7]) if e[0] == "Redeemed" else e) for src, e in step.events
    ]
    bad = inv.check_I5(s, dataclasses.replace(step, events=events))
    assert _has(bad, "I5: more than one partial, or not the last visited")


def test_I5_accepts_a_cancelled_partial_at_min_debt() -> None:
    s = System(record=True)
    t = s.now
    s.set_price(2_000 * WAD, t)
    for a in ("alice", "bob"):
        s.fund(a, 10**24)
    s.open_position("alice", 5 * WAD, 2_000 * WAD, now=t)  # the tail, at exactly MIN_DEBT: d == 0
    s.open_position("bob", 10 * WAD, 3_000 * WAD, now=t)
    with pytest.raises(er.NothingRedeemed):
        s.redeem("bob", 100 * WAD, 5, WAD, now=t)
    assert inv.check_I5(s, s.last) == []  # reverted: nothing to check
    assert s.check_invariants() == []


def test_I8_reports_pending_rewards_above_the_buckets() -> None:
    s = _run()
    s.vault.pending_coll = 0
    assert _has(inv.check_I8(s), "I8: pending rewards")


def test_unwind_reports_a_stuck_exit_and_a_missing_residue() -> None:
    s = _run()
    s.weth.balances["vault"] = 0  # the vault cannot pay any close
    bad = inv.unwind(s)
    assert any("close(" in b and "WethTransferFailed" in b for b in bad)
    assert s.weth.balances["vault"] == 0  # the unwind ran on a copy
    s = _run()
    s.pool.coll_gains_balance += 1  # a residue claimed that is not there
    assert _has(inv.unwind(s), "I8 unwind StabilityPool WETH")


def test_I9_reports_a_rescue_revert_with_its_precondition_met() -> None:
    s = _run()
    s.transfer("carol", "bob", 4_999 * WAD, now=s.now)  # carol keeps 1 WAD
    with pytest.raises(er.InsufficientBalance):
        s.repay("carol", 3, 2_000 * WAD, now=s.now)
    assert inv.check_I9_liveness(s, s.last) == []  # carol does not hold that much
    fake = dataclasses.replace(s.last, args=(3, WAD, 0, 0))  # she holds 1 WAD: the revert is a bug
    assert _has(inv.check_I9_liveness(s, fake), "I9: InsufficientBalance")
    fake = dataclasses.replace(s.last, error=er.PriceUnusable())
    assert _has(inv.check_I9_liveness(s, fake), "I9: repay reverted PriceUnusable")


def test_I12_price_required_operations_stop_on_an_unusable_price() -> None:
    s = _run()
    s.set_feed(None)  # the price feed's call fails
    with pytest.raises(er.PriceUnusable):
        s.borrow("bob", 2, WAD, now=s.now)
    assert inv.check_I12(s.last) == [] and s.check_invariants() == []
    with pytest.raises(er.NotOwner):  # a check before the fetch wins
        s.borrow("carol", 2, WAD, now=s.now)
    assert inv.check_I12(s.last) == []
    s.repay("bob", 2, WAD, now=s.now)  # a rescue path never reads the oracle
    assert s.last.oracle_reads == 0 and inv.check_I12(s.last) == []
    executed = dataclasses.replace(s.last, op="borrow", error=None, usable=False)
    assert _has(inv.check_I12(executed), "I12: borrow executed")
    wrong = dataclasses.replace(executed, error=er.IcrBelowMcr())
    assert _has(inv.check_I12(wrong), "I12: borrow reverted IcrBelowMcr")
    read = dataclasses.replace(s.last, oracle_reads=1)
    assert _has(inv.check_I12(read), "I12: repay read the oracle")


def test_I11_reports_a_changed_parameter_and_rewiring() -> None:
    s = _run()
    s.vault.mcr += 1
    s.redemption.vault = System().vault
    bad = inv.check_I11(s)
    assert "I11: MCR changed" in bad and "I11: the wiring changed" in bad


def test_I13_reports_a_misordered_list_and_records() -> None:
    s = _run()
    assert inv.check_I13(s, s.ghost) == []
    order = s.sorted.order()
    assert len(order) == 2
    a, b = order
    s.sorted.nodes = {b: [0, a], a: [b, 0]}  # swap the two members
    s.sorted.head, s.sorted.tail = b, a
    assert _has(inv.check_I13(s, s.ghost), "I13: pair")
    s.ghost.members.pop(a)
    assert inv.check_I13(s, s.ghost) == ["I13: the insertion records do not match the list"]


def test_I13_exact_regime_is_strict() -> None:
    s = System(record=True)
    t = s.now
    s.set_price(2_000 * WAD, t)
    s.fund("alice", 10**24)
    s.open_position("alice", 10 * WAD, 3_000 * WAD, now=t)
    s.open_position("alice", 10 * WAD, 3_000 * WAD, now=t)  # a tie: lower id first
    assert inv.check_I13(s, s.ghost) == []
    s.sorted.nodes = {2: [0, 1], 1: [2, 0]}
    s.sorted.head, s.sorted.tail = 2, 1
    assert _has(inv.check_I13(s, s.ghost), "I13: exact regime")


def test_I14_reports_a_state_change_with_no_event() -> None:
    s = _run()
    s.vault.l_coll += 1
    s.redemption.base_rate = 5
    bad = inv.check_I14(s, s.ghost)
    assert _has(bad, "I14: vault") and _has(bad, "I14: redemption")


def test_I15_gate_matches_the_revert_both_ways() -> None:
    s = _run()
    s.redeem("carol", 100 * WAD, 10, WAD, now=s.now)
    step = s.last
    assert inv.check_I15(s, step) == []
    gated = dataclasses.replace(step, price=10**18)  # at that price the gate holds
    assert _has(inv.check_I15(s, gated), "I15: gate True")
    blocked = dataclasses.replace(step, error=er.TCRBelowCritical())
    assert _has(inv.check_I15(s, blocked), "I15: gate False")
    early = dataclasses.replace(step, error=er.ZeroAmount())
    assert inv.check_I15(s, early) == []


def test_oracle_failure_clock_and_recovery_are_rebuilt_from_events() -> None:
    s = _run()
    t = s.now
    s.set_sequencer(FeedRound(1, 1, 1))  # down; liquidate fetches and reverts — nothing persists
    with pytest.raises(er.PriceUnusable):
        s.liquidate("liq", 2, now=t)
    assert s.oracle.failure_start == 0 and s.check_invariants() == []


def test_accrued_index_matches_the_vault() -> None:
    s = _run()
    snap = s.snapshot()["vault"]
    s.vault.now = s.now + 3_600
    rate = s.params.rate_per_second
    assert inv._accrued_index(snap, s.now + 3_600, rate) == s.vault.current_index()
    assert inv._accrued_index({**snap, "shutdown": 1}, s.now + 9, rate) == snap["index"] >= RAY
