"""The harness itself (P23): the two sides start equal, and every comparison can fail — a harness
that cannot report a difference proves nothing."""

from __future__ import annotations

import pytest

from differential.allowed import EXCLUDED_EVENTS, NOT_GENERATED, REVERT_NAMES, model_revert_name
from differential.pair import Mismatch
from model.protocol import errors as er

WAD = 10**18


def test_base_states_are_equal(pair) -> None:  # noqa: ANN001
    pair.reset()
    m = pair.model
    holders = set(m.weth.balances) | set(m.token.balances)
    assert m.snapshot() == pair.chain.snapshot(holders, set())


def test_a_state_difference_is_reported(pair) -> None:  # noqa: ANN001
    pair.reset()
    pair.model.redemption.base_rate = 1  # a change the chain did not make
    with pytest.raises(Mismatch, match="state differs"):
        pair.step("accrue", "alice")


def test_an_event_difference_is_reported(pair, monkeypatch) -> None:  # noqa: ANN001
    pair.reset()
    real = pair.model.accrue

    def accrue_with_a_stray_event(caller: str, *, now: int):  # noqa: ANN202
        r = real(caller, now=now)
        r.events.append(("vault", ("PoolInterestRedirected", 1)))
        return r

    monkeypatch.setattr(pair.model, "accrue", accrue_with_a_stray_event)
    pair.now += 60
    with pytest.raises(Mismatch, match="events differ"):
        pair.step("accrue", "alice")


def test_a_revert_name_difference_is_reported(pair, monkeypatch) -> None:  # noqa: ANN001
    pair.reset()

    def wrong(*_a, **_k):  # noqa: ANN002, ANN003, ANN202
        raise er.NotOwner()

    monkeypatch.setattr(pair.model, "close", wrong)
    with pytest.raises(
        Mismatch,
        match="model \\('revert', 'NotOwner'\\), chain \\('revert', 'PositionNotActive'\\)",
    ):
        pair.step("close", "alice", 7)


def test_reverts_compare_by_name_including_weth_and_panics(pair) -> None:  # noqa: ANN001
    pair.reset()
    pair.step("close", "alice", 1)  # PositionNotActive on both sides
    # a WETH pull the caller cannot pay: OZ's ERC20InsufficientBalance inside WETH, §2.5's name
    pair.step("open_position", "alice", 10**25, 3_333 * WAD, 0, 0)
    assert model_revert_name(er.Overflow()) == model_revert_name(er.Underflow()) == "Panic(0x11)"


def test_a_model_panic_is_compared_as_a_revert(pair, monkeypatch) -> None:  # noqa: ANN001
    """Checked arithmetic in the model raises Overflow (an ArithmeticError, not a ProtocolError):
    it must be compared as Panic(0x11), not escape the step."""
    pair.reset()

    def panics(*_a, **_k):  # noqa: ANN002, ANN003, ANN202
        raise er.Overflow()

    monkeypatch.setattr(pair.model, "close", panics)
    with pytest.raises(
        Mismatch,
        match="model \\('revert', 'Panic\\(0x11\\)'\\), chain \\('revert', 'PositionNotActive'\\)",
    ):
        pair.step("close", "alice", 1)


def test_an_aborted_step_leaves_nothing_for_the_next_example(pair, monkeypatch) -> None:  # noqa: ANN001
    """A step that dies after sending its feed update must not leak it into the next block."""
    pair.reset()
    env = pair.feed_change("price", 1_000 * WAD)

    def dies(*_a, **_k):  # noqa: ANN002, ANN003, ANN202
        raise RuntimeError("harness crash")

    monkeypatch.setattr(pair.model, "accrue", dies)
    with pytest.raises(RuntimeError, match="harness crash"):
        pair.step("accrue", "alice", env=tuple(env))
    monkeypatch.undo()
    pair.reset()
    pair.now += 1
    pair.step("fetch_price", "alice")  # the base price on both sides, not the leaked 1,000


def test_a_return_value_difference_is_reported(pair, monkeypatch) -> None:  # noqa: ANN001
    pair.reset()
    real = pair.model.fetch_price

    def off_by_one(caller: str, *, now: int):  # noqa: ANN202
        r = real(caller, now=now)
        r.value = (r.value[0] + 1, r.value[1])
        return r

    monkeypatch.setattr(pair.model, "fetch_price", off_by_one)
    with pytest.raises(Mismatch, match="returned model"):
        pair.step("fetch_price", "alice")


def test_hooks_compare_from_actors_and_from_the_stand_in_out_of_phase(pair) -> None:  # noqa: ANN001
    pair.reset()
    pair.step("hook", "alice", "onShutdown")  # Unauthorized on both sides
    pair.step(
        "hook", "bob", "redeemCollateral", "bob", 1_000 * WAD, WAD // 200, 2_000 * WAD, 3, 0, 0
    )
    pair.step("hook", "shutdown", "onSettlement")  # NotTriggered on both sides
    pair.step("trigger_shutdown", "shutdown")
    pair.step("hook", "shutdown", "onShutdown")  # SystemShutdown on both sides


def test_the_allowed_differences_are_listed_with_reasons() -> None:
    for table in (EXCLUDED_EVENTS, NOT_GENERATED):
        assert all(len(reason) > 40 for reason in table.values())
    assert set(EXCLUDED_EVENTS) == {"Approval", "Wired"}
    assert REVERT_NAMES["Overflow"] == "Panic(0x11)"
