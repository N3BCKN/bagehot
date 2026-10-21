# Static analysis triage

Every finding from `just static` (slither + aderyn) is either fixed or recorded here with a
justification the human can review. Detectors are never suppressed globally, and this file is
never edited merely to turn a check green.

Workflow: run `just static`, diff the findings against this table, fix what is real, add a row for
what is not. A row needs a reason a reviewer can disagree with — "false positive" alone is not one.

| id | tool | detector | location | severity | decision | justification | date |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

Decision is one of: `fixed` (with the commit), `accepted` (risk understood and taken),
`false-positive` (the detector's premise does not hold here, say why).

## Current state

`just static` at P00: slither analysed 24 contracts with 102 detectors, **0 results**. The only
Solidity in the repo is `contracts/test/unit/Sanity.t.sol` plus the pinned libraries, which
`contracts/slither.config.json` filters out of the report.

aderyn is skipped while `contracts/src/` holds no contracts — it exits 1 on an empty source
directory. The guard in the `static` recipe disappears on its own once the first contract lands at
P10; nothing needs to be changed then. See the open issue in `progress.md`.
