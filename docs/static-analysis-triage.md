# Static analysis triage

Every finding from `just static` (slither + aderyn) is either fixed or recorded here with a
justification the human can review. Detectors are never suppressed globally, and this file is
never edited merely to turn a check green.

Workflow: run `just static`, diff the findings against this table, fix what is real, add a row for
what is not. A row needs a reason a reviewer can disagree with — "false positive" alone is not one.

| id | tool | detector | location | severity | decision | justification | date |
|---|---|---|---|---|---|---|---|
| SA-001 | aderyn | internal-function-used-once | src/lib/WadRayMath.sol:75 | Low | accepted | `rpow(x, n)` is the spec's power function (§2.3, every product rounded up) and the only form protocol code is meant to call; the three-argument `rpow(x, n, rounding)` exists so tests can bracket the exact value with Floor. "Used once" is true only until P15: VaultManager (interest index, R4), RedemptionModule (base-rate decay, R19) and DutchAuctionHouse (price curve, R23) all call it. Re-check at P33, when it should no longer fire. | 2026-10-22 |

Decision is one of: `fixed` (with the commit), `accepted` (risk understood and taken),
`false-positive` (the detector's premise does not hold here, say why).

## Current state

`just static` at P00: slither analysed 24 contracts with 102 detectors, **0 results**. The only
Solidity in the repo is `contracts/test/unit/Sanity.t.sol` plus the pinned libraries, which
`contracts/slither.config.json` filters out of the report.

`just static` at P10 (first contracts in `src/`: `Rounding.sol`, `WadRayMath.sol`): slither
**0 results**; aderyn 88 detectors, **1 low** (SA-001, accepted). From P10 aderyn is gated too:
it writes `reports/static/aderyn.json` and `scripts/check_triage.py --aderyn` fails on any finding
without a row, exactly as for slither (closes open issue P01-4).
