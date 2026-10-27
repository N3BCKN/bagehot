# CHG-010: I3's gain bounds omit the gains §6.6.7 ignores beyond SCALE_SPAN; a correct pool breaks the interest bound

- Status: **approved by the human 2026-10-26** ("aproved, files unlocked, please proceed"; proposed the same day, P19 precision study). Code, model and tests applied. **Applied 2026-10-27:** spec/invariant text written.
- Raised: P19, `model/tools/sp_precision.py` (the precision study the P19 prompt requires).
- Affects: `docs/invariants.md` I3 ("Per-depositor attribution", the two gain bounds). No spec
  algorithm, contract, model or vector change.

## Problem

I3 bounds a depositor's gain against its exact pro-rata share by
`T_j / DP + Σ_{events k since snapshot} (T_k / DP + 1)` (`docs/invariants.md` I3, "Per-depositor
attribution"). The derivation covers the per-unit floors, the outer `mulDivDown` and the error
carry. It does not cover a rule the spec states on purpose, §6.6.7:

> Scales beyond `snapScale + 2` are ignored; the depositor's remaining fraction there is at most
> `SCALE_FACTOR^-2 = 10^-18`.

Gains booked while `currentScale > snapScale + SCALE_SPAN` are never paid to that depositor. The
remaining fraction is tiny, but the gain *per unit* is not bounded for interest: an interest event
credits `g / T` per wei of deposit, and after a near-emptying offset `T` can be small while `g` is
the pool's share of interest on the whole system's debt. (For collateral, `c ≤ 0.75·d + 1 ≤ T`
(§6.6.3) keeps the per-unit gain near 1, so the omitted term is at most about the remaining share in
wei; it never broke the bound in the study, and the term is not needed for soundness there: under
`c ≤ 0.75·d + 1` the omitted collateral telescopes to at most `0.75·s_entry + n_ignored`, with
`s_entry ≤ 10^-18 · initial` the depositor's share on entering the ignored scales and `n_ignored` the
number of such offsets — already covered by `T_first / DP ≥ initial / DP` and the `+1` per event.
Option 1 adds it to both bounds for symmetry, so the two read alike.)

No value is lost to anyone else: the unpaid part stays in `interestGainsBalance` (or
`collGainsBalance`) as inert dust, and `Σ gains ≤ balance` holds exactly. The contract is correct;
the invariant's bound is incomplete.

## Evidence

- **Counterexample** (seed 190022, `tests/model/test_sp_precision.py`): depositor a1 deposits
  840e18 into a pool holding a 1-wei residual (scale 4). An offset of `T − 1` leaves `T = 1` and moves
  the scale 4 → 7 in one step; a1's exact share is now 0.99999 wei and its compounded deposit floors to
  0. After a0 deposits, interest of 4.3·10^23 over `T ≈ 3.1·10^20` books 1,369 wei per wei of deposit
  in scale 7. The contract — bit-for-bit with the model on this sequence family
  (`StabilityPoolPrecisionTest`) — pays a1 0; the exact share is 1,369 wei; I3's bound for that
  depositor is about 2 wei.
- **Study** (200 sequences × 300 steps, all four regimes, `uv run python -m model.tools.sp_precision
  --cases 200 --steps 300`): 170 step-violations of the current I3 text, every one an interest gain
  booked in a scale §6.6.7 ignores for that depositor (or persisting from one after a later epoch
  change). Largest: 2.1·10^13 wei. The compounded bound and the collateral bound hold everywhere.
- **The proposed bound below**: 0 violations on the same 60,000 steps.

## Options

1. **Add the ignored-scales term to both gain bounds** (recommended). Sound by construction: the
   omitted amount is exactly the depositor's exact share of gains booked in scales the spec ignores,
   and the remaining error is what I3 already bounds. Measured: 0 violations.
2. **Change the protocol so interest beyond `SCALE_SPAN` is paid.** Needs more scales summed in
   `gain()` (gas on every deposit, withdrawal and claim) or a separate interest accounting; a spec,
   contract, model and vector change to recover dust of the order of 10^-5 tokens. Not recommended.
3. **Keep the bound and call the interest side "empirically validated".** Rejected: a correct
   implementation breaks it, and a sound derivation exists (option 1).

## Exact wording (option 1) to apply to `docs/invariants.md` I3

### Replaces the two-line gain formula block under "*Gains*"

```
|gExactCollGain[a] − collGain(a)|  ≤  T_j / DECIMAL_PRECISION
                                      + Σ_{offset events k since snapshot} (T_k / DECIMAL_PRECISION + 1)
                                      + Σ_{offset events k since snapshot, booked while
                                          currentScale > snapScale(a) + SCALE_SPAN} c_k · gExactShare_k[a] / T_k
|gExactInterestGain[a] − interestGain(a)|  ≤  the same form over interest events, with g_k for c_k
```

### Added after the paragraph that ends "…not a count times a constant."

**The ignored-scales term.** §6.6.7 ignores gains booked while `currentScale > snapScale +
SCALE_SPAN`; the depositor's remaining fraction there is at most `10^-18` of its deposit, but what
that remainder would have earned is never paid to it — it stays in `collGainsBalance` /
`interestGainsBalance` as inert dust, so the totals stay exact. The last term is exactly the
depositor's exact share of those gains, with `gExactShare_k[a]` its rational share at event `k`. For
collateral it is small (`c ≤ T`, §6.6.3, keeps the per-unit gain near 1). For interest it is not: an
interest event credits `g / T` per wei, and after a near-emptying offset `T` can be small while `g`
is the pool's share of interest on the system's whole debt. Measured by the P19 precision study:
up to 2.1·10^13 wei. Counterexample to the bound without this term: seed 190022 in
`tests/model/test_sp_precision.py` (CHG-010).

### "Checked in" — add after "`model.invariants.check_I3_attribution(state, exact)` for the two bounds,"

and the P19 precision study `model/tools/sp_precision.py` (200 sequences × 300 steps; its integer
model replayed bit-for-bit against the contract by `StabilityPoolPrecisionTest`),

## Impact

- `docs/invariants.md` I3 only. On approval, `model.invariants.check_I3_attribution` takes the new
  term (today `check_I3_attribution_chg010`), and the study's "current" count goes to 0.
- Spec: none — §6.6.7 already states the rule; the bound now accounts for it.
- Contract, Python model, vectors, differential: none.
- Experiments: none have run.
