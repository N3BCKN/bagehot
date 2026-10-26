"""The P19 precision study (`model/tools/sp_precision.py`) as tests: on fresh seeds, I3's integer
inequalities, U4, and the compounded and collateral attribution bounds hold with no violation; and
the counterexample behind CHG-010 — a correct pool breaks I3's interest bound as currently written,
while the bound CHG-010 proposes holds."""

from __future__ import annotations

from model.tools import sp_precision as sp


def _split(violations: list[str]) -> tuple[list[str], list[str], list[str]]:
    proposed = [v for v in violations if v.startswith("CHG-010")]
    interest = [v for v in violations if not v.startswith("CHG-010") and "interest gain" in v]
    other = [v for v in violations if not v.startswith("CHG-010") and "interest gain" not in v]
    return proposed, interest, other


def test_integer_invariants_and_compounded_collateral_bounds_hold() -> None:
    for seed in range(7_000, 7_012):  # all four regimes, three times each
        _, violations, _ = sp.run_case(seed, 150, False)
        proposed, _, other = _split(violations)
        assert other == [], other[:3]
        assert proposed == [], proposed[:3]


def test_chg010_counterexample_current_interest_bound_fails_proposed_holds() -> None:
    """Seed 190022: a depositor's deposit is taken through three scale changes by one offset that
    leaves T = 1 wei; interest booked afterwards falls in a scale §6.6.7 ignores for them. The
    contract (bit-for-bit with this model) pays 0; the exact pro-rata share is ~1,369 wei."""
    _, violations, _ = sp.run_case(190_022, 300, False)
    proposed, interest, other = _split(violations)
    assert other == []
    assert any("a1: interest gain 0" in v for v in interest), interest[:3]
    assert proposed == []
