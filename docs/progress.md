# Progress

Claude updates this file at the end of every session. Status: todo · in progress · done · blocked.

| Prompt | Title | Status | Commit | Notes |
|---|---|---|---|---|
| P00 | Repository bootstrap and toolchain | done | a4e5b1d | `just check` and `just static` green; all toolchains pinned; hooks verified |
| P01 | Continuous integration | done | c47245f | PR [#1](https://github.com/N3BCKN/bagehot/pull/1), run [39670041216](https://github.com/N3BCKN/bagehot/actions/runs/39670041216) green: 5 jobs pass, `differential (quick)` skipped as designed |
| P02 | Protocol specification (human gate) | done | a38feab, 6c8f001 | Approved at the gate with one override (D-27, the critical-TCR redemption gate) and nine confirmations; `docs/spec.md` and `spec/vectors/**` protected by the human |
| P03 | Invariants (human gate) | todo | | |
| P04 | ADRs and threat model skeleton | in progress | | 26 ADRs written as `proposed`; threat model filled (23 threats, trust assumptions, assets/actors, boundaries). Awaiting the human: review, set `Status: accepted`, protect the accepted files |
| P05 | Preregistration draft | done | | DRAFT: Q1–Q3, H1–H3 with decision rules, primary + 9 secondary metrics defined over a named output schema, risk appetite, S1–S9, parameter grid, analysis plan, exclusions. 14 `TBD-P30` placeholders |
| P06 | Price data | todo | | |
| P07 | Oracle and sequencer history on Base | todo | | |
| P08 | Liquidation events and liquidatable windows | todo | | |
| P09 | Stress blocks and transaction costs | todo | | |
| P10 | Math library and shared vectors | todo | | |
| P11 | StableToken, wiring pattern and mocks | todo | | |
| P12 | OracleAdapter | todo | | |
| P13 | SortedPositions and hint helpers | todo | | |
| P14 | VaultManager I: positions and borrowing | todo | | |
| P15 | VaultManager II: interest accrual and routing | todo | | |
| P16 | RedemptionModule | todo | | |
| P17 | Invariant harness and Medusa | todo | | |
| P18 | Local deployment, factory and manifest | todo | | |
| P19 | StabilityPool (product-sum) | todo | | |
| P20 | Liquidation via pool and redistribution | todo | | |
| P21 | DeficitLedger and invariant extension | todo | | |
| P22 | Python protocol model | todo | | |
| P23 | Differential testing harness | todo | | |
| P24 | Oracle and cost models | todo | | |
| P25 | Fork liquidity measurement and slippage model | todo | | |
| P26 | Borrower and depositor agents | todo | | |
| P27 | Liquidator agent and calibration | todo | | |
| P28 | Price path generator | todo | | |
| P29 | Simulation engine and sweep runner | todo | | |
| P30 | Preregistration freeze (human gate) | todo | | |
| P31 | Sweeps for deployment A and fork verification | todo | | |
| P32 | Interim report and publication (MVP) | todo | | |
| P33 | DutchAuctionHouse | todo | | |
| P34 | Auction invariants, model and differential | todo | | |
| P35 | Sweeps for deployment B and comparison | todo | | |
| P36 | ShutdownModule | todo | | |
| P37 | Hardening: campaigns, static analysis, gas | todo | | |
| P38 | Security self-review | todo | | |
| P39 | Fork deployment and end-to-end scenario | todo | | |
| P40 | Liquidation bot | todo | | |
| P41 | Indexer and invariant monitor | todo | | |
| P42 | Base Sepolia deployment (human broadcast) | todo | | |
| P43 | Final report | todo | | |
| P44 | Publication pack | todo | | |
| P45 | Optional: read-only dashboard | todo | | |

## Session log

<!-- newest first: date · prompt · what changed · decisions · next -->

### 2026-10-22 · P02 gate · Overrides applied

The human approved the specification with nine confirmations and one override. What changed in
`docs/spec.md`, `spec/vectors/` and `docs/threat-model.md`:

- **Override (gate question 9) — redemptions are no longer allowed at any TCR.** `redeem` reverts
  `TCRBelowCritical()` while `systemColl · price < CRITICAL_TCR · systemDebt`, on exactly the
  quantities and threshold the shutdown trigger uses; between `CRITICAL_TCR` and `MCR` redemptions
  stay allowed. `ShutdownModule` gains the view `belowCritical(price)` and `RedemptionModule.wire`
  gains the shutdown module. New deviation D-27, new error, new vector `redemption.json#tcr_guard`,
  and a proposed P03 invariant in Appendix B. `redeem` does **not** call `check()` — the revert
  would roll the shutdown back.
- **Parameter values are configuration** (§3 preamble): the spec freezes the parameter set, units,
  ranges, meanings and formulas; a value may move inside its range after P07 without
  `/spec-change`, as long as §3.3 still holds and §3.2 is recomputed.
- **`TIP` renamed `RESET_TIP`** and the two incentives separated in words: the auction starter
  takes the whole gas reserve of the liquidated position (§6.8.2), the resetter is paid a fixed
  `RESET_TIP` from the DeficitLedger reserve, capped by its balance and only on a reset that
  actually met `TAIL`/`CUSP` (§6.8.5).
- **Pool interest ordering confirmed** (gate question 8): `deposit`, `withdraw` and `claimGains`
  already call `vaultManager.accrue()` before reading or writing any snapshot. §5.3.1 now says so
  explicitly, with the new vector
  `product_sum.json#deposit_after_idle_gets_no_back_interest` (30 idle days: alice, the only
  depositor, gets 120.546… stable of interest, bob, who deposits afterwards, gets 0).
- **Known limitations** (§1.4) and `docs/threat-model.md` now carry the cost of pure pro-rata
  settlement (an unrepaid position forfeits its surplus collateral), full liquidation only, and
  depositor flight. The threat register has its first row, T-01 (redemption run below par).
- **§12.1 added**: the kit's thirteen "Corrections to the blueprint" checked one by one. Items 1–4,
  11–13 were already reflected; item 5 (zero differential tolerance) is noted in Appendix B;
  items 6–10 are data/experiment work and are carried forward below.

Vectors: 56 in 12 files (two new). The reference implementation reproduces the other ten files
byte-for-byte, so nothing else moved except the `RESET_TIP` key.

**Audit of the gate changes.** `spec-auditor`, spec-only mode, scoped to the changed sections.
Round one: 1 blocker, 3 major, 9 minor. The blocker and the majors were all in the new redemption
gate, and all three were the same kind of mistake — claiming the gate and the shutdown trigger are
"one number" when they were not:
- **B1** `belowCritical` left out `check()`'s `live` guard, so in an empty system with residual
  deficit dust every redemption would have been blocked for ever. `live` is now in the view, which
  §5.8 spells out as pseudocode.
- **M2** `check()` covers the deficit before measuring, `redeem` does not, so the gate is strictly
  tighter. Rather than make a redemption burn the reserve as a side effect, the spec now states
  the one-way relation: whatever would trigger a shutdown is already blocked, not the converse.
- **M3** In B, a buyer's `onAuctionPurchase` callback sees a lagged `systemColl`/`systemDebt`;
  `check()` is guarded against exactly that and the new gate was not. `redeem` now carries the
  same `AuctionCallbackActive` guard, which is why `RedemptionModule.wire` also takes the house.
Nine minor fixes: a stale `TIP` in an `auction.json` note, an Appendix B cross-reference, the
`index` vs `currentIndex()` equivalence, the overflow caveat on the view's `price` argument, §5.5's
use of the display `tcr()`, §3.1's `CRITICAL_TCR` meaning, the D/E rider on the configuration
paragraph, §12.1's provenance line, the §1.3/§1.4 duplication, and the pool "accrual comes first"
paragraph moved to a §5.3 preamble. The auditor recomputed both new vectors field by field from
the spec formulas and matched every value.

**Gate follow-ups (human, after the first report).** ADR-021's index entry in `docs/adr/README.md`
now records the new `RedemptionModule → ShutdownModule / DutchAuctionHouse` wiring edge and the
absence of a reverse dependency; the P03 invariant carries the placeholder id `I15`; the
zero-tolerance methodology note moved out of spec Appendix B into Carry-forward above.

**Round two** (same agent, scoped to the fixes): **0 blockers, 1 major, 8 minors**, every
round-one finding confirmed resolved. The major was that the `I15` draft had become unimplementable
as an *iff*: the new `AuctionCallbackActive` guard sits inside the measurement window the invariant
names, so a `redeem` called from a buyer callback could satisfy the right-hand side and still
revert. The premise now starts after that check. The eight minors were precision fixes: two summary
sentences that still quoted the gate without `live`, the dropped `usable` conjunct in §5.8's "in
full", a missing cross-contract constraint (§3.3 constraint 7: the `auctionHouse` argument of
`ShutdownModule.wire` and `RedemptionModule.wire` must be the house in B and `address(0)` in A —
unverifiable on-chain, so the deployment script asserts it), the §4.6 "both" covering three
addresses, §5.10's view list, §12.1's "items 6–10", Appendix A's §5.3.1 reference, and the ADR-021
no-cycle argument, which ruled out the wrong edges. The auditor independently enumerated the wire
graph and the run-time call graph around the RedemptionModule and confirmed the claim holds: one
inbound address edge (`VaultManager.wire`), no inbound call edge, no hook.

**Next.** The human protects `docs/spec.md` and `spec/vectors/**`; then P03.

### 2026-10-21/22 · P02 · Protocol specification

**Changed.** `docs/spec.md` (12 sections + appendices: scope, notation, 27 parameters with ranges and
start values, constructor/`wire` signatures, state of all 9 contracts, every external operation in
normative pseudocode, algorithms, oracle table, 34-row rounding table, permission matrix, I1/I2
identities with a derived drift bound, events, errors, 26 deviations from the blueprint).
`spec/vectors/` — 54 vectors in 12 files (format v2: system vectors are complete public-operation
logs from deployment; unit vectors drive one algorithm from an explicit state) + README.

**Decisions (human, at the plan gate).** D-1 deployment A redistributes the pool remainder (deficit
only with no stakes left); D-2 the redemption fee stays in the redeemed positions; D-3 in B the
penalty is in the tab and goes to the reserve.

**How the numbers were produced.** A throwaway exact-integer reference (scratchpad, not committed —
P22 builds the real model) transcribes the pseudocode; vectors are generated from it. Before
generation it was fuzzed against the spec's identities: 60 seeds × 300 steps × {A, B} for I1/I2 and
the bucket inequalities; a product–sum stress with an exact-fraction shadow (5,247 scale changes,
2,221 epoch changes).

**Design bugs found and fixed before freezing.**
- Product–sum error carry carried in `P` units over-credited depositors by up to 671 wei across
  epochs → carry made independent of `P` (Liquity structure).
- Interest into a near-empty pool could overflow `G` → pool share only when
  `totalDeposits ≥ MIN_DEPOSIT`.
- (spec-auditor B1) Stakes stuck at 0 forever after the last position is liquidated with pending
  dust → snapshots reset when no position remains.

**Audit.** `spec-auditor` in spec-only mode, three rounds: 1 blocker, 10 major, 18 minor → all
resolved; round two found 5 small new issues (N1–N5) → resolved. Every vector value the auditor
recomputed independently matched.

**Next.** Human gate: approve, then protect `docs/spec.md` and `spec/vectors/**`. Then P03.

### 2026-10-21 · P01 · Continuous integration

**Changed.** `.github/workflows/pr.yml` (jobs: `detect`, `contracts`, `static`, `python`,
`differential-quick`, `secrets`) and `.github/workflows/nightly.yml` (cron 03:17 UTC plus manual
dispatch; jobs: `detect`, `invariants`, `medusa`, `halmos`, `differential-long`, `report`).
New `scripts/check_triage.py` and `.gitleaks.toml`. README carries both badges.

**justfile changes** — all P00 recipe names kept; two added so CI runs the same commands as the
local loop rather than its own copies:
- `fmt-check` split into `fmt-check-sol` and `fmt-check-py`. `fmt-check` itself is unchanged in
  behaviour and still runs both; the halves let the contracts job check Solidity and the python
  job check Python without duplicating the commands.
- `static` now runs slither with `--fail-none --json reports/static/slither.json` and then
  `scripts/check_triage.py`. This is **stricter**, not looser: slither's own exit code fails on
  severity, while the triage gate fails on a finding of *any* severity that has no row in
  `docs/static-analysis-triage.md`.
- `py-test` now filters `not slow and not network and not fork`, matching the filter P01
  specifies for CI. Fork tests need a Base archive RPC that neither the quick loop nor CI has.

**Decisions.**
- Secret scanning runs the pinned **gitleaks binary**, not `gitleaks-action`: the action wants a
  `GITLEAKS_LICENSE` secret for organisation repositories and write permission to comment on
  PRs. The PR workflow carries no secrets and stays `contents: read`.
- Jobs call `just` recipes rather than re-spelling the commands, so CI and `just check` cannot
  drift. Each job installs `rust-just==1.59.0`.
- `ubuntu-24.04` rather than `ubuntu-latest`, so a runner image change is a deliberate edit.
- Every GitHub expression reaches a shell through an `env:` block, never interpolated into the
  script body — a branch name or PR title cannot inject commands.
- Nightly `report` can only use data from an artefact: `data/processed/` is git-ignored. Run the
  workflow manually with `data_run_id` set to a run that uploaded a `processed-data` artefact.
  With no artefact it writes a notice and exits 0 rather than inventing numbers.

**Verified locally.**
- `actionlint 1.7.12` — **0 issues** on both workflows.
- All six pinned action SHAs re-resolved against the GitHub API and confirmed to match their
  commented tags. (One SHA was wrong in my first draft and was caught by exactly this check.)
- Every job has `timeout-minutes`; `permissions: contents: read` at the top of both files; no
  `pull_request_target`; no secrets in `pr.yml`; concurrency cancels superseded PR runs.
- `scripts/check_triage.py` exercised on four paths: clean (exit 0), two untriaged findings
  (exit 1, printing paste-ready rows), a malformed decision value (exit 2), slither output
  missing (exit 2).
- `gitleaks 8.30.1` over history and working tree: clean. A planted `ghp_…` token in `config/`
  was caught; the same token under `contracts/lib/` was allowlisted, as intended.
- `just check`, `just static` — green.

**CI gate closed.** Repository `N3BCKN/bagehot`, made public after a clean pre-publication audit.
PR [#1](https://github.com/N3BCKN/bagehot/pull/1), run
[39670041216](https://github.com/N3BCKN/bagehot/actions/runs/39670041216):

| job | result |
|---|---|
| `detect optional trees` | success — reported `symbolic=false differential=false src=false` |
| `contracts` | success — `forge fmt --check`, `forge build --sizes`, `forge test`; halmos steps skipped |
| `static analysis` | success — slither plus the `check_triage.py` gate; aderyn skipped on empty `src/` |
| `python` | success — `uv sync --locked`, ruff, pytest |
| `secret scan` | success — diff-scoped gitleaks on the `pull_request` event, plus the working tree |
| `differential (quick)` | skipped — `differential/` arrives at P23 |

Two real defects were caught by running it rather than by reading it: a fabricated action SHA
(found locally by re-resolving every pin against the API) and the `~/.local/bin` bug in P01-7,
which only a clean machine could show.

**Next.** P02, protocol specification (human gate).

### 2026-10-21 · P00 · Repository bootstrap and toolchain

**Changed.** Full directory layout from the repository map, with `.gitkeep` in every empty
directory. Foundry project under `contracts/` (`foundry.toml`, `remappings.txt`,
`slither.config.json`, `test/unit/Sanity.t.sol`) with forge-std and OpenZeppelin as pinned
submodules. uv project at the root (`pyproject.toml`, `.python-version`, `uv.lock`,
`tests/test_sanity.py`). `justfile` completed: every later-stage recipe now guards itself and
names the prompt that fills it in. `.gitignore` rewritten. New docs: `dependencies.md`,
`static-analysis-triage.md`, `adr/README.md`, stubs for `spec.md`, `invariants.md`,
`preregistration.md`, `threat-model.md`, `gas.md`, plus `README.md` and `LICENSE`.

**Decisions (human).**
- `solc 0.8.28`, `evm_version = "cancun"` — ADR-018 still to be written at P04.
- Licence: MIT.
- `.gitignore`: `justfile`, `CLAUDE.md`, `contracts/CLAUDE.md` and `.claude/` are now **tracked**.
  The previous ignore list excluded them, and its `env` line did not actually match `.env`.
- medusa: pinned release binary in a git-ignored `.tools/` rather than Homebrew or a Go toolchain.
- Python packages are installed only via `uv tool install` at exact versions; nothing global.

**Versions pinned.** foundry 1.8.1 · solc 0.8.28 · forge-std v1.17.0 · OZ v5.7.0 ·
slither 0.11.6 · aderyn 0.6.8 · halmos 0.3.3 · medusa 1.5.1 · just 1.59.0 · uv 0.11.26 ·
CPython 3.12.13. Full table with install commands and the medusa checksum in `dependencies.md`.

**Guardrails verified.**
- `protect_paths.py` blocked an `Edit` of `.claude/protected-paths.txt`, and separately blocked a
  write to a path outside the repository. `.claude/settings.json` is additionally protected by
  Claude Code's own schema validator, which rejected the probe before the hook was reached.
- `guard_bash.py` blocked the prompt's own verification command — the payload string contains
  `--broadcast` with an `--rpc-url` of `base`, so the hook fired on the outer Bash call rather
  than letting it reach the pipe. Stronger evidence than the expected exit 2. It also blocked a
  later `git ls-files | grep` whose pattern mentioned a secrets filename.
- `python3` is on PATH (3.14.0 via pyenv; the hooks only need an interpreter, not the project's
  3.12). Hooks are mode 644 — see Human actions.

**Next.** P01, continuous integration.

### 2026-10-22 · P05 · Preregistration draft

**Changed.** `docs/preregistration.md` replaces its stub: research questions Q1–Q3, hypotheses
H1–H3 with a decision rule each, the primary metric (total system cost) and nine secondary
metrics defined as formulas over a named output schema, risk appetite as a bad-debt event rate,
scenarios S1–S9 with the three environments, the parameter grid outline, the analysis plan,
exclusion rules, how pilots are handled, what counts as confirmation, and an empty Addenda table.

**Decisions taken in the draft.**
- **Three outcomes, not two.** An interval that includes zero is "no detected difference", never
  a tie and never equivalence. §6.5 also fixes the order in which ties are broken when Q1 forces
  a parameter choice anyway.
- **Rates, not totals.** Hypotheses test bps per debt-year, so scenarios of different horizons and
  sizes are comparable; raw totals are stored too.
- **Paired bootstrap.** A and B see the same seeds and therefore the same paths, so the comparison
  resamples pairs and the price path cancels.
- **Path classification before simulation.** "Short crash" and "long slide" are properties of the
  path, computed before the run, so H1 and H2 cannot be tested on a set chosen after seeing
  outcomes.
- **Two metrics beyond blueprint §14.2**: M8 (shutdown outcome, because it changes how every other
  metric reads) and M9 (how long the peg floor was closed by the new critical-TCR gate). Neither
  carries a hypothesis.
- **Exclusions may never reference an outcome value** (§8 rule 6), and runs that shut down are not
  excluded — that tail is the subject of the study.

**Open placeholders.** 14 `TBD-P30` values, each with candidates and the prompt that decides it:
the crash/slide thresholds (`D_crash`, `X`, `D_slide`, `Y`, `R_up`), the thin-liquidity factor `Z`,
the rebound window `W` for unnecessary liquidations, the bootstrap block length, `N`, the risk
appetite `R`, the fork-agreement subset and band, and the freeze date and commit. P30 fails if any
remain.

**Next.** P03 (invariants) is the next prompt by dependency; P06 starts the data work.

### 2026-10-22 · P04 · ADRs and threat model

**Changed.** `docs/adr/0001…0026` — 26 records, all `Status: proposed`, each with Context,
Decision, Alternatives considered and Consequences, and each pointing at the spec sections or
prompts that depend on it. `docs/adr/README.md` carries the full index. `docs/threat-model.md`
replaces its stub: trust assumptions (blueprint §17.1), an asset table and an actor table, a
23-row threat register, an explicit out-of-scope section and the boundaries of the testnet
deployment (§17.3).

**Numbering.** 0001–0015 are the blueprint's decision register (§6) written out. 0016–0025 are the
prompt's additions, which match the kit's corrections 1–13 one-to-one where those are protocol
decisions. 0026 is the critical-TCR redemption gate decided at the P02 gate — one more than the
prompt asked for, because it is a real decision with alternatives and a cost, and leaving it only
in spec §12 (D-27) would hide it from the ADR index. Numbering is continuous, nothing reused.

**Threat register.** The blueprint's 14 threats are all present. The prompt's ten additions are
T-03 (oracle gas griefing), T-19 (wiring front-run), T-14 (auction callback reentrancy), T-11
(sorted-list hint griefing), T-05 (dust positions), T-18 (interest accrual skipped), T-01
(redemption of underwater positions), T-04 (sequencer grace bypass), T-20 (wrong chain) and T-21
(credential leakage through tooling). Two more came out of writing it: T-22, dishonest or
irreproducible results, and T-23, model/contract divergence — the failure modes specific to a
protocol whose product is a report.

**Open TBDs** (acceptance criterion): three tests named in the register do not exist yet —
`AuctionCallbackActive` on `buy`/`check` (T-14, P33), a `redeem` from inside a buyer callback
(T-01/T-14, P16/P33), and the gas-starvation branch of the oracle adapter (T-03, P12). They are
listed under Open issues as P04-1. Every other row names an invariant (numbered at P03) or an
existing test family.

**Next.** Human review of the ADRs; then P03 (invariants), which the P02 gate already unblocked.

## Carry-forward

Items from the kit's "Corrections to the blueprint" that no specification text can satisfy: they
constrain data collection and calibration. Each is checked at its target prompt (spec §12.1).

| # | Correction | Target |
|---|---|---|
| 5 | Differential test tolerance is zero: the model and the contracts do identical integer arithmetic, so a mismatch is a bug, never a rounding difference. Moved here from spec Appendix B at the gate — it is test methodology, not protocol semantics | P22 (model), P23 (differential harness) |
| 6 | Liquidation latency is right-censored; calibrate with survival analysis (Kaplan–Meier) rather than averaging observed latencies | P08 (extraction), P27 (calibration) |
| 7 | Price source: Coinbase ETH-USD is primary; Binance ETHUSDT is USDT-quoted and must be labelled as such, never mixed in silently | P06 |
| 8 | Base has native USDC and bridged USDbC; liquidity measurement uses native USDC and the report says which | P25 |
| 9 | Chainlink proxies change aggregators in phases; history extraction must walk the phases, not a single aggregator | P07 |
| 10 | Base transaction cost = L2 execution + L1 data fee, read from the GasPriceOracle predeploy | P09 (measurement), P24 (cost model) |
| 11 | Shared test vectors in `spec/vectors/*.json` feed both Foundry and pytest | Done at P02; consumed at P10 (Foundry) and P22 (pytest) |

## Open issues

<!-- id · description · owner · blocking? -->

| id | description | owner | blocking? |
|---|---|---|---|
| P00-1 | `aderyn` exits 1 on an empty `contracts/src/`, so `just static` currently runs slither only and prints a skip line for aderyn. The guard clears itself as soon as the first contract lands at P10; nothing to change then. slither runs clean (24 contracts, 102 detectors, 0 results). | Claude | no |
| P00-2 | `slither` is invoked with `--foundry-compile-all`. Without it crytic-compile builds only `src/` and produces no build-info while `src/` is empty. It also brings `script/` into scope, which is wanted; `test/`, `lib/` and `src/mocks/` are filtered from the report by `slither.config.json`. Revisit at P10 only if compile time becomes a problem. | Claude | no |
| P00-3 | `deployments/`, `data/raw/` and `data/processed/` were not created — the `mkdir` was declined. `data/raw/` and `data/processed/` are git-ignored and the fetch scripts can create them at P06, but `deployments/` needs to exist (and hold a `.gitkeep`) before P18. | human | at P18 |
| P00-4 | `ruff` excludes `.claude/` so that `just fmt` does not rewrite the three protected hooks, which it would otherwise reformat. | Claude | no |
| P00-5 | No gas snapshot yet; `just gas` guards itself until `contracts/.gas-snapshot` exists. Baseline due at P37. | Claude | no |
| P01-1 | `.gitleaks.toml` carries two allowlist entries, both narrow and both justified in the file: Anvil's published account-0 key (matched as an exact literal, so any other secret in the justfile still trips), and the `contracts/lib/` submodule tree (180 `generic-api-key` false positives in OpenZeppelin's own JS tests; that path is protected by its commit pin, not by the scanner). Re-check both if the scan ever goes quiet unexpectedly. | Claude | no |
| P01-2 | Resolved: the project now uses `N3BCKN` everywhere — README badges, `LICENSE`, and a repo-local `git config user.name`. Four commits predating the fix (`2705e33`, `a4e5b1d`, `283516a`, `3cb1d71`) are authored `H3BCKN` and were already pushed; re-authoring them needs a force push, which the permission rules and `guard_bash.py` both forbid, so they stay as they are. The global `~/.gitconfig` still says `H3BCKN` and was deliberately not touched — it is outside this repository. | human | no |
| P01-3 | The nightly `report` job cannot find processed data on a scheduled run — artefacts do not cross workflow runs without an explicit id. It needs `workflow_dispatch` with `data_run_id`. Revisit at P29/P32 once a data workflow actually produces the `processed-data` artefact; a scheduled run may then want to locate the newest one via the API. | Claude | at P32 |
| P01-4 | `scripts/check_triage.py` gates slither only. aderyn findings are uploaded as an artefact but not yet gated; aderyn can emit JSON, so the script can be extended when `contracts/src/` has contracts. The triage table's `tool` column already distinguishes them. | Claude | at P10 |
| P01-5 | The `contracts` and `differential-quick` jobs share one Foundry build cache key, derived from `foundry.toml` + `foundry.lock` + `remappings.txt`. Since `foundry.toml` carries `solc_version`, caches are never shared across solc versions, but confirm this still holds if the profile layout changes. | Claude | no |
| P01-6 | Resolved. Run [39668831000](https://github.com/N3BCKN/bagehot/actions/runs/39668831000) had every job fail at startup — *"recent account payments have failed or your spending limit needs to be increased"* — because the repository was private and Actions billed against the account quota. The human made the repository **public**, after an audit that found no leaks in the full history, no credential file ever committed, and nothing in the tree but source, docs and config. Actions is free and unlimited for public repositories. | human | no |
| P01-7 | Found by CI, not locally: the `secret scan` job installed gitleaks into `~/.local/bin/`, which does not exist there because that job runs no `setup-uv` step. Fixed in `c47245f` — both binary installs now `mkdir -p` the directory, install to an explicit filename and append it to `$GITHUB_PATH`. A reminder that a job without `setup-uv` starts from a barer environment than the others. | Claude | no |
| P02-1 | Sorted-list order is not exactly preserved under redistribution: near-tied NICRs can swap by up to ~7·10⁻¹⁹ relative (≈ 1/min collateral in wei) through stake/reward rounding. I13 in P03 needs a derived tolerance (spec §6.3.3, App. B). | Claude | at P03 |
| P02-2 | Resolved at the gate: the human supplied the kit's "Corrections to the blueprint" (13 items, from the kit README). Spec §12.1 checks each one; items 6–10 are data/experiment work and are listed under Carry-forward above. | Claude | no |
| P04-1 | Three threat-register rows have no test yet: `AuctionCallbackActive` on `buy`/`check` (T-14 → P33), a `redeem` called from inside a buyer callback (T-01/T-14 → P16/P33, same gap as P02-4), and the oracle gas-starvation branch (T-03 → P12). Each is marked TBD in `docs/threat-model.md` with its prompt. | Claude | at P12/P16/P33 |
| P02-4 | No vector exercises `redeem`'s `AuctionCallbackActive` branch (D-27, §6.7.2): it needs a deployment-B buyer callback that calls `redeem`, which the recorder cannot drive. Add it as a Foundry test at P16/P33 and as a model test at P22. | Claude | at P16/P33 |
| P02-3 | The vector reference implementation is throwaway (scratchpad). Vectors are validated independently from P10 (Foundry) and P22 (Python model); a vector that disagrees with both implementations is a spec question for `/spec-change`. | Claude | at P10/P22 |
| P01-8 | The repository is public, so all seven commits expose the author email `ka.koszewski@gmail.com` permanently. Four of them are also authored `H3BCKN`. Neither can be changed without a force push, which the permission rules forbid. If this matters, GitHub's `noreply` address plus `git config user.email` fixes it for future commits. | human | no |

## Human actions required

<!-- things only the human can do: approvals, secrets, broadcasts -->

| # | action | why |
|---|---|---|
| 1 | `chmod +x .claude/hooks/*.py` | The three hooks are mode 644. They work as configured (invoked as `python3 <path>`), so nothing is broken, but P00 asks that they be executable. `.claude/hooks/**` is protected from edits, so this one is yours. |
| 2 | `mkdir -p deployments data/raw data/processed && touch deployments/.gitkeep` | See open issue P00-3. Both `mkdir`s were declined during the session. |
| 3 | Copy `env.example` to `.env` and fill it in | Claude never reads or creates `.env`. Needed from P06 (`BASE_ARCHIVE_RPC`) onwards; `just fork`, `just smoke` and `just deploy-sepolia-dry` already fail with a clear message without it. |
| 4 | ~~Confirm the `LICENSE` copyright holder~~ | Done: `Copyright (c) 2026 N3BCKN`. Optional follow-up, outside this repo: `git config --global user.name N3BCKN`, so other projects stop committing as `H3BCKN`. |
| 5 | Decide whether `docs/redoubt-blueprint-v0.2.pdf` should be renamed | `CLAUDE.md` refers to it as `docs/blueprint-v0.2.pdf`, and the PDF itself uses the working name "Redoubt". Left untouched: renaming a source of truth is not Claude's call. |
| 6 | ~~Create the GitHub repository and connect it~~ | Done: `git@github.com:N3BCKN/bagehot`, `main` tracking `origin/main`. |
| 7 | ~~Resolve the Actions billing block~~ | Done: repository made public, Actions now free and unlimited. See P01-6. |
| 8 | ~~Record the run URL and close P01~~ | Done: run [39670041216](https://github.com/N3BCKN/bagehot/actions/runs/39670041216) is green. |
| 10 | Merge PR [#1](https://github.com/N3BCKN/bagehot/pull/1) | Claude has not merged it — merging to `main` is yours to approve. The branch is `ci/p01-verify`. |
| 9 | ~~`gh auth login`~~ | Done: logged in as `N3BCKN`, scopes `repo`, `read:org`, `gist`, `admin:public_key`. Claude can now read run status and logs for this private repository. |
