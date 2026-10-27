"""DeficitLedger in model/protocol/deficit.py (P21): the same cases as
contracts/test/unit/DeficitLedger.t.sol — hooks, caller and settled checks, cover, settlement."""

from __future__ import annotations

import pytest

from model.protocol import deficit as dl
from model.protocol.stability_pool import Tokens

E18 = 10**18


def _ledger(variant_b: bool = False) -> dl.DeficitLedger:
    return dl.DeficitLedger(Tokens(), variant_b=variant_b)


def test_hooks_callers_and_effects() -> None:
    led = _ledger()
    led.bank._mint("ledger", 7 * E18)
    led.on_interest("vault", 5 * E18)
    led.on_pool_dust("pool", 2 * E18)
    assert led.reserve == 7 * E18 == led.bank.stable["ledger"]
    led.bank.weth["ledger"] = 3 * E18
    led.record_deficit("vault", 1000 * E18, 3 * E18)
    assert (led.deficit, led.recovered_coll) == (1000 * E18, 3 * E18)
    for call in (
        lambda: led.on_interest("alice", 1),
        lambda: led.on_pool_dust("vault", 1),
        lambda: led.add_auction_debt("house", 1),  # no house in A
        lambda: led.on_settlement("alice"),
    ):
        with pytest.raises(dl.Unauthorized):
            call()


def test_auction_hooks_b() -> None:
    led = _ledger(variant_b=True)
    led.add_auction_debt("house", 500 * E18)
    led.bank._mint("ledger", 25 * E18)
    led.on_auction_payment("house", 300 * E18, 25 * E18)
    led.on_auction_shortfall("house", 200 * E18)
    led.pay_tip("house", "alice", 5 * E18)
    assert (led.auction_debt, led.deficit, led.reserve) == (0, 200 * E18, 20 * E18)
    assert led.bank.stable["alice"] == 5 * E18
    with pytest.raises(dl.Unauthorized):
        led.record_deficit("house", 1, 0)


def test_auction_hooks_b_beyond_balances_raise() -> None:
    led = _ledger(variant_b=True)
    led.add_auction_debt("house", 100 * E18)
    led.bank._mint("ledger", 10 * E18)
    led.on_auction_payment("house", 0, 10 * E18)
    for call in (
        lambda: led.on_auction_payment("house", 100 * E18 + 1, 0),
        lambda: led.on_auction_shortfall("house", 100 * E18 + 1),
        lambda: led.pay_tip("house", "alice", 10 * E18 + 1),
    ):
        with pytest.raises(ArithmeticError):
            call()
    assert (led.auction_debt, led.reserve) == (
        100 * E18,
        10 * E18,
    )  # each failed call left no trace
    led.pay_tip("house", "alice", 10 * E18)
    led.on_auction_shortfall("house", 100 * E18)
    assert (led.auction_debt, led.deficit, led.reserve) == (0, 100 * E18, 0)


def test_cover() -> None:
    led = _ledger()
    led.bank._mint("ledger", 100 * E18)
    led.on_interest("vault", 100 * E18)
    led.record_deficit("vault", 30 * E18, 0)
    supply = led.bank.total_supply
    assert led.cover() == 30 * E18
    assert supply - led.bank.total_supply == 30 * E18
    led.record_deficit("vault", 200 * E18, 0)
    assert led.cover() == 70 * E18
    assert (led.deficit, led.reserve) == (130 * E18, 0)
    assert led.cover() == 0


def test_settlement() -> None:
    led = _ledger(variant_b=True)
    led.bank._mint("ledger", 40 * E18)
    led.on_interest("vault", 40 * E18)
    led.add_auction_debt("house", 500 * E18)
    led.record_deficit("vault", 10 * E18, 0)
    assert led.on_settlement("shutdown") == 0
    assert (led.reserve, led.auction_debt, led.deficit, led.settled) == (0, 0, 510 * E18, True)
    with pytest.raises(dl.AlreadySettled):
        led.on_settlement("shutdown")
    with pytest.raises(dl.SystemSettled):
        led.on_interest("vault", 1)
    with pytest.raises(dl.SystemSettled):
        led.cover()
    with pytest.raises(dl.Unauthorized):  # the caller check first
        led.on_interest("alice", 1)


def test_settlement_sends_recovered_collateral() -> None:
    led = _ledger()
    led.bank.weth["ledger"] = 4 * E18
    led.record_deficit("vault", 1000 * E18, 4 * E18)
    assert led.on_settlement("shutdown") == 4 * E18
    assert led.bank.weth["shutdown"] == 4 * E18 and led.recovered_coll == 0


def test_after_settlement_every_hook_raises_system_settled() -> None:
    for variant_b in (False, True):
        led = _ledger(variant_b=variant_b)
        led.on_settlement("shutdown")
        hooks = [
            (led.on_interest, ("vault", 1)),
            (led.record_deficit, ("vault", 1, 0)),
            (led.cover, ()),
        ]
        if variant_b:
            hooks += [
                (led.add_auction_debt, ("house", 1)),
                (led.on_auction_payment, ("house", 0, 0)),
                (led.on_auction_shortfall, ("house", 0)),
                (led.pay_tip, ("house", "alice", 0)),
            ]
        else:
            hooks.append((led.on_pool_dust, ("pool", 1)))
        for fn, args in hooks:
            with pytest.raises(dl.SystemSettled):
                fn(*args)
        with pytest.raises(dl.Unauthorized):  # the caller check comes first
            led.on_settlement("alice")
        with pytest.raises(dl.AlreadySettled):
            led.on_settlement("shutdown")


def test_auction_hooks_wrong_caller_raise_unauthorized() -> None:
    for variant_b in (False, True):
        led = _ledger(variant_b=variant_b)
        for caller in ("alice", "vault"):
            for fn, args in (
                (led.add_auction_debt, (caller, 1)),
                (led.on_auction_payment, (caller, 0, 0)),
                (led.on_auction_shortfall, (caller, 0)),
                (led.pay_tip, (caller, "alice", 0)),
            ):
                with pytest.raises(dl.Unauthorized):
                    fn(*args)


def test_events_match_the_contract() -> None:
    """Event tuples as §11.1 orders the fields (DeficitLedger.t.sol asserts the same values)."""
    led = _ledger(variant_b=True)
    led.add_auction_debt("house", 500 * E18)
    led.bank._mint("ledger", 25 * E18)
    led.on_auction_payment("house", 300 * E18, 25 * E18)
    led.on_auction_payment("house", 0, 0)  # nothing for the reserve: no ReserveIncreased
    led.on_auction_shortfall("house", 200 * E18)
    led.pay_tip("house", "alice", 5 * E18)
    led.cover()
    led.on_settlement("shutdown")
    assert led.events == [
        ("AuctionDebtChanged", 500 * E18, 500 * E18),
        ("AuctionDebtChanged", -300 * E18, 200 * E18),
        ("ReserveIncreased", 25 * E18, 2),
        ("AuctionDebtChanged", 0, 200 * E18),
        ("AuctionDebtChanged", -200 * E18, 0),
        ("DeficitRecorded", 200 * E18, 0, 1),
        ("ReserveDecreased", 5 * E18, 1),
        ("DeficitCovered", 20 * E18, 0, 180 * E18),
        ("LedgerSettled", 0, 180 * E18, 0),
    ]
