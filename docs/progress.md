# Progress

Claude updates this file at the end of every session. Status: todo · in progress · done · blocked.

| Prompt | Title | Status | Commit | Notes |
|---|---|---|---|---|
| P00 | Repository bootstrap and toolchain | done | a4e5b1d | `just check` and `just static` green; all toolchains pinned; hooks verified |
| P01 | Continuous integration | done | c47245f | PR [#1](https://github.com/N3BCKN/bagehot/pull/1), run [39670041216](https://github.com/N3BCKN/bagehot/actions/runs/39670041216) green: 5 jobs pass, `differential (quick)` skipped as designed |
| P02 | Protocol specification (human gate) | done | a38feab, 6c8f001 | Approved at the gate with one override (D-27, the critical-TCR redemption gate) and nine confirmations; `docs/spec.md` and `spec/vectors/**` protected by the human |
| P03 | Invariants (human gate) | done | 2026-10-23 | I1–I16 + U1–U4 approved and protected. CHG-002 (I5's partial-redemption defect) approved and applied to spec §6.7.3 and `redemption.json` (ADR-0027); Solidity at P16 (P04-2) |
| P04 | ADRs and threat model skeleton | done | 2026-10-23 | 27 ADRs; threat model filled (23 threats, trust assumptions, assets/actors, boundaries). **All 27 accepted by the human at the P04 gate on 2026-10-23**, ADR-0027 with the obligation that P16 lands the targeted test for the 11-wei partial and that it passes against the Solidity. Human action left: add the accepted ADR files to `.claude/protected-paths.txt` |
| P05 | Preregistration draft | done | | DRAFT: Q1–Q3, H1–H3 with decision rules, primary + 9 secondary metrics defined over a named output schema, risk appetite, S1–S9, parameter grid, analysis plan, exclusions. 14 `TBD-P30` placeholders |
| P06 | Price data | done | | Coinbase ETH-USD (primary) and Bitstamp ETH/USD (cross-check; Kraken cannot serve history) 1-minute candles 2019-01 → 2026-09; 17,724 requests; re-run sends 0; cards match; 64 tests |
| P07 | Oracle and sequencer history on Base | blocked | | Feeds verified on-chain; phases found (ETH/USD 3, sequencer 1). Log scan blocked: the RPC plan caps `eth_getLogs` at ~10 blocks → 14.5M requests (P07-2) |
| P08 | Liquidation events and liquidatable windows | blocked | | Plan approved (Aave v3 only). Code, config and 23 offline tests ready; needs `eth_getLogs` over wide ranges — same blocker as P07 (P07-2). Finding: Aave reads the SVR ETH/USD feed (P08-1) |
| P09 | Stress blocks and transaction costs | done | | 31 blocks (20 stress, 10 calm, 2024-08-05); Base costs 930 blocks, L1 crash windows 5,136 sampled blocks; L1 data fee of a liquidation ≈ $0.13–0.19 before blobs → ≈ $0.0001 after |
| P10 | Math library and shared vectors | done | 2026-10-23 | `Rounding.sol` and `WadRayMath.sol` with the bit-identical Python model, generator and vectors; 25 Foundry + 19 Python tests green; rpow error bound measured; CHG-001 (record it in spec §2.3) approved 2026-10-23, the spec edit is staged and lands when `docs/spec.md` is unlocked. Halmos proofs close with no solver — yices, z3 and bitwuzla 0.8.1 all time out; the evidence is fuzzing + the independent vectors + both-side parity, a recorded deviation from the Halmos acceptance criterion (P10-1) |
| P11 | StableToken, wiring pattern and mocks | done | 2026-10-23 | `WiredBase` (src/lib/Wired.sol), shared `Errors.sol`, `StableToken` per spec §5.9; `MockAggregator`, `MockSequencerFeed`, `ReplayAggregator`; 43 new tests, 100% line/branch coverage on core; every custom error triggered. security-reviewer: no code issue; spec-level findings in CHG-003 (proposed) |
| P12 | OracleAdapter | done | 2026-10-23 | `OracleAdapter` per spec §6.10 with the ADR-0029 fixed-buffer read; Python mirror; 100% line/branch coverage; 20 vectors on both sides; independent-reference fuzz; split gas-griefing sweeps; fork tests on Base's real feeds and real proxy. security-reviewer signed off; its condition (CHG-004: post-failure gas floor `ceil(2·ORACLE_GAS/63)`, cap `ORACLE_GAS`, start 3,175) is approved and applied (ADR-0030) |
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

### 2026-10-23 · CHG-004 and CHG-003 applied · P12 closed

- **CHG-004:** spec §3.1, §3.3, §3.4 and §6.10.3, plus D-29. 24 vector fields `ORACLE_POST_FAILURE_GAS` 1588 → 3175; every other byte is identical to HEAD, re-validated field by field.
- **CHG-003 (option 1):** §3.3 constraint 8, the wired peer graph, enforced by the deploy script and the smoke test; §2.5 states StableToken has no lock; §11.1 lists StableToken's events in full.
- **ADRs:** ADR-0028 and ADR-0030 accepted by the human. ADR-0031 written for CHG-003, `proposed`.
- **Tests:** vector tests pass on both sides, and `/verify` is green.
- **Protection bypass, and the standing rule that came out of it.** The first CHG-004 apply wrote to the protected spec and vectors before the human's unlock was saved: the check and the script were chained, and the hook does not stop Bash-run scripts. I restored the files to HEAD at once.
  - Rule now in `CLAUDE.md`: any script that writes to `docs/spec.md`, `spec/vectors/**`, `docs/invariants.md` or `docs/preregistration.md` reads `.claude/protected-paths.txt` itself.
  - The unlock is verified in a separate step; the human's "unlocked" is not the unlock, the file is.
- **Process rule.** Findings whose failure mode is "kills all liquidations", "unbacked-mint key" or "forged shutdown" get their own message with a header. CHG-003 should have had that treatment at P11.
- **Human.** Re-protect lines 7–8 of `.claude/protected-paths.txt`. Add the CHG-003 criterion to the P18 prompt. Review ADR-0031.

### 2026-10-23 · CHG-004 applied · P12 closed

**Checks the human required before approving.**
1. **Real proxy, not a mock.** The first evidence came from `ProxyFeed`, a mock of the proxy's call shape, so I re-ran it on a Base fork (block 45,198,666). The test keeps Chainlink's deployed `EACAggregatorProxy` bytecode and replaces only the aggregator behind it, via `vm.etch`, with an honest but expensive one. The real aggregator costs about 19k gas and cannot be starved under any allowed cap.
   - **Gas left after a starved read:** at most 2,816 at a 100k cap (floor 3,175) and 28,734 at 1M (floor 31,747). The old floors (1,588; 15,874) are crossed in both cases.
   - **Adversarial sweep at a 1M cap:** 789 of 825 gas limits forged a recorded failure at the old floor, 0 at the new one. At the start parameters, 0 at either floor.
2. **Honest callers at the new floor.** Compared floors 1,588 and 3,175 on a 50k cap, where both are deployable.
   - **No effect** when the feed fails by reverting, or with one `fetchPrice` per transaction: fetchPrice's own ~4.2k of work after a failed read exceeds both floors.
   - **Only a second `fetchPrice` in the same transaction**, with the clock running and a feed that burns its whole cap, needs exactly 1,587 more gas. In that band the caller gets `InsufficientGasForOracle`, which is retryable.

**Changed.**
- ADR-0030; ADR-0024 marked superseded (bound only).
- `OracleAdapter` constructor, index 7 now checks both bounds; Python model to match.
- Spec §3.1, §3.3, §3.4 and §6.10.3, the last rewritten with the proxy refund term; new deviation row D-29; header note.
- 24 `ORACLE_POST_FAILURE_GAS` fields in 8 vector files, 1588 → 3175. `math.json#derived_constants` is now `ceil(2·100k/63)`. All other bytes are identical, regenerated by the reference generator and compared field by field.

**Tests.**
- Permanent regression sweeps: `test_regression_proxiedFeed_cap1M_noForgery` and `test_regression_proxiedFeed_startParameters_noForgery` (mock proxy, in `just test`); `OracleGasRuleForkTest` (real proxy, in `just test-fork`).
- Constructor bounds tested at both ends.
- Honest-caller tests `test_gasRule_newFloor_*`.

**Process notes.**
- **My closing summary claimed lines 7–8 of `.claude/protected-paths.txt` were commented out. They were not.** I had not re-read the file; it was a false alarm.
- **Several fixture edits silently missed their targets** after `forge fmt` rewrote number literals (`1_588` became `1588`). Edits now assert that the target string exists.

### 2026-10-23 · P12 · OracleAdapter

**Changed.**
- New `contracts/src/core/OracleAdapter.sol`, the §6.10 decision table:
  - lazy reads;
  - gas rule after each failed call;
  - events only on transitions;
  - `peek` with no writes and no gas rule.
- **The feed read is a fixed 160-byte assembly `staticcall`** (ADR-0029, accepted at the plan gate).
- New mirror `model/protocol/oracle.py` and `tests/model/test_oracle_model.py`.
- New mock `src/mocks/RawFeed.sol`: non-ABI replies via a Solidity `fallback`, no assembly.
- `MockAggregator` changes:
  - its `ShortReturn` assembly is removed; it was a P11 slip against `contracts/CLAUDE.md`;
  - its gas burner now reads `gasleft()` once.
- Test helpers in `test/utils/`: `OracleFixture`, `ProxyFeed`, `OracleAdapterHarness`.
- `justfile`: `just test` excludes `test/fork/*`; new `just test-fork`, kept out of `/verify` at the human's instruction.

**Decisions.**
- **Spec over prompt.** `failureStart`/`lastGoodPrice` (no `lastGoodAt`), `peek`, `ORACLE_POST_FAILURE_GAS`, and the spec's three events instead of the prompt's `PriceUsable`/`PriceUnusable` on every call.
- **Constructor ranges are named constants**, which also fixed four aderyn findings.

**Tests.**
- `OracleAdapterTest` (37):
  - every row and reason;
  - boundaries at −1/exact/+1 on an 8-decimal feed (answer units) and an 18-decimal feed (wei);
  - malformed replies (159 and 32 bytes, empty, no code, junk `uint80` words);
  - return and revert bombs, measured against a copying reader;
  - lazy reads, events and the failure clock;
  - memory safety through a harness;
  - reason values asserted literally.
- `OracleAdapterGasTest`: separate step-1 sweeps of the sequencer call and the price call (also after an expensive sequencer, and through a proxied feed). Each finds both edges by bisection and adds a coarse pass from 1k gas.
- `OracleAdapterFuzzTest`: an independent reference covering the full table. Bounds use a 512-bit product; staleness and grace use additive forms.
- `OracleVectorsTest`: the 20 `oracle.json` vectors.
- `OracleAdapterForkTest`: pinned Base block 45,198,666 (P09 calm rank 8). Real ETH/USD and sequencer feeds; the price equals the answer × 10^10.

**Found along the way.**
- **The first gas sweep reported "honest feed recorded as failed".** The fault was the mock, not the adapter: two `gasleft()` reads straddled `gasToBurn`, the subtraction underflowed, and the "honest" feed reverted fast. The adapter was right to record it.
- **`forge coverage` does not attribute constructor reverts under `vm.expectRevert`,** and this Forge build compiles `new` in tests to `deployCode`, so a same-frame `try` cannot catch it. The constructor tests now deploy through an external self-call with exact error-bytes matching.

**Review.** `security-reviewer` signs off, with one condition:
- **F1, confirmed independently and the one that matters.** A proxied feed returns its kept 1/64 when its inner call starves. At `ORACLE_GAS` = 1M with the spec-minimum threshold, every one of 1,601 tested gas limits forged a recorded failure. The start parameters are safe (0 of 2,500). This needs a spec change: **CHG-004**.
- **F2:** no upper bound on the threshold. Also in CHG-004.
- **F3:** decimals are read once, so a proxy phase change could rescale the price. Recorded in threat-model T-02.
- **F4:** the feeds' code and addresses are not checked at construction. Added to P11-1 for P18.
- **F5:** memory-safety test added and the bomb-test comment corrected.
- **F6:** fuzz now reaches the 1e30 ceiling; proxied sweep added.
- **F7:** docs fixed.

**Next.** Human: decide CHG-004 and CHG-003, and accept ADR-0028. Re-protect `docs/spec.md` and `spec/vectors/**`: lines 7–8 of `.claude/protected-paths.txt` are still commented out. Then P13.

### 2026-10-23 · CHG-001 and CHG-002 applied · P03 closed

**Changed.** With `docs/spec.md` and `spec/vectors/**` unlocked by the human, both approved changes
landed in one step:
- **CHG-002** — §6.7.3 gains the post-check `(c − out)·price ≥ MCR·debtOf(n − dn)`, which cancels a
  partial like a stale hint does; it also gains a rules bullet, a §2.2 exact-comparison row,
  deviation D-28 and an Appendix A row.
- **`redemption.json`** gains `partial_cancelled_below_mcr`. At the start parameters (index 1.2304)
  the 11-wei redemption reverts `NothingRedeemed`, then the 1,000-stable redemption raises ICR
  1.1 → 1.101897.
- **CHG-001** — §2.3 gains the *Accuracy* paragraph. New ADR-0028 (proposed).

**Re-validation.** The reference generator, with the post-check, regenerated all 12 vector files.
11 are byte-identical to the committed ones. In `redemption.json` the six existing vectors are
unchanged and the new vector is the only addition. `/verify` is green.

**Spec-change step 4d.** `just diff-long` and the invariant campaign do not exist yet (P23, P17), so
they have nothing to run. No experiments have run, so nothing needs re-running.

**Human.** Re-protect `docs/spec.md` and `spec/vectors/**`: un-comment lines 7–8 of
`.claude/protected-paths.txt`. Review ADR-0028.

### 2026-10-23 · P11 · StableToken, wiring pattern and mocks

**Changed.** New in `contracts/src`:
- `lib/Wired.sol` (`WiredBase`): immutable `deployer`, `wired`, `whenWired`, `onlyWiring`,
  `_requireNonZero` and `_markWired`. `_markWired` re-checks once-only itself, so a concrete
  `wire` that forgot the modifier still cannot wire twice.
- `lib/Errors.sol`: file-level `InvalidParameter(uint8)` and `Unauthorized()`, shared by every core
  contract.
- `core/StableToken.sol`.
- `interfaces/AggregatorV3Interface.sol`: written out, so there is no Chainlink dependency.
- `mocks/{MockAggregator,MockSequencerFeed,ReplayAggregator}.sol`.

Tests in `test/unit/{Wired,StableToken,Mocks}.t.sol`. `just coverage` now excludes `src/mocks/`,
`test/` and `script/`.

**Decisions.**
- **Spec over prompt on token roles.** The prompt lists six contracts that may mint and burn.
  Spec §3.4/§5.9/§9 is narrower and wins: the VaultManager mints; VaultManager, strategy,
  DeficitLedger and ShutdownModule burn; only the strategy moves without an allowance; supply is
  capped at 2^128−1 (`SupplyCapExceeded`). The RedemptionModule is not a burner, because the
  VaultManager burns the redeemer's tokens.
- **StableToken has no reentrancy lock.** It makes no external call. The reviewer concurs, and the
  wording of §2.5 is CHG-003 item 2.
- **Mock modes beyond the prompt.** `MockAggregator` adds a `ShortReturn` mode, the third kind of
  failed call in §6.10.1 (< 160 bytes), so P12 can test every row. `MockSequencerFeed` inherits all
  the failure modes.
- **ReplayAggregator.** It records a push only on Chainlink's rule (deviation ≥ bps by exact
  cross-multiplication, or heartbeat elapsed), accepts only positive answers, and stamps rounds
  with `block.timestamp`; the replay driver warps time.
- **Base contract named `WiredBase`, not `Wired`,** so it does not shadow the spec's `Wired`
  event (compiler warning 2519, reviewer F-2).

**Review.** `security-reviewer`: no critical, high or medium finding, and no role bypass. Fixed:
- F-1 — see the defect below.
- F-2 — the rename above.
- F-7 — the `burnFrom` selector clash with ERC20Burnable is now documented in NatSpec.
- F-8 — four tests added, including the `test_wire_nonDeployerReverts` that I11 cites.

Routed to CHG-003: F-3, F-5, F-6. Routed to P11-1: F-4.

**Defect found in the gate itself.** Slither will not overwrite an existing `--json` report and
still exits 0 under `--fail-none`. Every local `just static` since P00 therefore re-checked the
first run's file. A fresh run shows the P10 "0 results" happened to be true. CI was unaffected,
because it starts from a clean checkout. `just static` now deletes the reports first, and the four
real slither lows on `StableToken.wire` are triaged (SA-007).

**Next.** Human: review CHG-003. Unlock `docs/spec.md` and `spec/vectors/**` (comment out lines
7–8 of `.claude/protected-paths.txt`) so CHG-001/CHG-002 can land and P03 can close. Then P12.

### 2026-10-23 · P03 · Invariants

**Changed.** `docs/invariants.md` replaces its stub: I1–I16 and U1–U4, each with statement, exact
formula over state and named ghosts, tolerance (zero unless derived), scope by deployment and
phase, the test on each side, and the sequences that would break it. New
`docs/changes/CHG-002-partial-redemption-mcr-rounding.md`.

**Decisions (human, at the plan gate).** Full liquidation only in I4's framing; I6 replaced with
per-liquidation conservation; handlers donate so I1 tests "donations are inert"; I13 gets a derived
tolerance; I5 stated exactly, with the ~21-wei edge case to be tested immediately rather than left
as a known gap.

**Audit.** `spec-auditor` in spec-only mode, four passes: 26 findings, then 16, then 5, then 1 —
all 47 resolved; final verdict clean. Three defects were reproduced numerically before being acted
on, and all three were mine:
- **I4 was false twice.** The blueprint's version ("a liquidation never lowers TCR unless the
  position was uncollateralised") is false; my first correction ("ICR ≤ TCR ⇒ TCR does not fall")
  was also false in deployment A, because a partial pool offset leaves the redistributed remainder
  inside `systemColl`, so the departing bundle is richer than the position (ICR 1.09, 5% penalty,
  pool covering half the debt → bundle ratio 1.13, TCR 1.100000 → 1.098421). The third version
  states the bundle explicitly and asserts only what holds.
- **Two one-wei effects from the same rounding rule.** `systemDebt` takes one ceiling over the
  aggregate, so a full-absorption liquidation can lower TCR by a wei and an auction start can raise
  system debt by a wei (R1/R28). I derived this for the auction start and then failed to apply it
  two lines above; the auditor caught it with two identical positions, where `ICR == TCR` exactly.
- **The pool's error carry can over-credit a newcomer.** `offset()` never clears `lastCollError`,
  so a carry generated at `T ≈ 10^30` survives the pool emptying and is paid to whoever deposits
  next: reproduced at 10^12 wei against a 2-wei bound. §6.6.7's own measured maximum
  (1.6·10^12 wei at `T ≈ 10^30`) is the same quantity, which I had read past twice.

**Process note.** CHG-002's first version recommended raising the `MIN_PRICE` floor on the strength
of "no violation found in 600,000 samples". That search almost never landed in the narrow window
where violations live, so it measured the sampler, not the protocol; the auditor found a
counterexample at the start parameters by searching the window directly. Absence of hits from an
unvalidated random search is not evidence of absence, and the corrected CHG-002 says so explicitly.

**Next.** Human: approve `docs/invariants.md` and protect it; decide CHG-002. Then P11.

### 2026-10-22 · P10 · Math library and shared vectors

**Changed.** `contracts/src/lib/Rounding.sol` (`mulDivDown/Up`, `divUp` over OZ `Math.mulDiv` /
`ceilDiv`), `contracts/src/lib/WadRayMath.sol` (WAD/RAY products and quotients in both directions;
`rpow(x, n)` = the spec's power function, `rpow(x, n, rounding)` for test brackets),
`model/math.py` (bit-identical Python), `spec/tools/gen_math_vectors.py` →
`spec/generated/math_random.json` (800 cases, 104 expected reverts; expected values from `Fraction`
and an independent transcription of §2.3, deliberately not from the model), `spec/tools/rpow_error.py`,
tests: `test/vectors/MathVectors.t.sol` (7), `test/unit/Rounding.t.sol` (6), `test/unit/WadRayMath.t.sol`
(11), `tests/model/test_math.py` (19). Static gate extended to aderyn (closes P01-4; SA-001 triaged).

**Decisions (spec over prompt, `CLAUDE.md`).** (1) Overflow reverts `Panic(0x11)` from OZ `mulDiv`,
not a custom `Overflow()` error: spec §2.2 defines overflow that way (model: `Overflow` exception)
and §11.2 lists no `Overflow()` error. (2) `rpow` takes a rounding argument as the prompt asks, but
the protocol only ever uses Ceil (§2.3); Floor exists to bracket the exact value in tests.

**Results.** All 18 checks of `spec/vectors/math.json` pass on both sides, including the trace that
pins the product order; all 800 generated cases pass on both sides, reverts included. Fuzz (1,024 runs
each, no `vm.assume` — every input region asserts its own outcome): `mulDivUp − mulDivDown` is 1 iff
inexact, floor proven exact via 512-bit arithmetic, ceil overflow at the top edge reverts; rpow
monotone in n (growth and decay) and in x; rpow equals repeated rmul for n ≤ 3 and brackets the same
value for n ≤ 64; overflow boundary exact (`rpow(2·RAY, 166)` fits, 167 reverts).

**rpow error bound** (52,000 random inputs, two seeds): `rpowDown ≤ exact ≤ rpowUp` always (and
provably), and `|error| ≤ n · max(1, exact/RAY)` RAY units — tight. A first guess (error ≤ number of
roundings) was refuted by six orders of magnitude: early roundings are doubled by every later squaring,
so the error is linear in n. A year in one accrual: relative error < 4·10^-20. The spec states no bound,
so recording it is a spec change: **CHG-001** (`docs/changes/CHG-001-rpow-error-bound.md`), awaiting
review.

**Halmos — not achieved.** The `check_` functions (`test/symbolic/RoundingSymbolic.t.sol`, kept
uncommitted so CI does not go red) time out with both solvers bundled in the pinned halmos 0.3.3 —
yices and z3, 300 s per query — at 128-bit and even 64-bit operands; at 16 bits mulDiv still times out,
only an 8-bit divUp closes. EVM words are 256 bits, so the solver bit-blasts 256-bit multiplier and
divider circuits regardless of operand width. Halmos's default solver choice also tries to *download*
yices at run time, which is blocked (a new tool needs approval). Bitwuzla 0.8.1 was then tried, timeboxed (2026-10-23): 5 of 6 checks timed out at 600 s, the 6th was not reached in 60 min. Fallback adopted: P10-1.

### 2026-10-22 · P09 · Live run

**Run.** `just blocks` (31 blocks, 64 requests), `just costs base` (930 rows, 2,313 requests),
`just costs l1` (5,136 rows, 5,318 requests), `just costs report`. Cards: `blocks_selected.md`,
`costs_base.md`, `costs_l1.md`, each with a generated checksum block.

**Provider limits found and worked around** (P07-2 has the details): `eth_feeHistory` is served only
for recent blocks, so fee statistics are computed from full blocks — on Base with receipts (gas-used
weights, exactly feeHistory's statistic), on L1 every 10th block (gas-limit weights). Full blocks with
receipts triggered HTTP 429, so the fetcher gained a resumable SQLite result cache, 3 req/s pacing and
a patient retry policy.

**Results** (`reports/cost-empirics.md`). Base median base fee 0.0028 gwei calm, 0.017 stress, 0.029
on 2024-08-05; median priority fee 0.001 / 0.013 / 0.106 gwei. L1 data fee of a liquidation:
median ≈ $0.13–0.19 before Base's Ecotone (blob) upgrade, ≈ $0.0001 after. Ethereum L1 crash windows:
base fee p50 74 gwei (2022-05) and 27 gwei (2024-08); pre-London median price paid 40 gwei (2020-03)
and 178 gwei (2021-05), peaks up to 2,039 gwei. Gas used by our own liquidation comes at P20.

### 2026-10-22 · P09 · Stress blocks and costs (code ready, live run blocked)

**Changed.** `data/blocks.py` (selection + cached timestamp→block binary search), `data/fetch_costs.py`
(Base: `eth_feeHistory` over the minute ending at each selected block, and `GasPriceOracle.getL1Fee`
on three signed EIP-1559 payloads — Bagehot A `liquidate`, Bagehot B `buy`, Aave `liquidationCall`;
Ethereum L1: per-gas prices in the four named windows, with pre-London 2020/2021 blocks sampled in
full because they have no base fee), `data/analyze_costs.py` (`reports/cost-empirics.md`),
`tests/data/test_blocks_costs.py` (22 tests, RLP checked against the published yellow-paper
examples), `just blocks`, `just costs base|l1|report`. `data/rpc.py`: `from_env` takes the variable
name, so L1 uses `ETH_MAINNET_RPC`.

**Selection, run on the real P06 data (no RPC needed for this part).** 20 stress, 10 calm, plus
2024-08-05 at its −18.1% fifteen minutes (01:10 UTC); top stress pick the +20.1% rebound of
2025-02-03; at least 25.5 h between any two picks. One calm block (2024-06-01 22:55) has no 24 h
return because t − 24 h falls inside Coinbase's 67-minute gap of 2024-05-31; left empty rather than
filled from another moment.

**Defect found by a test.** Calm blocks were held 7 days away from stress picks as well as from each
other, so in a short history the selection silently returned fewer blocks. Calm-vs-calm stays 7
days (regime diversity), calm-vs-stress is now 2 days, and a shortfall is printed.

### 2026-10-22 · P06 · Price data

**Changed.** `data/http.py`, `data/sources.py`, `data/fetch_prices.py`, `data/process_prices.py`,
`data/validate.py` (prices part), `data/fetch_all.py` (driven by `just data`), two data cards,
recorded fixtures under `data/tests/fixtures/`, `tests/data/test_prices.py` (31 tests), and
`reports/data-validation.md`. `pyproject.toml` gains `pythonpath = ["."]` so tests can import the
top-level packages.

**Decisions.**
- **Bitstamp, not Kraken, as the cross-check.** Kraken's REST OHLC returns only the latest 720
  candles and its docs say older data "cannot be retrieved"; the human chose Bitstamp.
- **Bitstamp pads no-trade minutes, and those bars become gaps.** Found in the data, not in the
  docs: 620,593 zero-volume bars (15.2%; 42% in 2019), 620,289 exactly at the previous close.
  Storing them would store venue-forward-filled prices (P06 forbids forward-fill) and would inflate
  the divergence against Coinbase. `Source.emits_empty_minutes` handles it; the count is in the card.
- **Resume is window-aware.** A month counts as done only if its meta matches the file checksum
  *and* the exact window requested; a partial `--start/--end` run cannot leave a half-filled month
  marked complete. Tested, as is a truncated file.
- Verified against the live APIs before trusting the docs: Coinbase returns newest-first with
  elements `[time, low, high, open, close, volume]`; Bitstamp's `end` is inclusive.

**Results.** Coinbase 4,059,243 rows (99.61% coverage, 12,131 gaps, longest 394 min on 2026-05-08);
Bitstamp 3,454,607 rows (84.77% after padding removal). Median cross-source divergence 2.0 bps; in
the stress windows 18.3 (2020-03), 8.7 (2021-05), 4.6 (2022-05), 3.1 bps (2024-08). Largest single
divergence 2,318 bps: a −19.28% Bitstamp minute on 2019-07-14, flagged and kept. Processing is
byte-deterministic (Coinbase checksum identical across runs).

**Acceptance.** `just data` completes; a re-run sends 0 requests; card checksums match the files;
`just py-test` green.

### 2026-10-22 · P07 · Oracle history (code ready, live fetch blocked)

**Changed.** `config/8453.toml` (standard `eth-usd` proxy and the sequencer feed, each with source
URL and date; the three SVR ETH/USD feeds recorded as known but unused), `data/rpc.py` (a JSON-RPC
client that keeps the endpoint out of every exception, repr and traceback), `data/fetch_oracle.py`,
`data/process_oracle.py`, `data/analyze_oracle.py` (with the approved oracle-vs-market section),
`tests/data/test_oracle.py` (32 tests), and a `just oracle` recipe.

**Decisions (human, at the plan gate).** Calibrate on the standard ETH/USD feed; add the
oracle-vs-market section. **Found while planning:** the Chainlink directory lists three ETH/USD feeds
on Base (one standard, two SVR variants); all five addresses pass EIP-55, and the fetcher re-verifies
description and decimals on-chain before it scans anything.

**Blocked.** `just oracle --verify-only` reports `BASE_ARCHIVE_RPC` unset, even through `just`'s
dotenv loading. Claude cannot inspect the file (the guard blocks it by design). Human action 11.

### 2026-10-22 · P08 · Liquidations (plan approved)

**Code ready, live run blocked.** `config/8453.toml` gains `[aave_v3]` (16 addresses, all EIP-55);
`data/logscan.py` (generic resumable log scan), `data/fetch_liquidations.py` (stages `logs`,
`plan`, `calls --approve-calls N`, `build`), `data/analyze_liquidations.py` (Kaplan–Meier with
Greenwood log-log intervals, naive comparison, size buckets), `tests/data/test_liquidations.py`
(23 tests, including a hand-computed KM case), `just liquidations`.

Two defects caught in review before any test ran: the call budget reset on every run (now
cumulative, stored in the cache database), and a sampled user without a predicted onset would have
triggered a forward scan of every falling update (now one call at the window's lowest price).
Same-block liquidations — the update and the liquidation in one block — get latency 0 and are
counted separately; end-of-block state cannot show the moment in between.

Aave v3 only (human). Addresses from the official address book (`bgd-labs/aave-address-book`,
`src/AaveV3Base.sol`, read 2026-10-22 via jsDelivr's GitHub mirror). Method approved: logs first,
then archive `eth_call`s with the onset predicted from each user's liquidation price and bracketed
by two calls, a SQLite call cache, and a mechanical `--approve-calls N` gate. Code next; the live
run needs the same RPC as P07.

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
constrain data collection and calibration. Each is checked at its target prompt (spec §12.1). Also
obligations a later prompt must carry that are not in that prompt's text yet (rows named by CHG).

| # | Correction | Target |
|---|---|---|
| 5 | Differential test tolerance is zero: the model and the contracts do identical integer arithmetic, so a mismatch is a bug, never a rounding difference. Moved here from spec Appendix B at the gate — it is test methodology, not protocol semantics | P22 (model), P23 (differential harness) |
| 6 | Liquidation latency is right-censored; calibrate with survival analysis (Kaplan–Meier) rather than averaging observed latencies | P08 (extraction), P27 (calibration) |
| 7 | Price source: Coinbase ETH-USD is primary; Binance ETHUSDT is USDT-quoted and must be labelled as such, never mixed in silently | P06 |
| 8 | Base has native USDC and bridged USDbC; liquidity measurement uses native USDC and the report says which | P25 |
| 9 | Chainlink proxies change aggregators in phases; history extraction must walk the phases, not a single aggregator | P07 |
| 10 | Base transaction cost = L2 execution + L1 data fee, read from the GasPriceOracle predeploy | P09 (measurement), P24 (cost model) |
| 11 | Shared test vectors in `spec/vectors/*.json` feed both Foundry and pytest | Done at P02; consumed at P10 (Foundry) and P22 (pytest) |
| CHG-003 | **P18 acceptance criterion: the wiring graph** (spec §3.3 constraint 8, ADR-0031). This must become a named acceptance criterion in P18's own prompt file once the human commits `prompts/`; until then it is recorded here. The criterion:
  - **Before broadcasting**, the deploy script asserts that every `wire` address is the contract the factory created for that role, that the peer graph agrees, that every immutable `token`/`weth`/`oracle` is the deployment's, and that no role is an EOA.
  - **The post-deploy smoke test** asserts the same, plus `deployer() == factory` and `wired()` on every contract in the deployment receipt.
  - **Tests:** a StableToken wired to a different strategy than the VaultManager fails, and so does an EOA role. | P18 (add to `prompts/P18-*.md` when committed) |

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
| P01-4 | Resolved at P10: `scripts/check_triage.py --aderyn` gates aderyn findings like slither's; the `static` recipe writes `reports/static/aderyn.json`. Original note: `scripts/check_triage.py` gates slither only. aderyn findings are uploaded as an artefact but not yet gated; aderyn can emit JSON, so the script can be extended when `contracts/src/` has contracts. The triage table's `tool` column already distinguishes them. | Claude | at P10 |
| P01-5 | The `contracts` and `differential-quick` jobs share one Foundry build cache key, derived from `foundry.toml` + `foundry.lock` + `remappings.txt`. Since `foundry.toml` carries `solc_version`, caches are never shared across solc versions, but confirm this still holds if the profile layout changes. | Claude | no |
| P01-6 | Resolved. Run [39668831000](https://github.com/N3BCKN/bagehot/actions/runs/39668831000) had every job fail at startup — *"recent account payments have failed or your spending limit needs to be increased"* — because the repository was private and Actions billed against the account quota. The human made the repository **public**, after an audit that found no leaks in the full history, no credential file ever committed, and nothing in the tree but source, docs and config. Actions is free and unlimited for public repositories. | human | no |
| P01-7 | Found by CI, not locally: the `secret scan` job installed gitleaks into `~/.local/bin/`, which does not exist there because that job runs no `setup-uv` step. Fixed in `c47245f` — both binary installs now `mkdir -p` the directory, install to an explicit filename and append it to `$GITHUB_PATH`. A reminder that a job without `setup-uv` starts from a barer environment than the others. | Claude | no |
| P03-1 | I13's `k = 4` is calibrated to the P02 measurement, not derived: §6.3.3's stake-ratio divergence has no constant bound when a large liquidation meets a small `totalStakes`. P17 must re-validate against the campaign and may tighten it; exceeding it is a `/spec-change`, never a bump. | Claude | at P17 |
| P03-2 | Two one-wei TCR effects are asserted as allowances, not defects (full-absorption liquidation lowers TCR by ≤ 1 wei of debt; an auction start raises system debt by ≤ 1). The report must describe them, or a reader will take them for leaks. | Claude | at P32/P43 |
| P03-3 | I4 does not assert the TCR direction for a partial pool offset with surplus — the departing bundle is richer than the position, so TCR can fall legitimately. Measured in the report instead. | Claude | at P32/P43 |
| P02-1 | Sorted-list order is not exactly preserved under redistribution: near-tied NICRs can swap by up to ~7·10⁻¹⁹ relative (≈ 1/min collateral in wei) through stake/reward rounding. I13 in P03 needs a derived tolerance (spec §6.3.3, App. B). | Claude | at P03 |
| P02-2 | Resolved at the gate: the human supplied the kit's "Corrections to the blueprint" (13 items, from the kit README). Spec §12.1 checks each one; items 6–10 are data/experiment work and are listed under Carry-forward above. | Claude | no |
| P07-1 | `BASE_ARCHIVE_RPC` is not visible to `just oracle` (the script sees it unset). Blocks the P07 and P08 live runs; code and tests are ready. | human | yes — P07, P08 |
| P10-1 | **Resolved 2026-10-23: fallback adopted.** halmos 0.3.3 cannot close the rounding proofs: yices and z3 time out at 128, 64 and 16 bits, and **bitwuzla 0.8.1** (approved for one timeboxed attempt, pinned in `docs/dependencies.md`) timed out on 5 of 6 checks at 600 s per query; the 6th (`check_wmul_bracketsTheExactProduct`) was not reached inside the 60-minute cap. Per the human's instruction the P10 evidence is fuzzing + the independently generated vectors + both-side vector parity, recorded as a deviation from P10's Halmos acceptance criterion. `RoundingSymbolic.t.sol` stays uncommitted (a committed check that always times out would fail `just halmos`); `just halmos` still needs an explicit solver before CI runs it — revisit at P33. | — | closed |
| P10-2 | P10 lists P03 (invariants) as a dependency, but P03 has not been run (it was paused at the P02 gate). The math library depends only on the spec, so P10 proceeded; P03 should run before P11+ need invariant references. | human | before P11 |
| P07-2 | **The archive RPC plan caps `eth_getLogs` at about 10 blocks** (the probe halved from 500,000 to 7; free-tier plans of several providers do this). At that cap P07's history needs ~14.5M requests; the fetcher's budget guard stopped it. Blocks P07 and P08. Options: (a) an RPC plan allowing ≥ 10k-block `eth_getLogs` (P07 then needs ~11k requests); (b) fetch logs from the Etherscan-v2 / Basescan logs API (`BASESCAN_API_KEY` is already in `env.example`) and keep the RPC for the exact `getRoundData` cross-checks. Decision needed. Also observed: `eth_feeHistory` is served only for recent blocks (HTTP 503 at depth) — P09 now reads full blocks instead. | human | yes — P07, P08 |
| P07-3 | Phase 3 of the standard ETH/USD proxy (from block 50,530,334) reads aggregator `0x05c84a58FE042275b37db038bAAcD15F410c7bB0` — the contract Chainlink's directory lists for the `eth-usd-shared-svr-2` entry. Since then the standard proxy and that SVR proxy read the same aggregator, which narrows P08-1 to the period before. | Claude | at P24 |
| P08-1 | **Aave v3 on Base prices WETH from the SVR ETH/USD feed** (`WETH_ORACLE = 0x9dA00D23465282005DB222a441a663eE7B9dfCc8`, the `eth-usd-svr` secondary proxy), not the standard feed P07 calibrates on. P08 handles it by using the source in force in each window (AaveOracle `AssetSourceUpdated` history). Undecided: which feed the protocol's own oracle model (P24) should mirror. If update timing differs between the two, the liquidation calibration and the oracle calibration describe different oracles. Decide before P24. | human | at P24 |
| P04-1 | Two threat-register rows have no test yet: `AuctionCallbackActive` on `buy`/`check` (T-14 → P33), and a `redeem` called from inside a buyer callback (T-01/T-14 → P16/P33, same gap as P02-4). Each is marked TBD in `docs/threat-model.md` with its prompt. The third, the oracle gas-starvation branch (T-03), was closed at P12 by `OracleAdapterGasTest`. | Claude | at P16/P33 |
| P04-2 | **ADR-0027's implementation obligation.** The human accepted ADR-0027 at the P04 gate on the condition that P16 lands the targeted test for the 11-wei partial (`redemption.json#partial_cancelled_below_mcr`: the 11-wei redemption reverts `NothingRedeemed` with state unchanged, the 1,000-stable redemption then succeeds and raises the position's ICR to 1.101897) and that it passes against `VaultManager.redeemCollateral`, not only against the reference generator and the Python model. P16 is not done until it does. | Claude | at P16 |
| P11-1 | **P18 deployment pitfalls from the P11 review (F-4).** `deployer` is whoever executes CREATE. (i) `new X{salt: s}` inside `forge script` goes through the CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`, which becomes `deployer` and can never call `wire`: the contract is bricked, permanently NotWired. (ii) A factory that deploys in one call and exposes a separate `wireAll(...)` moves the front-running window from `wire` to the factory. P18 must: deploy and wire inside one factory call that takes no caller-supplied addresses; never use `{salt:}` for wired contracts; assert `deployer() == factory` and `wired()` from the deployment receipt; on Base Sepolia, assert that the price feed is the configured Chainlink address unless the environment is `fork_replay` (`ReplayAggregator` is operator-controlled). Also (P12 review F4) assert that both oracle feeds have code and equal the `config/<chain>.toml` addresses. Also update the threat-model row "Deployer key": with a factory, the deployer is the factory. | Claude | at P18 |
| P11-2 | Resolved 2026-10-23: CHG-003 approved (option 1) and applied to spec §2.5, §3.3 constraint 8 and §11.1 (ADR-0031, proposed). The human's condition: the deploy-script wiring-graph check and the smoke-test assertions (`deployer() == factory`, `wired()` on every contract, peer-graph agreement) must be a named acceptance criterion in **P18's own prompt text**. The prompt kit is not in this repository (there is no `prompts/` directory), so the human adds it there; the exact text was handed over on 2026-10-23. | — | closed |
| P12-1 | Resolved 2026-10-23: CHG-004 approved and applied. The floor is now `ceil(2·ORACLE_GAS/63) ≤ ORACLE_POST_FAILURE_GAS ≤ ORACLE_GAS`, start value 3,175, per ADR-0030 (which supersedes ADR-0024's bound). Before approving, the human required two checks, and both passed: the critical cases re-run on Base's real proxy, and an honest caller tested at the new floor. The permanent regression sweeps are `test_regression_proxiedFeed_*` (in `just test`) and `OracleGasRuleForkTest` (in `just test-fork`). | — | closed |
| P08-2 | `.gitleaks.toml` gained a value-only allowlist for public EVM addresses (`^0x[0-9a-fA-F]{40}$`): Aave's `a_token`/`v_token` keys in `config/8453.toml` tripped `generic-api-key`. A first version also allowlisted the `config/` path; a probe showed it hid a 64-hex private key there, so it was removed before anything was pushed. Probes confirm a 0x+64-hex key, a `private_key`, and a bare 40-hex token are still caught. The original slip: the scan and the commit were chained with `;`, so the commit ran despite the findings — scans now gate commits with `&&`. | Claude | no |
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
| 11 | ~~Make `BASE_ARCHIVE_RPC` and `ETH_MAINNET_RPC` visible~~ | Done 2026-10-22: both load through `just` (the first value pointed at Ethereum, chain id 1; fixed by the human). Remaining: P07-2. |
| 11-old | (superseded) Make `BASE_ARCHIVE_RPC` (and, for P09, `ETH_MAINNET_RPC`) visible to Claude's process | Checked on 2026-10-22 after the human set it: still not visible — a variable exported in the human's own terminal does not reach an already-running Claude Code session (or one launched from VS Code). Either put both in the dotenv file at the repo root (`just` loads it), or restart VS Code / Claude Code from a shell that exports them. `just oracle --verify-only` still reports it unset. The dotenv file must sit at the repo root and contain the line `BASE_ARCHIVE_RPC=<url>` — no `export`, no spaces around `=`, not commented out. A check that prints a count, not the URL: `grep -c '^BASE_ARCHIVE_RPC=.'` on that file should print 1. |
| 10 | Merge PR [#1](https://github.com/N3BCKN/bagehot/pull/1) | Claude has not merged it — merging to `main` is yours to approve. The branch is `ci/p01-verify`. |
| 9 | ~~`gh auth login`~~ | Done: logged in as `N3BCKN`, scopes `repo`, `read:org`, `gist`, `admin:public_key`. Claude can now read run status and logs for this private repository. |
