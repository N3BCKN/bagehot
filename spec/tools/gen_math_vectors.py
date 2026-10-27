"""Generate random math cases with exact expected values (P10). Not part of spec/vectors/.

    uv run python spec/tools/gen_math_vectors.py            # writes spec/generated/math_random.json

Expected values are computed here with `fractions.Fraction` and an independent transcription of
the spec's rpow (§2.3) — deliberately NOT by importing model/protocol/math.py — so the Solidity
library and the Python model are both checked against a third implementation. The output is used
by the Foundry and pytest suites. It is deliberately outside spec/vectors/ (protected,
human-approved): promoting it there would go through /spec-change.
"""

from __future__ import annotations

import json
import math
import random
from fractions import Fraction
from pathlib import Path

WAD, RAY = 10**18, 10**27
MAX = 2**256 - 1
OUT = Path(__file__).resolve().parents[1] / "generated" / "math_random.json"
SEED = 2026_10_22
N_MULDIV, N_RPOW, N_WR = 400, 200, 200


def floor_div(n: int, d: int) -> int:
    return math.floor(Fraction(n, d))


def ceil_div(n: int, d: int) -> int:
    return math.ceil(Fraction(n, d))


def muldiv(x: int, y: int, d: int, up: bool) -> int | str:
    if d == 0:
        return "DivisionByZero"
    q = ceil_div(x * y, d) if up else floor_div(x * y, d)
    return "Overflow" if q > MAX else q


def rpow_spec(x: int, n: int, up: bool) -> int | str:
    """docs/spec.md §2.3, transcribed independently."""
    z, b, e = RAY, x, n
    while e > 0:
        if e % 2 == 1:
            z = muldiv(z, b, RAY, up)
            if isinstance(z, str):
                return z
        e //= 2
        if e > 0:
            b = muldiv(b, b, RAY, up)
            if isinstance(b, str):
                return b
    return z


def rand_uint(rng: random.Random) -> int:
    """Magnitudes spread across the whole uint256 range, with edge values mixed in."""
    if rng.random() < 0.1:
        return rng.choice([0, 1, 2, WAD, RAY, MAX, MAX - 1, 2**128, 2**255])
    return rng.getrandbits(rng.randrange(1, 257))


def s(v: int | str) -> str:
    return str(v)


def main() -> int:
    rng = random.Random(SEED)
    md = {"x": [], "y": [], "d": [], "down": [], "up": []}
    for _ in range(N_MULDIV):
        x, y = rand_uint(rng), rand_uint(rng)
        d = rand_uint(rng) if rng.random() < 0.97 else 0
        for k, v in (
            ("x", x),
            ("y", y),
            ("d", d),
            ("down", muldiv(x, y, d, False)),
            ("up", muldiv(x, y, d, True)),
        ):
            md[k].append(s(v))

    wr = {
        k: []
        for k in (
            "x",
            "y",
            "wmulDown",
            "wmulUp",
            "wdivDown",
            "wdivUp",
            "rmulDown",
            "rmulUp",
            "rdivDown",
            "rdivUp",
            "divUp",
        )
    }
    for _ in range(N_WR):
        x = rng.getrandbits(rng.randrange(1, 200))
        y = rng.getrandbits(rng.randrange(1, 200)) or 1
        row = {
            "x": x,
            "y": y,
            "wmulDown": muldiv(x, y, WAD, False),
            "wmulUp": muldiv(x, y, WAD, True),
            "wdivDown": muldiv(x, WAD, y, False),
            "wdivUp": muldiv(x, WAD, y, True),
            "rmulDown": muldiv(x, y, RAY, False),
            "rmulUp": muldiv(x, y, RAY, True),
            "rdivDown": muldiv(x, RAY, y, False),
            "rdivUp": muldiv(x, RAY, y, True),
            "divUp": ceil_div(x, y),
        }
        for k, v in row.items():
            wr[k].append(s(v))

    rp = {"x": [], "n": [], "up": [], "down": []}
    regimes = [
        lambda: (RAY + rng.randrange(0, 21_979_553_151_239_153_029), rng.randrange(0, 2**26)),
        lambda: (rng.randrange(RAY // 2, RAY + 1), rng.randrange(0, 2**20)),
        lambda: (rng.randrange(0, 4 * RAY), rng.randrange(0, 200)),  # includes overflows
        lambda: (rng.randrange(0, 10**30), rng.randrange(0, 4)),
    ]
    for i in range(N_RPOW):
        x, n = regimes[i % len(regimes)]()
        for k, v in (
            ("x", x),
            ("n", n),
            ("up", rpow_spec(x, n, True)),
            ("down", rpow_spec(x, n, False)),
        ):
            rp[k].append(s(v))

    doc = {
        "generator": "spec/tools/gen_math_vectors.py",
        "seed": SEED,
        "note": "Random cases, exact expected values from Fraction arithmetic and an independent "
        "transcription of spec §2.3. A string result 'Overflow' / 'DivisionByZero' means the "
        "call must revert (Solidity Panic 0x11 / 0x12).",
        "mulDiv": md,
        "wadRay": wr,
        "rpow": rp,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, indent=1) + "\n")
    reverts = sum(v in ("Overflow", "DivisionByZero") for v in md["up"] + rp["up"])
    print(
        f"wrote {OUT}: {N_MULDIV} mulDiv, {N_WR} wad/ray, {N_RPOW} rpow cases ({reverts} reverting)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
