"""Measure rpow's rounding error against the exact value over random inputs (P10).

    uv run python spec/tools/rpow_error.py [--samples 12000] [--seed 10]

The exact x^n for n ~ 3e7 has billions of digits, so it is bracketed instead: the same
square-and-multiply at SCALE = 10^70 with every product floored (lo) and ceiled (hi) gives
lo <= exact <= hi with a width around 10^-60 — far below the 10^-27 being measured. Errors are
in RAY units (1 = 10^-27 of the value 1.0).

Bound checked: 0 <= rpowUp(x, n) - exact <= n * max(1, exact/RAY), and the mirror for rpowDown.

Why n and not the number of roundings: a rounding made early in the squaring chain is doubled by
every later squaring ((b + d)^2 ~ b^2 + 2bd). The rounding at squaring level j therefore reaches
the result multiplied by up to 2^(L-j), and summing over the bits of n gives at most n units, times
the growth factor when x > RAY. (A first guess, "error < number of roundings", was refuted by this
very script by six orders of magnitude.) Second-order terms are of relative size n/RAY, negligible
for every n below ~10^13.
"""

from __future__ import annotations

import argparse
import random
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from model.protocol.math import RAY, Overflow, Rounding, rpow  # noqa: E402

SCALE = 10**70
UP = SCALE // RAY  # 10^43: RAY units -> SCALE units


def bracket(x: int, n: int) -> tuple[Fraction, Fraction]:
    """lo <= x^n / RAY^(n-1) <= hi, as Fractions in RAY units."""
    lo = hi = SCALE
    blo = bhi = x * UP
    e = n
    while e > 0:
        if e & 1:
            lo = lo * blo // SCALE
            hi = -(-hi * bhi // SCALE)
        e >>= 1
        if e > 0:
            blo = blo * blo // SCALE
            bhi = -(-bhi * bhi // SCALE)
    return Fraction(lo, UP), Fraction(hi, UP)


DOMAINS = {
    # name: (x sampler, n sampler) — the regimes the protocol actually uses, and a broad one
    "interest growth: RAY..RAY+max rate, n <= 2^26 s": (
        lambda r: RAY + r.randrange(0, 21_979_553_151_239_153_029),
        lambda r: r.randrange(0, 2**26),
    ),
    "decay factors: 0.5..1 RAY, n <= 2^20": (
        lambda r: r.randrange(RAY // 2, RAY + 1),
        lambda r: r.randrange(0, 2**20),
    ),
    "near RAY, tiny distance: RAY +- 10^k, n <= 2^24": (
        lambda r: RAY + r.choice((-1, 1)) * r.randrange(0, 10 ** r.randrange(0, 12)),
        lambda r: r.randrange(0, 2**24),
    ),
    "broad growth: 1..2 RAY, n <= 160": (
        lambda r: r.randrange(RAY, 2 * RAY),
        lambda r: r.randrange(0, 161),
    ),
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=12_000)
    ap.add_argument("--seed", type=int, default=10)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    per = args.samples // len(DOMAINS)
    worst_ratio, total, failures = Fraction(0), 0, 0
    print(f"{'domain':52} {'n':>6} {'max up-err':>11} {'max down-err':>12} {'max err/bound':>13}")
    for name, (xs, ns) in DOMAINS.items():
        max_up = max_dn = Fraction(0)
        ratio = Fraction(0)
        done = 0
        while done < per:
            x, n = xs(rng), ns(rng)
            try:
                up, dn = rpow(x, n, Rounding.CEIL), rpow(x, n, Rounding.FLOOR)
            except Overflow:
                continue
            lo, hi = bracket(x, n)
            if not (dn <= lo and hi <= up):
                failures += 1
            err_up, err_dn = up - lo, hi - dn  # upper estimates of the true errors
            bound = n * max(Fraction(1), hi / RAY)
            if bound:
                ratio = max(ratio, max(err_up, err_dn) / bound)
            max_up, max_dn = max(max_up, err_up), max(max_dn, err_dn)
            done += 1
        total += done
        worst_ratio = max(worst_ratio, ratio)
        cells = f"{float(max_up):>11.3f} {float(max_dn):>12.3f} {float(ratio):>13.4f}"
        print(f"{name:52} {done:>6} {cells}")
    print(f"\nsamples: {total}; bracket violations (rpowDown <= exact <= rpowUp): {failures}")
    ratio_text = f"{float(worst_ratio):.4f}"
    print(f"worst observed error / (n * max(1, x^n/RAY^n)): {ratio_text} (<= 1 confirms the bound)")
    return 1 if failures or worst_ratio > 1 else 0


if __name__ == "__main__":
    raise SystemExit(main())
