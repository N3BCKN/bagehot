# CHG-001: State rpow's error bound and bracket property in spec §2.3

- Status: **approved 2026-10-23 (option 1) and applied** — spec §2.3 *Accuracy (CHG-001)*, ADR-0028
- Raised: 2026-10-22, P10
- Affects: `docs/spec.md` §2.3 (documentation only — no formula, order or behaviour changes)

## Problem

`docs/spec.md` §2.3 fixes `rpow`'s algorithm exactly (least-significant-bit-first square-and-
multiply, every product rounded up, final squaring skipped) and notes the frequency effect
("one accrual of a year and 365 daily accruals … differ by 104 RAY units"), but states **no bound
on how far `rpow` may be from the exact power**. P10 requires the bound to be measured over at least
10,000 random inputs and recorded in the spec; with no bound in the spec, recording it is a spec
change.

## Evidence

`spec/tools/rpow_error.py` brackets the exact value x^n / RAY^(n−1) with a 70-digit floor/ceil
computation (width ~10^-60, far below the 10^-27 measured) and compares both rounding directions.

| run | samples | domains | bracket violations | worst error / bound |
|---|---|---|---|---|
| seed 10 | 12,000 | interest growth (x ≤ RAY + max rate, n ≤ 2^26); decay (0.5–1 RAY, n ≤ 2^20); near RAY ± 10^k, n ≤ 2^24; broad growth (1–2 RAY, n ≤ 160) | 0 | 1.0000 |
| seed 77 | 40,000 | same | 0 | 1.0000 |

The bound is tight (the worst ratio reaches 1.0 close to RAY, never exceeds it). The same property
is checked by `tests/model/test_math.py::test_error_bound_holds_on_a_fresh_sample` and, as
`rpowUp − rpowDown ≤ 2·n·max(1, value/RAY)`, by the Foundry fuzz test
`WadRayMathTest.testFuzz_rpow_upMinusDownWithinTwiceTheBound`.

Worked example: the derived constant itself, `rpow(RAY + RATE_PER_SECOND, 31_536_000)` (n = 3.15·10^7,
value ≈ 1.05): bound = 3.15·10^7 × 1.05 ≈ 3.3·10^7 RAY units, a relative error ≤ 3.3·10^-20.

**A first hypothesis was refuted by the data**, and the reason belongs in the spec: the error does
not scale with the number of rounded products (≈ 2·log₂ n) but with n. A rounding made at squaring
level j is doubled by every later squaring ((b + δ)² ≈ b² + 2bδ), so it reaches the result
multiplied by up to 2^(L−j); summed over the bits of n this is at most n units, times the growth
factor when x > RAY. Second-order terms are of relative size n/RAY (negligible below n ≈ 10^13).

## Options

1. **Add the bound and the bracket property to §2.3 as documented properties** (recommended).
   Text to add after the frequency paragraph:

   > *Accuracy.* For all x and n, `rpow` computed with every product rounded down is ≤ the exact
   > x^n / RAY^(n−1) ≤ `rpow` (rounded up): each rounded product is monotone in its arguments.
   > The rounded-up result exceeds the exact value by at most n · max(1, exact/RAY) RAY units
   > (second-order terms of relative size n/RAY aside) — linear in n, because an early rounding is
   > doubled by every later squaring. For a year of interest accrued in one step this is a relative
   > error below 4·10^-20. Measured at P10 on 52,000 random inputs (`spec/tools/rpow_error.py`,
   > CHG-001); the bound is tight.

   Consequences: none for behaviour; invariants and the drift analysis (§10.2) gain a citable bound.
2. **Leave §2.3 as is** and keep the bound only in `WadRayMath.sol` NatSpec and this file.
   Consequences: the spec stays silent on accuracy; P10's acceptance criterion ("recorded in
   docs/spec.md") is not met; later reasoning about interest drift has to cite code comments.
3. **Tighten the algorithm** (e.g. a final correction step) to get an error independent of n.
   Consequences: changes every rpow vector and the frequency example; buys nothing economically
   (the error is ~10^-20 relative). Not recommended.

## Recommendation

Option 1. Documentation only: no vector, contract or model change.

## Impact

| Area | Impact |
|---|---|
| `docs/spec.md` | §2.3 gains one paragraph (protected file: the human unlocks, Claude edits, human re-protects) |
| Invariants (P03) | none yet; I2's drift bound (§10.2) can cite it |
| `spec/vectors/` | none |
| Solidity (`WadRayMath.sol`) | none — NatSpec already states the bound |
| Python model (`model/math.py`) | none |
| Differential rules | none (tolerance stays zero) |
| Experiments run so far | none affected |
| Preregistration | none |
| ADR | a short ADR referencing CHG-001 after approval (skill step 4a) |
