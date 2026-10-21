---
name: solidity-rules
description: Security and correctness checklist for Bagehot Solidity code — rounding, accounting, reentrancy, oracle handling, loops, wiring. Use whenever writing, editing or reviewing any .sol file in contracts/.
user-invocable: false
paths: "contracts/**/*.sol"
---
Apply on every change. A box you cannot tick is a finding to report, not to ignore.

## Arithmetic and rounding
- Use `Rounding.mulDivDown/mulDivUp` (wrapping OZ `Math.mulDiv`) for every product-then-divide on
  amounts, prices, indices, P/S/G accumulators and shares. Look up the direction in the spec's
  rounding table; add a NatSpec `@dev rounding:` line naming it.
- Never divide before multiplying. Never compare values in different scales (WAD vs RAY vs 8-dec
  feed); convert at the boundary (OracleAdapter for prices).
- Debt of a position = `normDebt * index / RAY` rounded **up**; repayment converts to normDebt
  rounded **down**; collateral sent out rounded **down**.
- Check overflow bounds for `uint128` packing with realistic maxima (document them).

## Accounting
- Every token movement updates internal accounting in the same function, before the external call.
- For each holder contract, `token.balanceOf(this)` must equal the sum of its internal claims
  (I1). If you add a new bucket (surplus, gas reserve, fees), add it to the invariant.
- Stable supply identity (I2): mint only for new debt or accrued interest; burn on repay, redeem,
  pool offset, auction purchase, reserve cover. Any other mint/burn is a bug.

## External calls and reentrancy
- Checks–effects–interactions; `nonReentrant` (transient) on state-changing externals of every
  contract that holds tokens.
- WETH via `SafeERC20`. Assume nothing about token hooks; still follow CEI.
- Oracle calls go through OracleAdapter's try/catch with a gas cap; after a failed call require
  `gasleft()` above the threshold so a caller cannot fake an oracle failure by under-supplying gas.
- The auction buyer callback (P33) is the only arbitrary external call: state must be final and
  consistent before it; verify payment after it; `nonReentrant` across the whole auction house.

## Access and wiring
- No owner, no setters. `wire(...)` is callable exactly once by the immutable `deployer`, emits
  `Wired`, sets `wired = true`; every external function except views requires `wired`.
- `onlyVault`, `onlyPool` style modifiers compare against wired immutable-like storage; test both
  the allowed caller and an attacker.

## Liveness and DoS
- Every loop has a hard bound (`maxIterations` argument or immutable constant).
- Hints: validate; bounded walk; revert `StaleHint()` instead of unbounded traversal.
- Repay and addCollateral never depend on the oracle (I9).
- No function can be blocked by a third party leaving dust (minimum amounts, explicit dust rules).

## Oracle usage
- Price-sensitive operations call `fetchPrice()` and revert `PriceUnusable()` when `usable == false`
  (I12). The usage table in the spec is authoritative.

## Events and errors
- Emit spec-defined events with all fields needed to rebuild state (I14). Custom errors only,
  named exactly as in the spec.

## Review before done
- Run the `security-reviewer` subagent on the diff for any contract prompt.
