# CHG-002: A tiny partial redemption can leave a boundary position below MCR

- Status: proposed (awaiting human review)
- Raised: 2026-10-22, P03
- Affects: `docs/spec.md` §6.7.3 (partial redemption), §3.1 (`MIN_PRICE` range); invariant I5

## Problem

Blueprint §16.2 states I5 as "a redemption creates no position with ICR below MCR or debt below the
minimum". `docs/spec.md` §6.7.3 enforces the debt half explicitly (`d = min(remaining,
debt − MIN_DEBT)`, with a proof that `debtOf(n − dn) ≥ debt − d ≥ MIN_DEBT`) but makes **no check
on the resulting ICR**. The loop skips positions already below MCR; it never re-checks the one
position it partially redeems from.

In exact arithmetic no check is needed: the redeemer takes collateral worth `d·(1 − feeRate)` and
cancels `d` of debt, a bundle whose ratio is below 1 and therefore below MCR, so removing it
*raises* the position's ICR. That is the intended effect of D-2 (the fee stays in the position).

With integer arithmetic the argument fails at the margin. The debt relief is
`dn = mulDivDown(d, RAY, index)` and the position's remaining debt is
`mulDivUp(n − dn, index, RAY)`: both round against the borrower, so the *value* of the debt
cancelled can be less than the value of the collateral taken. For a position sitting exactly at
MCR there is no head-room to absorb that, and its ICR ends below MCR.

## Evidence

Reproduced with exact integer arithmetic against the spec's own formulas (`model/math.py`,
`mulDivUp`/`mulDivDown`), on positions placed at the smallest collateral satisfying
`coll·price ≥ MCR·debtOf(n)`.

**Counterexample at the START parameters** (`MCR = 1.1e18`, `MIN_DEBT = 2000e18`,
`feeRate = 0.005e18`, **`price = MIN_PRICE = 10e18`**, `index = 1.23 RAY`):

```
n = 56551713917667894610000     debt = 69558608118731510370300     d = 11 wei
dn   = mulDivDown(11, RAY, index) = 8      -> 8 wei of normalised debt cancelled
out  = mulDivDown(11, WAD − fee, price) = 1 -> 1 wei of collateral taken
before:  coll·price − MCR·debt  =  0          (exactly eligible)
after :  coll·price − MCR·debt  = −1e17       (below MCR, ~1.3e−24 relative)
```

Sweeping `index` from 1.00 to 4.00 in steps of 0.01 at `price = 10e18`: **57 of 300 index values
admit a violating `d`**.

**The necessary conditions** explain where the window is:

```
out ≥ 1                         ⇒  d  ≳  price / WAD
MCR·Δdebt < d·(WAD − feeRate)   ⇒  d  ≲  10.5 · (index/RAY + 1)      at MCR = 1.1, fee = 0.005
```

so a violation is possible whenever `price/WAD ≲ 10.5·(index/RAY + 1)`. At `MIN_PRICE = 10e18`
that holds for every `index ≥ RAY`. The window widens as the index grows, so **no fixed price
floor closes it**: §3.1 allows `ANNUAL_RATE` up to 1.0, where the index doubles yearly and even
`price = 2000e18` falls inside the window within a decade.

> **Correction.** The first version of this change request claimed "no violation found" at
> `price ≥ 10e18` and recommended raising the `MIN_PRICE` floor on that basis. That claim came
> from a random search whose samples almost never landed in the narrow `d` window described above;
> absence of hits was reported as evidence of absence. The `spec-auditor` found the counterexample
> by searching the window directly. The reachability table below is the corrected one.

| configuration | result |
|---|---|
| `price = 10e18` (the **start** value of `MIN_PRICE`), `index ∈ [1.00, 4.00]` | **violations at 57 of 300 index values**, smallest `d` = 11 wei |
| `price = 2e18` (the range floor), `index ≤ 1.3` | violation at `d` = 5 wei |
| any `price`, `index` large enough that `price/WAD ≲ 10.5·(index/RAY + 1)` | violation |

**Impact if left unfixed.** A position at exactly MCR can be pushed fractionally below it by a
redemption of a few wei, making it liquidatable. The economics are negligible — the attacker pays
gas to move one wei of collateral, and a position at exactly MCR is one price tick from
liquidation anyway — but I5 is a zero-tolerance invariant and a correct implementation fails it.
The borrower also takes a strictly unfavourable trade at that scale: collateral leaves and the
debt cancelled is worth marginally less.

## Options

1. **Post-check in the redemption loop** (recommended). After computing `out` and `dn` for the
   partial, require
   `(c − out)·price ≥ MCR·debtOf(n − dn)`; if it fails, cancel the partial exactly as a stale hint
   does — no state change, loop ends, `redeemed` keeps whatever the full redemptions produced.
   Consequences: one extra cross-multiplication per redemption (no division, no new storage);
   §6.7.3's normative pseudocode changes and the redemption vectors are regenerated; a new
   cancelled-partial vector is added. I5 then holds for every configuration and every index. This
   is the only option that actually closes the window.
2. **Raise the `MIN_PRICE` floor** from `2e18` to `10e18`. **Insufficient** — the counterexample
   above is *at* `10e18`. Any fixed floor fails as the index grows. Rejected.
3. **Minimum redemption amount** (e.g. `amount ≥ 1e12`). Blunt, adds a parameter and a revert, and
   the window scales with the index rather than with absolute size, so a floor chosen today does
   not stay sufficient. Rejected.
4. **State I5 with a tolerance.** Rejected: a tolerance on "a position must be above MCR" is
   exactly the hidden weakening `CLAUDE.md` forbids. The property is binary.

## Recommendation

Option 1. It is a small, local change to a frozen algorithm, and it is the only one that makes the
invariant true. The cost is regenerating `redemption.json` and adding one vector.

Until it is approved, I5 in `docs/invariants.md` records the defect and
`test_redeem_tinyPartialAtMcrBoundary` is expected to fail at the start parameters. It must not be
weakened to pass.

## Impact

| Area | Impact |
|---|---|
| `docs/spec.md` | §6.7.3 pseudocode (normative order: the check sits after `out`/`dn` and before `applyPending`), and the "Rules made explicit" list gains the cancelled-partial case |
| `docs/invariants.md` | I5's defect note removed once implemented |
| `spec/vectors/` | `redemption.json` regenerated; one new vector for a partial cancelled by the post-check |
| Solidity | `VaultManager.redeemCollateral` (P16) |
| Python model | Same change, same commit |
| Differential | The cancelled partial is a new outcome to compare; no new revert name (the loop ends normally) |
| Experiments | None run yet |
| Preregistration | None — `MIN_PRICE` is not a swept parameter |
