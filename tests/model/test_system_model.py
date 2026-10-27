"""`System` (P22): one transaction per operation across every contract model, explicit time, the
shared event log with token `Transfer`s, the canonical snapshot, and the stand-in shutdown hooks."""

from __future__ import annotations

import json

import pytest

from model.protocol import errors as er
from model.protocol.events import EVENTS, ZERO, well_formed
from model.protocol.math import WAD
from model.protocol.oracle_adapter import FeedRound
from model.protocol.system import SHUTDOWN, Params, System

E18 = WAD


def _sys(record: bool = False) -> System:
    s = System(record=record)
    s.set_price(2_000 * E18, s.now)
    for a in ("alice", "bob", "carol", "liq"):
        s.fund(a, 10**24)
    return s


def test_params_from_spec_names_ignores_b_and_keeps_defaults() -> None:
    p = Params.from_spec({"MCR": "1200000000000000000", "BUFFER": "1", "MIN_DEPOSIT": 2 * E18})
    assert (p.mcr, p.min_deposit, p.min_debt) == (12 * 10**17, 2 * E18, 2_000 * E18)


def test_fund_mints_weth_with_a_transfer_from_zero() -> None:
    s = System()
    s.fund("alice", 5)
    assert s.weth.balance_of("alice") == 5 and s.weth.total_supply == 5
    assert s.log.entries[-1] == ("weth", ("Transfer", ZERO, "alice", 5))


def test_open_emits_in_contract_order_and_returns_its_events() -> None:
    s = _sys()
    r = s.open_position("alice", 3 * E18, 3_333 * E18, now=s.now)
    assert r.value == 1
    assert [(src, e[0]) for src, e in r.events] == [
        ("oracle", "LastGoodPriceUpdated"),
        ("sorted", "NodeInserted"),
        ("weth", "Transfer"),
        ("token", "Transfer"),
        ("vault", "PositionOpened"),
        ("vault", "PositionUpdated"),
    ]
    assert r.events[2][1] == ("Transfer", "alice", "vault", 3 * E18 + s.params.gas_reserve)
    assert r.events[3][1] == ("Transfer", ZERO, "alice", 3_333 * E18)
    assert r.events == s.log.entries[-6:]


def test_every_emitted_event_is_in_the_spec_table_with_its_arity() -> None:
    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    s.open_position("bob", 10 * E18, 5_000 * E18, now=t + 60)
    s.deposit("bob", 3_000 * E18, now=t + 60)
    s.set_price(1_200 * E18, t + 120)
    s.liquidate("liq", 1, now=t + 120)
    s.claim_gains("bob", now=t + 180)
    s.cover("carol", now=t + 180)
    s.trigger_shutdown(now=t + 240)
    s.settle(now=t + 240)
    names = {e[0] for _, e in s.log.entries}
    assert {"Liquidated", "PoolOffset", "Redistributed", "LedgerSettled", "Transfer"} <= names
    bad = [e for _, e in s.log.entries if not well_formed(e)]
    assert bad == []
    assert all(e[0] in EVENTS for _, e in s.log.entries)


def test_a_failed_operation_leaves_every_contract_token_and_event_as_before() -> None:
    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    before, n = s.snapshot(), len(s.log.entries)
    with pytest.raises(er.IcrBelowMcr):
        s.borrow("alice", 1, 10**24, now=t + 3_600)  # accrues, mints interest, then reverts
    with pytest.raises(er.NotOwner):
        s.withdraw_collateral("bob", 1, 1, now=t + 3_600)
    with pytest.raises(er.InsufficientBalance):
        s.redeem("carol", E18, 5, WAD, now=t + 3_600)  # fetches a price and accrues first
    after = s.snapshot()
    assert {k: v for k, v in after.items() if k != "now"} == {
        k: v for k, v in before.items() if k != "now"
    }
    assert len(s.log.entries) == n


def test_a_reverted_unusable_read_does_not_start_the_failure_clock() -> None:
    """fetchPrice writes failureStart, then the caller reverts PriceUnusable: the write is undone
    with the transaction, as on chain."""
    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    with pytest.raises(er.PriceUnusable):
        s.borrow("alice", 1, E18, now=t + 3_601)  # the round is now stale
    assert s.oracle.failure_start == 0
    s.set_sequencer(FeedRound(1, 1, 1))  # sequencer down
    with pytest.raises(er.PriceUnusable):
        s.open_position("bob", 3 * E18, 3_333 * E18, now=t + 3_601)
    assert s.oracle.failure_start == 0


def test_time_never_goes_back() -> None:
    s = _sys()
    s.accrue("carol", now=s.now + 10)
    with pytest.raises(ValueError, match="time goes back"):
        s.accrue("carol", now=s.now - 1)


def test_snapshot_is_canonical_integer_and_drops_zero_balances() -> None:
    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    s.transfer("alice", "bob", 3_333 * E18, now=t)
    snap = s.snapshot()
    assert "alice" not in snap["token"]["balances"]
    assert snap["token"]["balances"]["bob"] == 3_333 * E18
    assert snap["vault"]["shutdown"] == 0

    def keys_sorted(x: object) -> bool:
        if isinstance(x, dict):
            return list(x) == sorted(x) and all(keys_sorted(v) for v in x.values())
        return not isinstance(x, bool | float)

    assert keys_sorted(snap)
    assert json.dumps(snap) == json.dumps(_replay_same().snapshot())


def _replay_same() -> System:
    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    s.transfer("alice", "bob", 3_333 * E18, now=t)
    return s


def test_erc20_transfers_fail_with_the_token_errors() -> None:
    s = _sys()
    with pytest.raises(er.ERC20InsufficientBalance):
        s.transfer("alice", "bob", 1, now=s.now)
    with pytest.raises(er.WethTransferFailed):
        s.transfer_weth("nobody", "bob", 1, now=s.now)
    s.transfer_weth("alice", "bob", 7, now=s.now)
    assert s.weth.balance_of("bob") == 10**24 + 7


def test_record_keeps_the_last_step_with_pre_and_post_state() -> None:
    s = _sys(record=True)
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    step = s.last
    assert step is not None and step.op == "open" and step.error is None
    assert step.pre["vault"]["activeCount"] == 0 and step.post["vault"]["activeCount"] == 1
    assert (step.price, step.usable) == (2_000 * E18, True)
    with pytest.raises(er.ZeroAmount):
        s.repay("alice", 1, 0, now=t)
    assert isinstance(s.last.error, er.ZeroAmount) and s.last.post == s.last.pre


def test_stand_in_shutdown_then_settlement_moves_collateral_and_burns_the_reserve() -> None:
    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    s.trigger_shutdown(now=t + 3_600)
    assert s.vault.shutdown and s.ledger.reserve > 0
    with pytest.raises(er.SystemShutdown):
        s.trigger_shutdown(now=t + 3_600)
    supply = s.token.total_supply
    reserve = s.ledger.reserve
    r = s.settle(now=t + 7_200)
    assert r.value == 3 * E18
    assert s.weth.balance_of(SHUTDOWN) == 3 * E18
    assert s.token.total_supply == supply - reserve
    assert [e[0] for src, e in r.events if src in ("vault", "ledger")] == [
        "VaultSettled",
        "LedgerSettled",
    ]
    with pytest.raises(er.AlreadySettled):
        s.settle(now=t + 7_200)
    with pytest.raises(er.SystemSettled):
        s.cover("bob", now=t + 7_200)
    s.reclaim_gas_reserve("alice", 1, now=t + 7_200)


def test_settlement_failure_rolls_the_vault_hook_back() -> None:
    s = _sys()
    with pytest.raises(er.NotTriggered):
        s.settle(now=s.now)
    assert not s.vault.settled and not s.ledger.settled


def test_a_revert_after_a_position_changed_restores_it_from_the_journal() -> None:
    """`borrow` applies pending rewards (writing the stored position) and only then fails its MCR
    check: the journal must put every field back, and be empty once the transaction is over."""
    from model.protocol.vault import _Journal

    s = _sys()
    t = s.now
    s.open_position("alice", 3 * E18, 3_333 * E18, now=t)
    s.open_position("bob", 10 * E18, 5_000 * E18, now=t)
    s.set_price(1_200 * E18, t + 1)
    s.liquidate("liq", 1, now=t + 1)  # empty pool: redistributed, bob has pending rewards
    q = s.vault.positions[2]
    stored = (q.coll, q.norm_debt, q.stake, q.snap_l_coll, q.snap_l_debt, q.status)
    assert s.vault.effective(2) != (q.coll, q.norm_debt)
    with pytest.raises(er.IcrBelowMcr):
        s.borrow("bob", 2, 10**24, now=t + 2)
    assert (q.coll, q.norm_debt, q.stake, q.snap_l_coll, q.snap_l_debt, q.status) == stored
    assert _Journal.entries == [] and _Journal.depth == 0
    s.borrow("bob", 2, E18, now=t + 2)  # the same path, succeeding, writes for good
    assert q.snap_l_coll == s.vault.l_coll and _Journal.entries == []
