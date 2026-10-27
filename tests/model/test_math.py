"""model/protocol/math.py against spec vectors, the generated cases, Fraction and Hypothesis.

The Solidity libraries are checked against the same two vector files in
contracts/test/vectors/MathVectors.t.sol, so passing both suites means the two sides agree.
"""

from __future__ import annotations

import json
import math
from fractions import Fraction
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from model.protocol import math as m

SPEC = json.loads(Path("spec/vectors/math.json").read_text())["vectors"]
GEN = json.loads(Path("spec/generated/math_random.json").read_text())
U256 = st.integers(min_value=0, max_value=m.UINT256_MAX)
MAX_RATE = 21_979_553_151_239_153_028


def vector(name: str) -> dict:
    return next(v for v in SPEC if v["name"] == name)


def expect(value: str, fn, *args) -> None:
    """A generated expectation is either an integer or the name of the error."""
    if value == "Overflow":
        with pytest.raises(m.Overflow):
            fn(*args)
    elif value == "DivisionByZero":
        with pytest.raises(m.DivisionByZero):
            fn(*args)
    else:
        assert fn(*args) == int(value)


# --------------------------------------------------------------------------- spec vectors
def test_spec_mul_div_vectors():
    steps = vector("mulDiv")["steps"]
    assert len(steps) == 6
    for s in steps:
        x, y, d = int(s["x"]), int(s["y"]), int(s["d"])
        assert m.mul_div_down(x, y, d) == int(s["result"]["down"])
        assert m.mul_div_up(x, y, d) == int(s["result"]["up"])


def test_spec_rpow_vectors_and_trace():
    steps = vector("rpow")["steps"]
    plain = [s for s in steps if s["op"] == "rpow"]
    assert len(plain) == 8
    for s in plain:
        assert m.rpow(int(s["x"]), int(s["n"])) == int(s["result"])
    trace = next(s for s in steps if s["op"] == "rpow.trace")
    want = [{k: int(v) for k, v in st_.items()} for st_ in trace["result"]]
    assert m.rpow_trace(int(trace["x"]), int(trace["n"])) == want  # pins the product order


def test_spec_derived_constants():
    e = vector("derived_constants")["expected"]
    assert m.rpow(m.RAY + int(e["RATE_PER_SECOND"]), 31_536_000) == int(
        e["rpow(RAY+RATE_PER_SECOND,31536000)"]
    )
    assert m.rpow(int(e["BASE_RATE_DECAY"]), 43_200) == int(e["rpow(BASE_RATE_DECAY,43200)"])
    assert m.rpow(int(e["CUT"]), 600) == int(e["rpow(CUT,600)"])


# --------------------------------------------------------------------------- generated vectors
def test_generated_mul_div():
    g = GEN["mulDiv"]
    for x, y, d, down, up in zip(g["x"], g["y"], g["d"], g["down"], g["up"], strict=True):
        expect(down, m.mul_div_down, int(x), int(y), int(d))
        expect(up, m.mul_div_up, int(x), int(y), int(d))


def test_generated_wad_ray():
    g = GEN["wadRay"]
    fns = {
        "wmulDown": m.wmul_down,
        "wmulUp": m.wmul_up,
        "wdivDown": m.wdiv_down,
        "wdivUp": m.wdiv_up,
        "rmulDown": m.rmul_down,
        "rmulUp": m.rmul_up,
        "rdivDown": m.rdiv_down,
        "rdivUp": m.rdiv_up,
        "divUp": m.div_up,
    }
    for i, (x, y) in enumerate(zip(g["x"], g["y"], strict=True)):
        for name, fn in fns.items():
            expect(g[name][i], fn, int(x), int(y))


def test_generated_rpow():
    g = GEN["rpow"]
    for x, n, up, down in zip(g["x"], g["n"], g["up"], g["down"], strict=True):
        expect(up, m.rpow, int(x), int(n), m.Rounding.CEIL)
        expect(down, m.rpow, int(x), int(n), m.Rounding.FLOOR)


# --------------------------------------------------------------------------- Fraction cross-check
@settings(max_examples=2000)
@given(U256, U256, st.integers(min_value=1, max_value=m.UINT256_MAX))
def test_mul_div_is_floor_and_ceil_of_the_exact_quotient(x, y, d):
    exact = Fraction(x * y, d)
    down, up = math.floor(exact), math.ceil(exact)
    if down > m.UINT256_MAX:
        with pytest.raises(m.Overflow):
            m.mul_div_down(x, y, d)
        return
    assert m.mul_div_down(x, y, d) == down
    if up > m.UINT256_MAX:
        with pytest.raises(m.Overflow):  # the ceil's +1 at the very top
            m.mul_div_up(x, y, d)
        return
    assert m.mul_div_up(x, y, d) == up
    assert up - down == (0 if (x * y) % d == 0 else 1)


def test_ceil_overflow_at_the_top_matches_solidity():
    x = 96493407697763496186309154173906589877724987221367136699547986673260941366613
    assert m.mul_div_down(x, 6, 5) == m.UINT256_MAX
    with pytest.raises(m.Overflow):
        m.mul_div_up(x, 6, 5)


def test_zero_divisor_raises_division_by_zero_even_for_zero_numerator():
    with pytest.raises(m.DivisionByZero):
        m.mul_div_down(0, 0, 0)
    with pytest.raises(m.DivisionByZero):
        m.div_up(0, 0)


def test_non_uint256_arguments_are_programming_errors():
    for bad in (-1, 2**256, 1.0, True):
        with pytest.raises(ValueError):
            m.mul_div_down(bad, 1, 1)


@settings(max_examples=1000)
@given(st.integers(min_value=0, max_value=2 * m.RAY), st.integers(min_value=0, max_value=48))
def test_rpow_brackets_the_exact_power(x, n):
    exact = Fraction(x**n, m.RAY ** (n - 1)) if n else Fraction(m.RAY)
    assert m.rpow(x, n, m.Rounding.FLOOR) <= exact <= m.rpow(x, n, m.Rounding.CEIL)


@settings(max_examples=1000)
@given(st.integers(min_value=0, max_value=2 * m.RAY), st.integers(min_value=0, max_value=3))
def test_rpow_equals_repeated_rmul_up_to_three(x, n):
    z = m.RAY
    for _ in range(n):
        z = m.rmul_up(z, x)
    assert m.rpow(x, n) == z


# --------------------------------------------------------------------------- rpow properties
@settings(max_examples=500)
@given(
    st.integers(min_value=m.RAY, max_value=m.RAY + MAX_RATE),
    st.integers(min_value=0, max_value=2**26),
)
def test_rpow_growth_is_nondecreasing_in_n(x, n):
    assert m.rpow(x, n + 1) >= m.rpow(x, n)


@settings(max_examples=500)
@given(
    st.integers(min_value=m.RAY // 2, max_value=m.RAY), st.integers(min_value=0, max_value=2**20)
)
def test_rpow_decay_is_nonincreasing_in_n(x, n):
    assert m.rpow(x, n + 1) <= m.rpow(x, n)


@settings(max_examples=500)
@given(
    st.integers(min_value=0, max_value=2 * m.RAY),
    st.integers(min_value=0, max_value=2 * m.RAY),
    st.integers(min_value=0, max_value=160),
)
def test_rpow_is_nondecreasing_in_x(a, b, n):
    lo, hi = sorted((a, b))
    assert m.rpow(lo, n) <= m.rpow(hi, n)


def test_rpow_overflow_boundary_matches_solidity():
    assert m.rpow(2 * m.RAY, 166) == 2**166 * m.RAY
    with pytest.raises(m.Overflow):
        m.rpow(2 * m.RAY, 167)


@settings(max_examples=300)
@given(st.integers(min_value=0, max_value=m.RAY), st.integers(min_value=0, max_value=2**255))
def test_rpow_never_overflows_at_or_below_ray(x, n):
    assert m.rpow(x, n) <= m.RAY


def test_multiplications_counts_rounded_products():
    assert [m.multiplications(n) for n in (0, 1, 2, 3, 7, 8)] == [0, 1, 2, 3, 5, 4]


def test_error_bound_holds_on_a_fresh_sample():
    """The P10 bound |rpow - exact| <= n * max(1, exact/RAY), via spec/tools/rpow_error.py."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("rpow_error", "spec/tools/rpow_error.py")
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    import random

    rng = random.Random(4242)
    for _ in range(400):
        x = m.RAY + rng.randrange(0, MAX_RATE + 1)
        n = rng.randrange(1, 2**26)
        lo, hi = tool.bracket(x, n)
        up, down = m.rpow(x, n, m.Rounding.CEIL), m.rpow(x, n, m.Rounding.FLOOR)
        bound = n * max(Fraction(1), hi / m.RAY)
        assert down <= lo and hi <= up
        assert up - lo <= bound and hi - down <= bound
