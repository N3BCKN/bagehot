"""DeficitLedger in model/protocol/deficit_ledger.py (P21): the same cases as
contracts/test/unit/DeficitLedger.t.sol — hooks, caller and settled checks, cover, settlement."""

from __future__ import annotations

import pytest

from model.protocol import deficit_ledger as dl
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
