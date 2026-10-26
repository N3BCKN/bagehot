"""Exact-integer arithmetic of the protocol, bit-for-bit identical to the Solidity libraries.

Mirrors `contracts/src/lib/Rounding.sol` and `contracts/src/lib/WadRayMath.sol` (spec §2.2,
§2.3). Python `int` only — no float, Decimal or numpy (python-model skill).

Errors carry the names the differential test compares (spec §2.2): a result that does not fit in
uint256 raises `Overflow` (Solidity: `Panic(0x11)` from OZ `Math.mulDiv`), a zero divisor raises
`DivisionByZero` (Solidity: `Panic(0x12)`). An argument outside uint256 is not representable in
Solidity at all, so it is a programming error here (`ValueError`), not a protocol revert.
"""

from __future__ import annotations

from enum import Enum

WAD = 10**18
RAY = 10**27
UINT256_MAX = 2**256 - 1


class Overflow(ArithmeticError):
    """uint256 overflow — Solidity `Panic(0x11)`."""


class Underflow(ArithmeticError):
    """A checked subtraction below zero (Solidity `Panic(0x11)`, spec §2.2)."""


class DivisionByZero(ArithmeticError):
    """Division by zero — Solidity `Panic(0x12)`."""


class Rounding(Enum):
    """The two directions the spec uses. Names follow OZ `Math.Rounding`."""

    FLOOR = "floor"
    CEIL = "ceil"


def _uint(*values: int) -> None:
    for v in values:
        if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= UINT256_MAX:
            raise ValueError(f"not a uint256: {v!r}")


def mul_div(x: int, y: int, d: int, rounding: Rounding) -> int:
    """floor or ceil of x*y/d with an unbounded intermediate (OZ `Math.mulDiv` with 512 bits).

    Solidity checks the divisor first, then whether the result fits; so does this.
    """
    _uint(x, y, d)
    if d == 0:
        raise DivisionByZero("mulDiv by zero")
    q, r = divmod(x * y, d)
    if rounding is Rounding.CEIL and r:
        q += 1
    if q > UINT256_MAX:
        raise Overflow("mulDiv result does not fit in uint256")
    return q


def mul_div_down(x: int, y: int, d: int) -> int:
    return mul_div(x, y, d, Rounding.FLOOR)


def mul_div_up(x: int, y: int, d: int) -> int:
    return mul_div(x, y, d, Rounding.CEIL)


def div_up(x: int, y: int) -> int:
    """ceil(x / y), as OZ `Math.ceilDiv`."""
    _uint(x, y)
    if y == 0:
        raise DivisionByZero("ceilDiv by zero")
    return -(-x // y)


# WAD (1e18) and RAY (1e27) fixed point. Multiply: x*y/UNIT; divide: x*UNIT/y.
def wmul_down(x: int, y: int) -> int:
    return mul_div(x, y, WAD, Rounding.FLOOR)


def wmul_up(x: int, y: int) -> int:
    return mul_div(x, y, WAD, Rounding.CEIL)


def wdiv_down(x: int, y: int) -> int:
    return mul_div(x, WAD, y, Rounding.FLOOR)


def wdiv_up(x: int, y: int) -> int:
    return mul_div(x, WAD, y, Rounding.CEIL)


def rmul_down(x: int, y: int) -> int:
    return mul_div(x, y, RAY, Rounding.FLOOR)


def rmul_up(x: int, y: int) -> int:
    return mul_div(x, y, RAY, Rounding.CEIL)


def rdiv_down(x: int, y: int) -> int:
    return mul_div(x, RAY, y, Rounding.FLOOR)


def rdiv_up(x: int, y: int) -> int:
    return mul_div(x, RAY, y, Rounding.CEIL)


def rpow(x: int, n: int, rounding: Rounding = Rounding.CEIL) -> int:
    """x^n in RAY by square-and-multiply, least-significant bit first (spec §2.3).

    Every product is rounded in `rounding`'s direction; the protocol only ever uses CEIL (the
    spec's rpow). FLOOR exists so tests can bracket the exact value. The last squaring is skipped
    (`if e > 0`), which is part of the order the vectors pin — and why `rpow(2·RAY, 166)` fits
    while an implementation that squares once more would overflow first.
    """
    _uint(x, n)
    z, b, e = RAY, x, n
    while e > 0:
        if e & 1:
            z = mul_div(z, b, RAY, rounding)
        e >>= 1
        if e > 0:
            b = mul_div(b, b, RAY, rounding)
    return z


def rpow_trace(x: int, n: int, rounding: Rounding = Rounding.CEIL) -> list[dict[str, int]]:
    """The (e, z, b) states of `rpow`, in the shape of `spec/vectors/math.json#rpow.trace`."""
    _uint(x, n)
    z, b, e, out = RAY, x, n, []
    while e > 0:
        if e & 1:
            z = mul_div(z, b, RAY, rounding)
        step = {"e": e, "z": z}
        e >>= 1
        if e > 0:
            b = mul_div(b, b, RAY, rounding)
            step["b"] = b
        out.append(step)
    return out


def multiplications(n: int) -> int:
    """Rounded products `rpow` performs: popcount(n) multiplications into z plus
    bit_length(n) - 1 squarings. The first z product (RAY · b / RAY) is always exact."""
    return 0 if n == 0 else bin(n).count("1") + n.bit_length() - 1
