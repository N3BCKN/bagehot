"""The P19 precision study (`model/tools/sp_precision.py`) as tests: on fresh seeds, I3's integer
inequalities, U4 and all three attribution bounds (with CHG-010's ignored-scales term) hold with no
violation; and the counterexample behind CHG-010 — a correct pool breaks I3's interest bound as it
was written before CHG-010, and satisfies the bound since."""

from __future__ import annotations

from model.tools import sp_precision as sp


def _split(violations: list[str]) -> tuple[list[str], list[str]]:
    pre = [v for v in violations if v.startswith("pre-CHG-010")]
    current = [v for v in violations if not v.startswith("pre-CHG-010")]
    return pre, current


def test_integer_invariants_and_compounded_collateral_bounds_hold() -> None:
    for seed in range(7_000, 7_012):  # all four regimes, three times each
        _, violations, _ = sp.run_case(seed, 150, False)
        _, current = _split(violations)
        assert current == [], current[:3]


def test_chg010_counterexample_pre_chg010_bound_fails_current_holds() -> None:
    """Seed 190022: a depositor's deposit is taken through three scale changes by one offset that
    leaves T = 1 wei; interest booked afterwards falls in a scale §6.6.7 ignores for them. The
    contract (bit-for-bit with this model) pays 0; the exact pro-rata share is ~1,369 wei."""
    _, violations, _ = sp.run_case(190_022, 300, False)
    pre, current = _split(violations)
    assert any("a1: interest gain 0" in v for v in pre), pre[:3]
    assert current == []
