# ADR-0017: Do every division with OpenZeppelin `Math.mulDiv` and an explicit `Rounding`

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

ADR-0015 fixes the rounding *direction* of every division; this decision fixes the *implementation*.
`a * b / c` overflows whenever the intermediate product exceeds 2^256 − 1, which in WAD arithmetic
happens at amounts the system must support (collateral × price, `P` × a scale factor). The standard
solution is a 512-bit intermediate, and OpenZeppelin's `Math.mulDiv` is the audited one.

## Decision

All fixed-point multiplication and division goes through two project helpers,
`mulDivDown(a, b, c)` and `mulDivUp(a, b, c)`, which wrap `Math.mulDiv` with
`Math.Rounding.Floor` and `Math.Rounding.Ceil` (`docs/spec.md` §2.2, §6.1). No other math library
is used, no hand-rolled 512-bit code exists, and no call site passes a rounding mode implicitly.
The Python model implements the same two helpers with exact integers (ADR-0022), and
`math.json` pins their behaviour including the edge cases.

## Alternatives considered

- **Solmate / PRB-Math.** Equivalent quality, but a second dependency with its own pinning and
  audit story; OpenZeppelin is already in the tree for ERC-20 and `SafeERC20`.
- **Hand-written `mulDiv`.** The one piece of arithmetic nobody should write twice.

## Consequences

- Intermediate overflow is impossible in a `mulDiv`; the remaining overflow risks are additions
  and the explicit caps (`CollateralTooLarge`, the supply cap, `MAX_PRICE`).
- A reviewer can find every rounding decision by grepping for two function names.
- The dependency is pinned and recorded in `docs/dependencies.md`; changing it needs a new ADR.
