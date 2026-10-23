# ADR-0028: Document rpow's bracket property and error bound in the specification

- Status: accepted 2026-10-23 (human)
- Date: 2026-10-23
- Prompt: P10 (measured), applied via `/spec-change` CHG-001
- Supersedes: —

## Context

Spec §2.3 fixes `rpow`'s algorithm exactly (least-significant-bit-first square-and-multiply, every
product rounded up) but stated no bound on its distance from the exact power, and P10 requires the
measured bound to be recorded in the spec. `spec/tools/rpow_error.py` measured it on 52,000 random
inputs across four domains (interest growth, decay, near RAY, broad growth): zero bracket
violations, worst error exactly at the bound. The bound is linear in `n`, not in the number of
rounded products, because a rounding at an early squaring is doubled by every later one.
Full evidence: `docs/changes/CHG-001-rpow-error-bound.md`.

## Decision

§2.3 states, as a documented property and not a new rule:
`rpow` with every product rounded down ≤ exact x^n / RAY^(n−1) ≤ `rpow` rounded up; and the
rounded-up result exceeds the exact value by at most `n · max(1, exact/RAY)` RAY units (second-order
terms of relative size n/RAY aside). The algorithm, its rounding directions and every vector are
unchanged.

## Consequences

- Invariant I2's drift analysis (§10.2) and the report can cite a bound from the spec rather than
  from code comments.
- The property is checked on both sides: `tests/model/test_math.py::test_error_bound_holds_on_a_fresh_sample`
  and `WadRayMathTest.testFuzz_rpow_upMinusDownWithinTwiceTheBound`. A future change to `rpow`
  that breaks it is a spec violation, not a tuning choice.
- No behaviour, contract, model or vector change; reversing it is a documentation edit through a
  new ADR.

## Alternatives considered

- **Leave §2.3 silent and keep the bound in NatSpec only.** Rejected: P10's acceptance criterion
  requires it in the spec, and later reasoning about interest drift would rest on code comments.
- **Change the algorithm to make the error independent of n** (a final correction step).
  Rejected: it changes every rpow vector and the frequency example for an error of order 10^-20
  relative, which has no economic effect.
