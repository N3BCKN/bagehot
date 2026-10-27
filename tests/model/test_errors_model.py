"""The model's errors against the Solidity custom errors, and the §3.4 constructor checks (P22)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from model.protocol import errors as er
from model.protocol import redemption as rdm
from model.protocol import sorted_list as sl
from model.protocol import stability_pool as sp
from model.protocol import vault as vm
from model.protocol.math import RAY, WAD

SRC = Path(__file__).resolve().parents[2] / "contracts" / "src"
PROTOCOL_DIRS = ("core", "liquidation", "redemption", "safety", "lib")


def _solidity_errors() -> set[str]:
    names: set[str] = set()
    for d in PROTOCOL_DIRS:
        for f in (SRC / d).glob("*.sol"):
            names |= set(re.findall(r"^\s*error (\w+)\(", f.read_text(), re.M))
    return names


def test_every_solidity_error_has_a_model_class_of_the_same_name() -> None:
    solidity = _solidity_errors()
    assert len(solidity) >= 35  # the parse found the error declarations
    missing = sorted(n for n in solidity if not hasattr(er, n))
    assert missing == []
    for n in solidity:
        assert issubclass(getattr(er, n), er.ProtocolError), n


def test_model_errors_are_solidity_errors_or_documented_extras() -> None:
    """Nothing invented: every class is a Solidity error, a §2.5 token failure, or a panic."""
    extras = {"ProtocolError", "WethTransferFailed", "ERC20InsufficientBalance"}
    panics = {"Overflow", "Underflow", "DivisionByZero"}
    assert set(er.__all__) - _solidity_errors() == extras | panics


def test_invalid_parameter_carries_its_index() -> None:
    e = er.InvalidParameter(7)
    assert e.index == 7 and type(e).__name__ == "InvalidParameter"


def _vault(**kw: object) -> vm.Vault:
    args = {
        "mcr": 11 * 10**17,
        "min_debt": 2_000 * WAD,
        "gas_reserve": 1,
        "max_hint_steps": 30,
        "price_source": lambda: (2_000 * WAD, True),
    }
    args.update(kw)
    return vm.Vault(**args)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("kw", "index"),
    [
        ({"mcr": WAD}, 3),
        ({"mcr": 2 * WAD + 1}, 3),
        ({"min_debt": WAD - 1}, 4),
        ({"gas_reserve": 0}, 5),
        ({"rate_per_second": vm.MAX_RATE_PER_SECOND + 1}, 6),
        ({"pool_share_bps": 10_001}, 7),
        ({"pool_hook_gas": 174_999}, 8),  # CHG-013
        ({"pool_hook_gas": 1_000_001}, 8),
        ({"mcr": WAD, "pool_hook_gas": 0}, 3),  # argument order: the first failure wins
        ({"has_pool": False, "pool_share_bps": 1}, 2),  # wire argument 2
    ],
)
def test_vault_constructor_rejects_out_of_range(kw: dict, index: int) -> None:
    with pytest.raises(er.InvalidParameter) as e:
        _vault(**kw)
    assert e.value.index == index


def test_vault_constructor_accepts_the_bounds() -> None:
    for kw in (
        {"mcr": WAD + 1},
        {"mcr": 2 * WAD},
        {"min_debt": WAD},
        {"rate_per_second": vm.MAX_RATE_PER_SECOND},
        {"pool_share_bps": 10_000},
        {"pool_hook_gas": 175_000},
        {"pool_hook_gas": 1_000_000},
        {"has_pool": False, "pool_share_bps": 0},
    ):
        _vault(**kw)


@pytest.mark.parametrize(
    ("penalty", "min_deposit", "index"),
    [(WAD // 2 + 1, WAD, 2), (WAD // 2, WAD - 1, 3), (WAD, 0, 2)],
)
def test_pool_constructor_rejects_out_of_range(penalty: int, min_deposit: int, index: int) -> None:
    with pytest.raises(er.InvalidParameter) as e:
        sp.StabilityPool(sp.Tokens(), penalty, min_deposit)
    assert e.value.index == index
    sp.StabilityPool(sp.Tokens(), WAD // 2, WAD)  # both bounds accepted


@pytest.mark.parametrize(
    ("floor", "beta", "decay", "index"),
    [
        (WAD + 1, 2, RAY - 1, 2),
        (WAD, 0, RAY - 1, 3),
        (WAD, 101, RAY - 1, 3),
        (WAD, 100, 0, 4),
        (WAD, 100, RAY, 4),
    ],
)
def test_redemption_constructor_rejects_out_of_range(
    floor: int, beta: int, decay: int, index: int
) -> None:
    v = _vault()
    with pytest.raises(er.InvalidParameter) as e:
        rdm.RedemptionModule(v, floor, beta, decay, lambda _p: False)
    assert e.value.index == index
    rdm.RedemptionModule(v, WAD, 1, 1, lambda _p: False)
    rdm.RedemptionModule(v, 0, 100, RAY - 1, lambda _p: False)


@pytest.mark.parametrize("steps", [0, 1_001])
def test_sorted_list_constructor_rejects_out_of_range(steps: int) -> None:
    with pytest.raises(er.InvalidParameter) as e:
        sl.SortedList(steps, lambda _i: (0, 0))
    assert e.value.index == 0


def test_sorted_list_constructor_accepts_the_bounds() -> None:
    sl.SortedList(1, lambda _i: (0, 0))
    sl.SortedList(1_000, lambda _i: (0, 0))
