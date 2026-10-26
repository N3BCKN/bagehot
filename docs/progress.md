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
| P13 | SortedPositions and hint helpers | done | 2026-10-23 | `SortedPositions` per spec §6.3; `HintHelpers` (view-only); Python mirror `model/protocol/sorted_list.py`; 100% line/branch coverage; insert gas with exact hints 135,254 at list sizes 10/100/1,000 (O(1)); I13 campaign green (30 seeds) after CHG-005 / ADR-0032 corrected I13's tie clause |
| P14 | VaultManager I: positions, borrowing, minimum debt, gas reserve | done | 2026-10-23 | Positions, shutdown hooks, views and stakes/pending per spec §5.1 and §6.5.3–4; interest is a hook until P15; Python mirror `model/protocol/vault.py`; 100% coverage; vector position prefixes (23 vectors, 61 steps) on both sides; parity checklist in the P14 log |
| P15 | VaultManager II: interest accrual and routing | done | 2026-10-23 | Accrual per spec §6.2 (R4, R6, R7), routed to the pool or reserve with `onInterest`; public `accrue()`; accruing `currentIndex()`; max dt documented and tested at the boundary; I2 invariant green with interest; interest vectors on both sides |
| P16 | RedemptionModule | done | 2026-10-24 | `RedemptionModule` (fee, gate, guard, lock), `VaultManager.redeemCollateral` (push model, CHG-002 post-check), `HintHelpers.getRedemptionHints`; Python mirror; all 7 `redemption.json` vectors end to end on both sides; P04-2 closed; I5/I15/I2 campaign green; rounding mutations 8/8; security-reviewer: no critical/high. CHG-007 raised (P16-1) |
| P17 | Invariant harness and Medusa | done | 2026-10-25 | `CoreHandler` over the whole system in A and B; I1, I2, I5, I8, I9, I11, I12, I13 and no unexpected revert; Medusa 30 min green; nightly green; I9∩I12 test; crytic-compile pinned with a CI check. CHG-008 applied to I13 (ADR-0034, proposed). security-reviewer: 5 surviving mutants found and now caught. **Open for the human: P17-1 (stake collapse, before P20) and P17-2 (I13 derivation)** |
| P18 | Local deployment, factory and manifest | done | 2026-10-25 | `BagehotFactory` deploys and wires a whole variant in one transaction (local-only stand-ins for the modules P19–P33 build); `config/31337.toml` + `script/Config.s.sol`; `Deploy.s.sol` (chain guard, §3.3 + CREATE-provenance assertions before broadcast, variant-keyed manifest written only on broadcast); `SmokeTest.s.sol`. **Fresh anvil → `just deploy-local` → `just smoke http://127.0.0.1:8545` passes**; deploy on 1 / 8453 reverts (tested). security-reviewer: nothing critical; M/L findings fixed. Open: P18-1 (initcode, ADR before P19), P18-2, P18-3 |
| P19 | StabilityPool (product-sum) | done | 2026-10-26 | `StabilityPool` (§6.6, §5.3; `onLiquidation`, dust sweep, `onInterest` returning `booked`) with its integer model; all 3 `product_sum.json` vectors bit-for-bit on both sides; 39 unit tests; CHG-006 / ADR-0033 applied (guarded, gas-capped pool hook, `POOL_HOOK_GAS = 200_000` from a measured 86,981 worst case; failing-pool matrix 8 modes × 6 operations; caller-gas sweeps with zero redirections); pool invariant campaign (I1, I3, U4) and the real pool in the core handler (Medusa `property_I3_poolSolvency`); precision study `model/tools/sp_precision.py` (200 × 300, replayed bit-for-bit by Foundry; docs/fuzzing.md); real pool deployed in A from its blueprint (ADR-0035 implemented, factory tx ≈ 10.2M gas), smoke tests A and B pass on a fresh anvil; CHG-009 applied to invariants. security-reviewer and spec-auditor: no high/critical. **Open: CHG-010 (I3 interest bound, human decision), P19-L1 (`MIN_POOL_HOOK_GAS` range), CHG-011 candidate (I2 counter rule).** |
| P20 | Liquidation via pool and redistribution | in progress | | `liquidate` (§6.4.1) with redistribution (§6.5.2), snapshots and reset (§6.5.4), the no-stakes deficit, CHG-012's defensive checks; Python mirror; all 9 liquidation/redistribution vectors bit-for-bit on both sides; unit tests incl. T-10 self-liquidation fuzz, T-26 measurement, CHG-006 liquidation sub-case, P17-H1 equivalence (1,024 runs). Core campaign now liquidates for real (A and B; B through the §6.8.2 house stand-in, P20-B): I4 (A1–A3, B1–B2), I6, I7 checked in every liquidation, I2 counted per CHG-011, I1 ledger/house rows; P17's `redistribute` is replay-only. CHG-010 applied to the model's I3 check; CHG-013's `MIN_POOL_HOOK_GAS = 175_000`. Spec/invariant texts of CHG-010/011/013 await the protected-paths unlock. |
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

### 2026-10-26 · P19 · StabilityPool, the non-fatal pool hook, blueprints

**Changed.**
- `StabilityPool` per spec §6.6 and §5.3, with `onLiquidation` (pool side) and the dust sweep;
  `model/protocol/stability_pool.py` mirrors it; all three `product_sum.json` vectors pass on both
  sides bit-for-bit; 39 unit tests cover every revert and the prompt's edge cases.
- CHG-006 / ADR-0033 applied: accrual calls the pool once through a gas-capped, failure-tolerant
  assembly call; `POOL_HOOK_GAS = 200_000` (≥ 2× the measured 86,981); post-failure floor 6,350. Spec
  §3.1, §3.4, §4.2, §5.3.4, §5.9, §5.10, §6.2, §6.6.3, §6.6.5, §11 and `interest.json` updated.
- CHG-009 applied to invariants I13 and spec §6.3.3; ADR-0034 and ADR-0035 accepted; the blueprint
  factory (ADR-0035) implemented, and the real pool deployed in A from its blueprint.
- Pool invariant campaign (I1, I3, U4); the real pool in the core handler with deposit, withdraw and
  claim; the I8 unwind exits every depositor; precision study `model/tools/sp_precision.py` with a
  Foundry replay; `model/invariants.py` (I3, U4, attribution references).
- Threat model: T-24 mitigated, T-25 (stake collapse, accepted), T-26 (JIT sandwich).

**Decisions.** The human approved CHG-009, ADR-0034, ADR-0035, the P19 plan and its five decisions,
and accepted P17-1 as residual risk (2026-10-26).

**Found.**
- CHG-010: a correct pool breaks I3's interest attribution bound (gains in scales §6.6.7 ignores).
- The gas rule assumes the pool never reverts early when short of gas; a caller-gas sweep against a
  pool that branched on `gasleft()` found exactly that redirection; stated in §6.2 and pinned.
- P19-L1 (`MIN_POOL_HOOK_GAS` too low), CHG-011 candidate (I2 counter rule inverted), spec-audit lows.

**Reviews.** security-reviewer: no critical/high; L-2 → T-26; I-1 (runtime check masked every zero
byte; now only compiler-reported immutables), I-3 (empty / huge return, huge revert added to the
matrix), I-4 (gas figure refreshed) fixed; I-2 → P21 carry-forward. spec-auditor: no high; the I8
pool unwind, I11 pool coverage, sweep counting and reach wording, the CHG-006-scope spec text, the
model's `Underflow` and hook-answer handling fixed; the rest listed as P19-A.

**Nightly (2026-10-26).** `invariant_I13_sortedByNicrWithinTolerance` failed with "I13: exact order".
Root cause: a harness bug since P17 — the core handler's `reclaimGasReserve` action forgot the
position's I13 exactness as if it had left the list, while §5.1.10 leaves the node in the frozen list;
once every non-exact member had reclaimed, the handler applied the exact rule to two drifted near-ties
(which satisfy CHG-009's bound). Fix: the action no longer forgets the node's exactness (cites §5.1.10).
Regression: `I13ExactOrderAfterSettleTest.test_regression_I13_reclaimKeepsListMembers` (red before the
fix). Replay under the nightly profile: 4,096 × 500, green. **Correction:** the identical failure the
blueprint agent saw earlier that day was this bug, not the temporary interface change I blamed it on
(that change produced a different error, `EvmError: Revert`).

**Next.** P20 (plan approved with the human's decisions a–d, 2026-10-26); CHG-010, P19-L1 and CHG-011
await the human.

### 2026-10-25 · P18 · Local deployment, factory and manifest

**Changed.**
- **`src/deploy/BagehotFactory.sol`:** its constructor deploys every contract of one variant and
  calls every `wire`. That is one transaction with no un-wired window and no caller-supplied role
  addresses, and it uses no `{salt:}`. Every wired contract's `deployer` is the factory.
  - It exposes each address as an immutable, plus `deployBlock`, and emits `Deployed`.
  - Variant A: `stabilityPool == strategy` and no auction house. Variant B: the reverse, with
    `POOL_SHARE_BPS = 0`.
- **Local-only stand-ins** in `src/mocks/` fill the roles whose contracts do not exist yet:
  - `StandInStrategy`, for the pool and the auction house: an empty pool that takes no interest; an
    auction house with no lot, no auction and no callback;
  - `StandInDeficitLedger`, for the ledger: a zero deficit view and the reserve recorded from the
    VaultManager only;
  - `StandInShutdownModule`, for the shutdown module: §5.8's `belowCritical` exactly, and no way to
    trigger anything.
  - `LocalWETH`, a mintable WETH for local use.
- **Config:** `config/31337.toml` holds the §3.1 start values; large values are strings, parsed
  exactly. `script/Config.s.sol` loads it with `vm.readFile` and `stdToml`.
- **`script/Deploy.s.sol`:**
  - **Chain guard:** 31337 and 84532 are allowed; 8453 only with `BAGEHOT_FORK=true`; everything
    else reverts.
  - **Stand-ins:** refused anywhere but 31337.
  - **Deployment:** local mocks, then the factory, then `DeploymentChecks` before anything is
    broadcast.
  - **Manifest:** `deployments/<chainId>.json` with the addresses, block, `GIT_COMMIT`, solc version
    and parameters.
- **`script/DeploymentChecks.sol` (§3.3):**
  - constraint 8 in full: every peer, every immutable, and `deployer() == factory` with `wired()`;
  - the feeds have code and equal the config;
  - every parameter equals the config;
  - constraints 1, 3, 4, 5 and 7. Constraint 2 waits for the strategy contracts, which carry the
    penalty.
- **`script/SmokeTest.s.sol`:** reads the manifest, checks it against the factory and re-runs every
  check on the live chain. It then simulates, without broadcasting:
  1. open a position;
  2. a day passes, then accrue;
  3. a small redemption.

  After each step it checks the events and view-based invariants: I1 holder balances and sums, I2
  exact with counters taken from the events, list size, TCR.
- **`justfile`:** `smoke` defaults its sender to anvil's public account 0 for localhost RPCs only,
  since it only simulates. The fork recipe now sets `BAGEHOT_FORK=true`, which matches the guard's
  documented value; `1` is also read as true, so this changes behaviour only in clarity.
- **Static analysis:** slither's `filter_paths` now excludes `script/`, as `test/` already was;
  scripts are not deployed. Factory findings are triaged as SA-127 to SA-130. The factory now
  assigns its immutables before the wiring calls, which fixes aderyn's reentrancy findings.
- **Threat model:** the "Deployer key" row now names the factory as the deployer.

**Tests.** `test/script/DeployScripts.t.sol`, 21 tests:
- the chain guard on 1, 8453 with and without the flag, 84532, 31337 and four other chains, including
  `run()` itself on 1 and 8453;
- the stand-in refusal on Base Sepolia;
- full A and B deployments passing every check and the functional smoke;
- each check family rejecting a bad deployment: an impostor factory, a token wired to another
  strategy, an auction house in A, and a wrong WETH, feed, parameter, constraint 1 or constraint 5.

`test/unit/StandIns.t.sol` covers each stand-in and its custom errors.

**Review.** `security-reviewer` found nothing in the critical categories on the deployed path. Fixed:
- **M-1:** `just smoke` would always have failed on the project's own anvil (`--block-time 2`): it
  counted accrual events in absolute terms, and `openPosition` accrues whenever time has passed. The
  smoke test now measures every step as a change, including I2 within the step's own bound (the bound
  is additive per sub-effect). New tests smoke after blocks have passed, in A and B, and smoke twice.
- **M-2:** 8453 now needs `BAGEHOT_FORK=true` *and* an RPC that answers `anvil_nodeInfo`, as ADR-0019
  requires ("only when the RPC endpoint is localhost"), not the flag alone.
- **M-3:** the manifest is written only when broadcasting, so a dry run cannot overwrite it. It is
  keyed by variant in `deployments/<chainId>.json`, so A and B coexist; `runVariant("A")` and
  `runVariant("B")` select the variant. Covered by a dry-run test and a two-variant round trip.
- **L-1:** off chain 31337 the smoke test requires the manifest's feeds and WETH to equal the config.
- **L-2:** the factory and every stand-in revert off chain 31337, so "local-only" is enforced
  on-chain, not only by the script. The shutdown stand-in requires `CRITICAL_TCR ≥ WAD`, as the real
  constructor does.
- **L-3, L-4:** `DeploymentChecks` adds CREATE provenance: every role, including contracts without
  `deployer()`, is the factory's creation at its index, and the factory's nonce shows nothing else was
  created. It also checks that FEED_DECIMALS is what the feed reports. More negative tests: a second
  ledger, an unwired token, the sequencer feed, CRITICAL_TCR above MCR, and the factory off-chain.
- **L-6:** I2 reads A and F from the ledger; I1 covers the strategy's and the ledger's WETH.
- **I-4:** the manifest separates config-only parameters.
- **D-1:** a CI guard asserts the factory's initcode and deployment gas against EIP-3860 and
  EIP-7825.

Not fixed here:
- **L-5:** `gitCommit` does not flag a dirty tree, and solc is a constant. This needs an edit to the
  `deploy-local` recipe line, which holds the anvil key that I do not open (P18-3).
- **I-2:** see P18-2.
- **I-5:** the permissionless local mocks can be griefed on a shared anvil. Accepted, local only.

**Decisions.**
- **Stand-ins rather than waiting:** P18 comes before the modules it would deploy. They are named
  `StandIn*`, are local-only, and are replaced by P19, P21, the ShutdownModule prompt and P33.
- **No Base Sepolia config yet:** a Sepolia deployment waits for the real modules.
- **Manifest block:** `block` records the block the run simulated against; the factory's
  `deployBlock` is exact, and the smoke test checks the two are consistent.
- **Entry points:** `runVariant(string)` rather than a `run(string)` overload, because forge script
  cannot choose between overloads when the recipes give no `--sig`.
- **Local manifest:** `deployments/31337.json` is git-ignored, since local addresses die with the
  chain. Sepolia manifests will be committed.

**Acceptance (2026-10-25).**
- On a fresh anvil (account 0's nonce was 0), `just deploy-local` deployed and wired everything in
  one transaction ("ONCHAIN EXECUTION COMPLETE & SUCCESSFUL") and wrote `deployments/31337.json`:
  variant A under key `A`, B's slot empty, git commit, solc and parameters.
- `just smoke http://127.0.0.1:8545` passed against the live chain, with blocks elapsing between
  deploy and smoke.
- The deploy refusing to run on chain 1 or 8453 is tested in `DeployScriptsTest`.

**Next.** Human:
- decide CHG-009 (P17-2), ADR-0034 and P17-1;
- P18-1: ADR-0035 written (blueprints, proposed); Base Sepolia gas cap checked; implement at P19;
- optionally, P18-3.

Then P19.

### 2026-10-24/25 · P17 · Invariant harness and Medusa

**Changed.**
- New `test/invariant/handlers/CoreHandler.sol`: the whole system in deployment A or B behind
  `CountingOracle`.
  - **Actions:** open, add, withdraw, borrow, repay, close, redeem (three hint modes),
    redeemAcrossTail, warp, movePrice, toggleOracle (healthy or one of nine reasons), donate,
    togglePoolDeposits, redistribute, rare shutdown and settle, reclaim.
  - **Checks:** I9 inside the rescue actions; every protocol call caught and classified; I5 rebuilt
    from state (partials inferred from the burned amount); I13 exactness per member (CHG-005); the
    CHG-008 bound with `m` counted per member.
- New `test/invariant/CoreInvariants.t.sol` (A and B): I1 holders and sums, I2, the event
  reconstruction, I5, I8 (per step and an unwind), I9, I11, I12, I13 and `noUnexpectedReverts`, with
  `fail-on-revert` and per-run regime and reach requirements.
- New `test/invariant/medusa/CoreProperties.sol` with ten properties, and `contracts/medusa.json`.
- `VaultManagerHarness.redistribute(id)`, a test-only stand-in for §6.4.1 + §6.5.2 + §6.5.4.
- New tests: `RescuePathsUnusableOracle.t.sol` (I9∩I12, live and window), `CoreHandlerPhases.t.sol`,
  and seven shrunk regressions in `CoreHandlerRegressions.t.sol`.
- Tooling: crytic-compile 0.4.2 from slither-analyzer 0.11.6, pinned, with the `crytic-compile-check`
  recipe and a CI step.
- New `docs/fuzzing.md` with baselines, the I13 tolerance table and the review mutants.

**Decisions (human, at the plan).**
- The redistribute harness is approved, with a differential check before P20 (P17-H1).
- The rare shutdown/settle stand-in is approved, to be re-validated against the real
  ShutdownModule (P17-H2).
- claimSurplus is dropped (push model).
- crytic-compile is pinned with a CI check.
- An I9∩I12 test is required.

**Spec change.**
- CHG-008 approved without the slack ceiling I first proposed. That ceiling failed on every seed,
  and my earlier figure of 1.7·10⁻¹⁷ for the measured slack came from final runs only; both were
  corrected to the human.
- I13 now uses a per-member derived bound, with a quantified weak regime. Applied to
  `docs/invariants.md` on 2026-10-24 by a script that checks protected-paths itself. ADR-0034 is
  proposed.

**Found.**
- **P17-1 (open, human decision before P20): stake collapse in A.** Active stakes of 0, and
  `totalStakes == 0` with open positions, are reachable, and §6.4.1 then routes remainders to the
  DEFICIT path. The review extended this with (d) persistence after a full exit and (e) inversions
  after a reset.
- **P17-2 (open):** the CHG-008 derivation omits the snapshot-ratio error (review F3).

**Review.** `security-reviewer`, with 15 mutants of its own:
- **Mutants M11–M15** passed the whole suite and Medusa: shutdown or settlement hooks reverting, the
  harness redistribute failing, redemption dead or always refused.
  - **F1:** every protocol call in an action is now caught and classified, `fail-on-revert` is on,
    and deterministic phase tests were added.
  - **F2:** a redemption refusal is accepted only when the state before the call justifies it.
  - All five are now caught (`docs/fuzzing.md`).
- **Also fixed:**
  - **F6:** the exact-regime counter no longer starts at 1. That exposed runs whose list was never
    exact after an action, so the first redistribution now waits for one exact step.
  - **F8:** the I13 regressions now pin their redistributions, the tolerance regime and `k > 4`.
  - **F9:** a below-MCR node redeemed in full is a violation, and untouched members are compared
    across the whole list, including stake and snapshots.
  - **F10:** a vacuous assertion dropped; the window phase added.
- **New regression:** `fail-on-revert` exposed a handler-side panic in the settled phase, now
  covered by `test_regression_redeemAfterSettlement_noEscapingRevert`.
- **Recorded, not fixed here:**
  - F3 → P17-2; F4 → P17-1; F5 → P17-H1.
  - F7: Medusa has no `afterInvariant`; reach is read from lcov.
  - F11: `HarnessRedistributed` stands in for `Redistributed`; `donatedToken[VaultManager]` has no
    I1 row.
  - F12: PR CI must keep at least the default profile.
- **Not reached:**
  - A per-run requirement that a redemption succeed was tried and dropped: price paths below the
    critical TCR legitimately refuse every redemption, and F2's classification already catches a
    dead one.

**Next.** Human:
- re-protect `docs/invariants.md`;
- accept or amend ADR-0034;
- decide P17-1 and P17-2 before P20.

Then P18.

**Follow-up 2026-10-25 (P17-2).** The human asked for a re-derivation of I13's bound rather than a
relabel. An exact-integer model search (`scripts/analysis/i13_bound_search.py`) found that a correct
VaultManager breaks CHG-008's bound on protocol-valid sequences: 34 of 64 grid scenarios, and the
deterministic regression `I13BoundCounterexampleTest`, whose state matches the model bit for bit.
CHG-009 (proposed) derives an exact per-pair tolerance from hidden ideal keys, with three exact
companion checks: the key identity, insertion exactness and the §6.5.4 stake.
- **Audit:** `spec-auditor` confirmed the derivation and implementation. Its findings on the claims
  were applied:
  - the tolerance is stated in observed keys;
  - the weak regime is given as observations with no a-priori limit, vacuous in zero-stake states;
  - the counterexample's liquidations are proved genuine;
  - ι is made exact;
  - the edit covers the Summary and Open-items rows.
- **Campaign:** zero violations. The new checks catch M7 (wrong stake) and a stored-value `sortKey`
  deterministically.
- **Waiting for the human:** `docs/invariants.md`, ADR-0034 and an optional §6.3.3 sentence.
  CHG-008's check stays asserted until then.


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

### 2026-10-24 · P16 · RedemptionModule and the redemption loop

**Changed.**
- New `src/redemption/RedemptionModule.sol` (§4.6, §5.5, §6.7.1–6.7.2):
  - `redeem` with the fee (floor + decayed base rate + increment from the requested amount; base rate stored from the redeemed amount), the auction-callback guard, the critical-TCR gate via `ShutdownModule.belowCritical` after accrual, and its own transient lock;
  - views `decayedBaseRate` and `redemptionFeeRate`;
  - constructor checks at §3.4's indices 0–4 and a one-shot `wire(vaultManager, shutdownModule, auctionHouse)` (auctionHouse 0 in A).
- `VaultManager.redeemCollateral` (§5.1.9, §6.7.3): the loop from the tail, the below-MCR skip, full redemptions that push surplus plus gas reserve to the owner (push model, no `claimSurplus`), and at most one partial, cancelled with no state change at exactly MIN_DEBT, by the CHG-002 post-check, or on a stale hint. Emits `PositionRedeemed` and `PositionUpdated(op 7)`; status `ClosedByRedemption`.
- `HintHelpers.getRedemptionHints(amount, price, maxIterations, feeRate, numTrials, seed) → (upperHint, lowerHint, partialId, redeemable)` (approved signature): simulates the loop with the same integer arithmetic, including all three cancellations.
- Interfaces `IRedemptionVault`, `IRedemptionViews`, `IAuctionHousePurchaseState`, `IShutdownGate`; shared error `AuctionCallbackActive`.
- Python: `vault.py` gained `redeem_collateral`, `system_coll` / `system_debt` (parity gap since P14 closed) and the burn balance check; new `model/protocol/redemption.py` with `make_gate` implementing §5.8 exactly.

**Decisions.**
- Push model for the owner's surplus and gas reserve; lock on `redeem` (human, at plan approval).
- `getRedemptionHints` starts `find` from the closest sampled member, or from the partial node's neighbours when that sample is the node itself (which `find` excludes).
- Tests use `MockShutdownGate` (§5.8 verbatim) until the ShutdownModule prompt, and `MockPurchaseHouse` for deployment B.

**Tests.**
- **All seven `redemption.json` vectors end to end on both sides**, each with every step's result, trace (skips checked against `isLiquidatable` at the visit), reverts and the full expected state. Passed on first implementation.
- **CHG-002 line item (P04-2, closed):** see the open-issue row. The direct call proves the post-check branch: no `find`, (0, 0, 1), state unchanged.
- **Two locks (human's condition):** `test_redeem_twoTransientLocksDoNotInterfere` (accrue and redeemCollateral each called once inside `redeem`), `test_redeem_bothLocksReleasedAfterwards`. `RedemptionReentrancyTest` shows the RM lock blocks a re-entrant `redeem` and the VaultManager lock blocks its mutators mid-redemption; `redeemCollateral` is the 11th target of `VaultManagerReentrancyTest`.
- **Hint helper vs `redeemCollateral` (human's condition):** identical `redeemable` and partial position on every redeem step of all seven vectors, with the state accrued as `redeem` will. Plus a 1,024-run fuzz at the MCR/MIN_DEBT boundary (random index 1–4, price 10–3,000, slack 0–3 wei, tiny and large amounts), and the helper's own no-slot cancellation.
- **Unit:** every error in its order (`ZeroIterations`, `FeeExceedsMaximum` at max − 1 and max, `NothingRedeemed`, `TCRBelowCritical` at the feed-precision threshold, `AuctionCallbackActive`, `InsufficientBalance`, `PriceUnusable`, `SystemShutdown`, `NotWired`, `Unauthorized`, constructor and `wire`), fee from requested vs base from redeemed, 12-hour halving and the 1-wei floor, partial to exactly MIN_DEBT then the stop, pending rewards applied to the redeemed position only.
- **Rounding at index 1.2346 (R18, R3, R1, R19, R20):** each test asserts floor ≠ ceiling for its operands. **Mutation check: 8/8 caught** (5 contract sites + 3 in the hint helper; the helper's R18 survived the vectors and is caught by the boundary fuzz, added for that reason). Removing the CHG-002 post-check is caught by four tests.
- **Attacks:** dust redemptions on a zero-slack position (the CHG-002 window exercised, never below MCR), dust still pays and moves the base rate, stale hints cost only the partial, self-redemption at par, a redemption from inside a deployment-B buyer callback.
- **Gas** (`RedemptionGasTest`): ~55,500 per full redemption (50 MIN_DEBT positions closed in 2.77M); ~20,600 per skipped below-MCR node; `maxIterations` caps the walk.
- **Invariant campaign** (`RedemptionInvariantTest`, 256 runs × 200 calls, 0 reverts, seeds 1–3): I5 (redeemed positions healthy; at most one partial and it is the last visit; every visited unredeemed node before the last was below MCR), I15 (the gate fires exactly when its condition holds; reached on every seed) and I2 with redemption's counts (`PositionRedeemed`: Y when closed, X when partial).
- Coverage: RedemptionModule and VaultManager 100 % lines and branches; HintHelpers 100 % lines.

**Observed, not a defect.** §6.7.2 charges each redemption the base rate including its own increment (as Liquity), so two same-block halves pay a lower average rate than one redemption of the whole. Pinned by `test_feeSplitting_halvesPayLessThanTheWholeBySpecDesign` so a change is noticed; relevant to the report's fee analysis.

**Found.** CHG-007 (open issue P16-1): I5's skip clause is false for a successful call whose last visit is a cancelled partial. Raised to the human; invariants unchanged.

**Static analysis.** 57 rows repointed via a diff line map; four naming rows corrected that had silently matched a neighbouring finding after the shift; SA-090 … SA-125 added.

**Review.** `security-reviewer` (24 mutants of its own, 51 redemption tests, 21 model tests): no critical or high finding; nothing kills liquidations, mints unbacked supply, forges a shutdown or bricks a rescue path. Acted on:
- **F1, a test gap (the code was right).** Deleting `_applyPending` from `_redeemFull` survived the whole suite: only the partial had a pending-rewards test. Added `test_redeem_fullWithPendingRewards_appliesThemFirst` and `…_outAboveStoredCollateral` (collateral out exceeds the stored collateral, so the mutant underflows). Both kill the mutant.
- **F3.** With more than MAX_HINT_STEPS full redemptions ahead of the partial, `getRedemptionHints` sampled from the tail — among the nodes the call removes — and reported no slot. Sampling now starts from the partial node; `test_hints_manyFullRedemptionsBeforeThePartial` (35 full + 1 partial) fails with the old seeding and passes now.
- **F6, F7.** Misnamed test renamed (`test_redeem_validCallerHintsPlaceThePartial`); a NatSpec line break fixed.
- **F8.** The threat model's T-15 now states that the redemption loop's order relies on WETH having no transfer hook.
- **F2, F4** go with CHG-007 (open issue P16-1): the last-visit reason check once I5 is reworded, and an I15 "Breaks if" that names an unobservable failure (item 2). **F5** is a carry-forward row for the ShutdownModule prompt (re-run the gate tests against the real `belowCritical`).

**Next.** Human: decide CHG-007 (P16-1) and accept ADR-0033 when convenient (needed before P19). Then P17.

**Follow-up 2026-10-24.** CHG-007 approved and applied (I5 last-visit clause with a reason check, I15 "Breaks if"); ADR-0033 rewritten to state its three requirements in full and accepted by the human. Human: re-protect `docs/invariants.md` (line 10) and add ADR-0033 to the protected list.

### 2026-10-23 · P15 · VaultManager II: interest accrual and routing

**Changed.**
- `VaultManager._accrue()` per spec §6.2: new index R4 (up), interest R6 (up), pool share R7 (down).
  - Minted to the stability pool only when it `acceptsInterest()` (deployment A), the rest to the DeficitLedger reserve; each is notified through `onInterest`.
  - `InterestAccrued` emitted; state written before the mints.
- A public `accrue()`: anyone, `wired` required, a no-op once shut down, under the lock.
- `currentIndex()` now accrues in the view without writing. `debtOf`, `systemDebt` and `tcr` use it.
- New interfaces `IStabilityPoolInterest` and `IDeficitLedgerInterest`.
- The Python mirror gained the same accrual, `accrue()` and `current_index()`.

**Decisions (spec over prompt).**
- **The index still grows when `totalNormDebt == 0`** (§6.2: "interest = 0"). It is not frozen with only the timestamp moving, as the prompt said.
- **No custom `Overflow()` error.** §11.2 has none; the arithmetic panics `0x11` (spec §2.2), which the model names `Overflow`.
- **Maximum `dt`, documented in `_accrue`'s NatSpec and tested at the exact boundary** (from index RAY, one accrual):
  - 74,509,693,419 s (≈ 2,362.7 years) at the start rate;
  - 5,244,687,241 s (≈ 166.3 years) at the maximum rate;
  - in practice the 2^128 supply cap stops interest minting long before.

**Tests.**
- `interest.json` on both sides: the pool share, the pool below `MIN_DEPOSIT`, deployment B, yearly vs 365 daily accruals (a 104-wei difference), and the R1–R3 conversions at index ≈ 1.05.
- **The accrual rules:** a second accrual in the same block is a no-op; the index grows without debt; shutdown freezes it; views accrue without writing; operations accrue first; routing.
- **A long-horizon fuzz** (waits from 1 s to ≈ 3 years) checking I2 with event-counted N, X and Y, and the sum-of-ceilings bound after every step.
- **The I2 invariant campaign** (`VaultI2InvariantTest`, the acceptance criterion): open, add, withdraw, borrow, repay, close, accrue and time warps.
  - Green, alongside I1 and the bound Σ debtOf(nᵢ) − n·I/RAY ∈ [0, one wei per position).
  - **Rerun with reverts failing the run:** it surfaced two handler bugs of the same kind, not contract bugs.
    - The handler sized `open` collateral for the nominal debt, and capped `borrow` at `cap − debt − 1`.
    - Above index RAY, opening or borrowing `a` adds up to I/RAY wei more than `a` to the debt (R2 then R1), so the contract's `IcrBelowMcr` was correct both times.
    - The handler now accounts for that margin.
- **Reentrancy:** `accrue` added to the guarded targets, now ten mutators.

**Review.** `security-reviewer`: nothing that mints unbacked supply, under-mints, double-accrues or moves the index after the trigger. Fixed:
- **F1, a test gap.** Removing `_accrue()` from open, add, withdraw or close passed the whole suite, because the I2 handler pre-accrued before those operations.
  - Each of the six operations now has a test that it accrues first: the index the view predicted, `lastAccrual` stamped, and `InterestAccrued` logged before the operation's own events. Close burns the accrued debt, and in the window nothing accrues.
  - The handler now sizes inputs from the views.
  - **Mutation check:** all six removals caught, where four survived.
- **F2, F3.** The reentrancy triage rows were rewritten. New tests: hostile pool and ledger `onInterest` hooks re-entering each of the ten mutators.
- **F5.** The overflow NatSpec now states the cumulative-growth limit, says it's reachable with no debt, and gives the time to the supply cap by rate.
- **F6.** R7's floor tested with a remainder (Python).
- **F7.** E reads `A` and `F`.

**Raised to the human:** F4, open issue P15-1 and threat T-24. Deferred: F7's B/window coverage (P15-2) and F8 (P15-3).

**Next.** Human: decide P15-1. Then P16.

### 2026-10-23 · P14 · VaultManager I: positions, borrowing, minimum debt, gas reserve

**Changed.**
- New `src/core/VaultManager.sol`, transcribing spec §5.1.1–§5.1.6 line by line: open, addCollateral, withdrawCollateral, borrow, repay, close.
- Also from the spec:
  - `reclaimGasReserve` (§5.1.10) and the shutdown hooks `onShutdown`/`onSettlement` (§5.1.11);
  - the views of §5.1.12: `currentIndex`, `effective`, `sortKey`, `debtOf`, `icr`, `nicr`, `systemColl`, `systemDebt`, `tcr`, `isLiquidatable`;
  - §6.5.3 apply-pending and §6.5.4 stakes, implemented exactly (human's choice at the plan gate).
- Interest is the empty internal hook `_accrue()` until P15; the index stays at RAY and `currentIndex()` returns it.
- Shared errors moved to `src/lib/Errors.sol`. New interfaces `IOracleAdapter`, `IStableToken` (now `is IERC20`) and `ISystemViews`. StableToken and OracleAdapter declare their interfaces.
- New Python mirror `model/protocol/vault.py`: the same checks in the same order, the same error names, atomic like a transaction.

**Decisions (human, at the plan gate).**
- Stakes and pending rewards exact, not stubbed.
- The shutdown hooks and `reclaimGasReserve` included, so `SystemShutdown`, `SystemSettled` and `NotSettled` can be triggered.
- The model written now rather than at P22.
- Spec over prompt on views: `effective` and `systemDebt` replace the prompt's `collOf` and `totalDebt()`.
- The redistribution error carries (`lastErrorColl`/`lastErrorDebt`) are left out until P20 writes them. There's no proxy, so storage layout needn't be fixed in advance.

**Tests.** 100% line and branch coverage on `VaultManager.sol`.
- Unit tests on every function and every error, in pseudocode order, with boundaries: ICR exactly at MCR, `MIN_DEBT`, the maximum repay, the 2^128 − 1 collateral cap.
- Propagated `StaleHint` and `SupplyCapExceeded`.
- I9 (no oracle read at any ICR); I12 (sequencer down, stale, out of bounds, failed call).
- 1,024 random operation sequences checking I1, exact I2 at index RAY, the supporting identities and exact list order after every step.
- Reentrancy: a hostile WETH and token call back into each of the nine mutators, which all revert on the lock.
- The non-zero pending and stake paths, through a test harness that sets the redistribution state P20 will write.
- Fuzzed: `close` always works after any repays (the prompt's dust pitfall, which the spec's rules make impossible).
- **Vectors:** the leading position steps of all 23 system vectors (61 steps), with ids and recorded drift state, on both sides. **Full vector replay** needs P15 (interest), P16, P19–P21 and the P23 harness.

**Review.** `security-reviewer`: no critical or high finding; nothing under "unbacked mint", "frees collateral" or "kills liquidations". Fixed:
- **V-1, test strength.** No test ran at a non-round index, so wrong rounding directions R1, R2 and R3 were invisible, and R8 was never exercised with a remainder.
  - New `VaultManagerRoundingTest`, run at index ≈ 1.2346 RAY through `VaultManagerHarness.setIndex`, with mirrors in pytest.
  - **Mutation check:** eight mutations now fail the suite where all eight used to pass. They are R2 on open, R2 on borrow, R3, R1, R8, settlement without `pendingColl`, close without apply-pending, and borrow without update-stake.
- **V-2.** The model now uses checked arithmetic and raises `Overflow` where the contract panics `0x11`, not a spec error. Tested on both sides.
- **V-3.** Settlement with pending collateral is tested.
- **V-4.** Every operation's apply-pending and update-stake is tested, with a 4 : 5 snapshot ratio so a skipped stake update would show.
- **V-5.** The hooks check the caller before state, tested where the order matters.
- **V-8.** A NatSpec line repaired.

V-6 is the human's re-protect of line 10. V-7 notes view edge cases that are consistent with the spec.

**Parity checklist, Solidity ↔ `model/protocol/vault.py`** (P22 extends the model; tick in P23's differential test):

| Item | Contract | Model | Checked by |
|---|---|---|---|
| open / add / withdraw / borrow / repay / close: check order and error names | ✓ | ✓ | unit tests on both sides (`test_error_order_matches_the_contract`) |
| rounding R1 / R2 / R3 / R8 / R10 | ✓ | ✓ | vector prefixes (drift state), pending test |
| apply pending, stakes, snapshot rule | ✓ | ✓ | `VaultManagerPendingTest`, `test_apply_pending_and_stake_after_a_snapshot` |
| events (`PositionUpdated` with all 8 fields, …) | ✓ | ✓ (tuples) | unit tests; exact comparison at P23 |
| shutdown hooks, `reclaimGasReserve` | ✓ | ✓ | unit tests |
| views `effective`, `sortKey`, `debtOf`, `icr`, `nicr`, `isLiquidatable` | ✓ | ✓ | unit tests |
| views `systemColl`, `systemDebt`, `tcr` (read ledger and house) | ✓ | **missing**: the model has no ledger or house yet | P22 |
| atomicity (revert leaves no state) | EVM | ✓ (`_atomic`) | `test_failed_operations_leave_no_trace` |
| checked arithmetic (Panic 0x11 ↔ `Overflow`) | ✓ | ✓ (`_c`) | `test_overflow_panicsOnAbsurdInputs`, `test_checked_arithmetic_raises_overflow_like_the_contract` |
| rounding at a non-round index | ✓ | ✓ | `VaultManagerRoundingTest`, `test_rounding_directions_at_a_non_round_index` |
| `nonReentrant`, `wired`, `Unauthorized` on hooks | ✓ | n/a, or partial (no `wired` flag in the model) | P22 decides whether the model tracks `wired` |
| interest accrual | P15 | P15 | — |

**Next.** Human: re-protect `docs/invariants.md` (line 10). Then P15.

### 2026-10-23 · P13 · SortedPositions and hint helpers

**Changed.**
- New `src/core/SortedPositions.sol`, spec §6.3 transcribed:
  - keys read from `sortKey` and compared by exact cross-multiplication, with no NICR division;
  - walks bounded by `MAX_HINT_STEPS`, failing with `StaleHint`;
  - `find`, a non-reverting probe that evaluates exclusion on the reduced list.
- New `src/core/HintHelpers.sol`: view-only `getApproxHint`, approved by the human; `getRedemptionHints` deferred to P16.
- Interfaces `ISortKeySource` and `ISortedPositions`.
- Python mirror `model/protocol/sorted_list.py`, which also reports walk steps.

**Decisions.**
- **Spec over prompt.** `insert(id, upperHint, lowerHint)` reads keys itself rather than taking a NICR, and the views follow spec names (`getFirst`, …, `find`); there is no public `findInsertPosition`.
- **Id 0 is the null link:** inserting it reverts `NodeExists`. This is unreachable through the VaultManager.

**Tests.**
- Unit tests on every branch and error, plus CHG-005's regression test.
- Both vectors in Foundry and pytest; the Python step counts match the traces.
- Fuzz against a sorted-array reference (2 × 1,024 sequences). With `MAX_HINT_STEPS` = 2, every insert lands exactly or reverts `StaleHint` with no side effects.
- I13 handler: insert, remove, re-key, drift; per-member exactness; both regimes required in every run.
- Coverage 100%.

**Gas** (storage cold, as in a fresh transaction; includes the mock VaultManager's call):
- **Insert with exact hints:** 135,254 at list sizes 10, 100 and 1,000, so O(1).
- **Hint off by k:** 141,112 / 173,065 / 340,820 for k = 1 / 5 / 25, about 8,400 per extra step.
- **Stale hint at `MAX_HINT_STEPS` = 30:** 285,779, the same however stale the hint.

**Found.** I13's tie clause was false under drift (CHG-005).
- A deterministic five-operation counterexample. The fix I first proposed ("no current member has drifted") was also false, on 4 of 30 seeds, because the counterexample's own final state satisfies it. I corrected it before applying.
- The approved wording, ADR-0032, defines a recursive "exact" member: key unchanged since its last insertion, and every member exact at that insertion. The campaign after applying: 30 seeds × 256 runs × 200 calls, 0 failures, both regimes reached in every run.
- No downstream reliance on strict tie order under drift. Spec §6.3.1's phrase "among equals, highest id first" describes the exact regime; a qualifier there is optional and would need the spec unlocked.

**Next.** Human: re-protect `docs/invariants.md` (line 10). Then P14.

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
| CHG-003 | **P18 acceptance criterion: the wiring graph** (spec §3.3 constraint 8, ADR-0031). This must become a named acceptance criterion in P18's own prompt file once the human commits `prompts/`; until then it is recorded here. The criterion: - **Before broadcasting**, the deploy script asserts that every `wire` address is the contract the factory created for that role, that the peer graph agrees, that every immutable `token`/`weth`/`oracle` is the deployment's, and that no role is an EOA. - **The post-deploy smoke test** asserts the same, plus `deployer() == factory` and `wired()` on every contract in the deployment receipt. - **Tests:** a StableToken wired to a different strategy than the VaultManager fails, and so does an EOA role. | P18 (add to `prompts/P18-*.md` when committed) |
| CHG-005 | **Done at P17:** `CoreHandler` tracks per-member exactness (`_placed`, `_refreshExactness`) and every run of A reaches both regimes, the exact one counted only after an action on a list of two or more. Original requirement: **P17 must track per-member exactness in its I13 handler, exactly as P13's handler does (ADR-0032).** A member is *exact* if its key has not changed since its last insertion **and** every member was exact at that insertion. I13 asserts exact order (ties included) only while every current member is exact, and the tolerance check otherwise. Every run must reach both regimes. "No current member has drifted" is **not** an acceptable simplification: it fails on 4 of 30 seeds. The reference implementation is `contracts/test/invariant/SortedPositionsInvariant.t.sol`. Flag this when planning P17. | P17 |
| P16-F5 | **ShutdownModule prompt: re-run the redemption gate against the real `belowCritical`.** I15 and the gate are tested at P16 only against `MockShutdownGate`, a literal copy of §5.8. The ShutdownModule prompt must re-run `RedemptionInvariantTest.invariant_I15_noRedemptionBelowCritical`, `RedemptionVectorsTest.test_vector_tcrGuard` and `RedemptionAuctionCallbackTest` against the real module, and add a test with `dt > 0` since the last accrual where the view is called without accruing, so a stored-`index` read would flip the result (P16 review F4/F5). | ShutdownModule prompt |
| P17-H1 | **Equivalence confirmed at P20** (`RedistributionHarnessEquivalenceTest`, 1,024 fuzzed runs: identical accumulators, carries, pending, snapshots, keys and order); remaining: re-run the I13 campaign on real liquidations with the core handler (P20 invariant step). **Test stand-in to re-validate (same category as P16-F5): the redistribution harness vs P20's real liquidation.** P17's I13 tolerance work runs on `VaultManagerHarness.redistribute(id)`, a test-only implementation of §6.4.1 (strategy absorbs nothing) + §6.5.2 + §6.5.4. Before P20 swaps it for the real `liquidate`, a differential-style test must show the harness and P20's real redistribution produce **identical** state (`LColl`, `LDebt`, `lastErrorColl`, `lastErrorDebt`, `pendingColl`, `pendingNormDebt`, snapshots, every position's effective key) on the same inputs and sequences; then the I13 campaign (both regimes, the CHG-008 bound once decided) is re-run with real liquidations. Human's condition at the P17 plan. **Extended by the P17 review (F5):** identical state on the same inputs cannot catch a difference in the *kind* of inputs. The harness redistributes the whole collateral of healthy positions (collateral-rich), whereas a real empty-pool liquidation in A redistributes only `min(coll, ⌈debt·(WAD+penalty)/price⌉)` of a position below MCR and pushes the surplus to the owner (debt-heavy), the opposite drift direction (P17-2). P20 must also run the I13 campaign under debt-heavy redistributions, and add a harness mode that runs §6.4.1's DEFICIT branch and the reset (P17-1 (e)). | P20 |
| P17-H2 | **Test stand-in to re-validate (same category as P16-F5): the shutdown/settlement harness action vs the real ShutdownModule.** P17's core handler reaches the window and settled phases by having the wired shutdown address call `onShutdown` (after an `accrue`) and `onSettlement` directly. The ShutdownModule prompt must replace this with the real `check()` / `settle()` and re-run `CoreInvariants` (I1 phase scoping, I2 in the window, I9 in the window, the I8 unwind in the settled phase) against it, not leave the stand-in in place. Human's condition at the P17 plan. | ShutdownModule prompt |
| CHG-006 | **P19 acceptance criteria: the pool interest hook is non-fatal** (ADR-0033, accepted by the human 2026-10-24, so P19-AC-CHG006-3 is met; decided by the human 2026-10-24 as option 1 for P15-1). These must become named acceptance criteria in P19's own prompt file once the human commits `prompts/`; until then they are recorded here and in CHG-006, which holds the full text. **P19-AC-CHG006-1 — the fallback path cannot revert:** ledger `onInterest` call-free, fuzzed from 0 to the supply cap without reverting; with a pool that reverts, panics (`G` overflow), burns all its gas, returns the wrong size or a non-bool word, `accrue()` and every accruing operation (repay, addCollateral, close, borrow, withdrawCollateral, open, liquidation, `ShutdownModule.check`) succeed, the whole offered amount reaches the reserve, `PoolInterestRedirected` is emitted and I2 holds; `SupplyCapExceeded` is pinned as the only remaining revert path. **P19-AC-CHG006-2 — under-supplying gas cannot fake a pool failure:** `POOL_HOOK_GAS` derived from a recorded worst-case measurement of the real pool (≥ 2×), floor `ceil(2·POOL_HOOK_GAS/63)`; a caller-gas sweep against the real pool and a heavy pool records zero redirections; a genuine over-cap pool is redirected; floor boundary tested ±1. **P19-AC-CHG006-3:** ADR-0033 accepted before the spec text is applied (spec unlock needed). | P19 (add to `prompts/P19-*.md` when committed) |
| CHG-006-P20 | **Done at P20:** `liquidate` is operation 7 of `VaultManagerPoolHookTest`'s failing-pool matrix (8 modes); the pool share is redirected and the liquidation completes. | P20 (done) |
| CHG-006-SM | **ShutdownModule prompt: `check()` joins the failing-pool matrix** (the other deferred AC-CHG006-1 sub-case, next to P16-F5). | ShutdownModule prompt |
| P19-I2 | **P21 requirement (P19 security review I-2):** the real DeficitLedger's `settled()` never reverts and `onPoolDust` accepts from the pool without reverting in every phase while not settled — otherwise the last current-epoch depositor cannot exit (`_leave` runs before their transfer). Test: `onPoolDust` never reverts live and in the window; the last depositor exits during the window. | P21 |
| P20-I3 | **P21 requirement (P20 security review I3):** the real DeficitLedger hands `recoveredColl` to the claim pool at settlement (§6.11.3) and `recordDeficit` carries §5.6's `wired`/caller/`!settled` checks; the stand-in has neither, so local runs that reach the no-stakes path and then settle strand that WETH. Test: I1/I10 after a prior no-stakes deficit. | P21 |
| P19-T26 | **Measured at P20** (`VaultManagerLiquidationTest.test_jitSandwich_measuresProfitAndDilution`): at ICR 1.067, a sandwicher matching the standing depositor's 5,000 captures 75 of the 150 penalty and halves the standing depositor's collateral gain. P26's depositor agent and S3 still model it. | P26 |
| P20-SD | **Test stand-in to re-validate (same category as P16-F5, P17-H1, P17-H2): the DeficitLedger stub's storage-backed `recordDeficit` (P20, human decision b 2026-10-26).** When P21 replaces the stand-in with the real ledger, re-run every P20 test and vector that reaches the no-stakes DEFICIT path against it, and confirm `deficit`/`recoveredColl` and I1's ledger row agree. | P21 |
| P20-B | **Test stand-in to re-validate: the core handler's B-variant house mock `onLiquidation` per §6.8.2 (P20, human decision c 2026-10-26),** so I4/I6/I7 run on B before the DutchAuctionHouse exists. At P33 re-run the B campaign against the real house and compare. | P33 |
| P20-SIZE | **VaultManager size (human note 2026-10-26):** after P20 about 2–3 kB of EIP-170 headroom remains (the binding limit is the 0xFE blueprint). Anything P21/P33 would add to the VaultManager itself must be measured before it is written, not after. | P21, P33 |

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
| P03-1 | **Closed 2026-10-24 (P17):** the campaign exceeded `k = 4`; CHG-008 replaced it with a derived per-member bound, applied to I13 (ADR-0034, proposed); its derivation is questioned in P17-2. Original: I13's `k = 4` is calibrated to the P02 measurement, not derived: §6.3.3's stake-ratio divergence has no constant bound when a large liquidation meets a small `totalStakes`. P17 must re-validate against the campaign and may tighten it; exceeding it is a `/spec-change`, never a bump. | Claude | at P17 |
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
| P04-1 | Two threat-register rows have no test yet: `AuctionCallbackActive` on `buy`/`check` (T-14 → P33), and a `redeem` called from inside a buyer callback (T-01/T-14 → P16/P33, same gap as P02-4). Each is marked TBD in `docs/threat-model.md` with its prompt. The third, the oracle gas-starvation branch (T-03), was closed at P12 by `OracleAdapterGasTest`. **Updated 2026-10-24:** the `redeem`-from-a-buyer-callback row (T-01/T-14) now has a Foundry test against a mock house (`RedemptionAuctionCallbackTest`); the real house and `AuctionCallbackActive` on `buy`/`check` remain for P33. | Claude | at P33 |
| P04-2 | **Closed 2026-10-24 (P16).** ADR-0027's obligation is met against `VaultManager.redeemCollateral` itself: `RedemptionBoundaryTest.test_redeem_tinyPartialAtMcrBoundary` rules out every other exit from the state (not skipped: exactly at MCR; not the MIN_DEBT stop; `find` would succeed), then calls `redeemCollateral` as the module and asserts it visits alice once, never calls `find`, returns (0, 0, 1) and changes nothing — the CHG-002 post-check is the only branch that does that. `…_throughTheModule`: the 11-wei call reverts `NothingRedeemed` with every field unchanged; the 1,000-stable partial raises her ICR 1.1 → 1.101897. Removing the post-check fails both, the vector and the hint-agreement test. Passed on first implementation. | Claude | closed |
| P11-1 | **Addressed at P18** (`BagehotFactory`, `DeploymentChecks`): deploy and wire in one constructor with no caller-supplied role addresses, no `{salt:}`, `deployer() == factory` and `wired()` asserted before broadcast and in the smoke test, feeds checked for code and against the config, threat-model row updated. The Base Sepolia feed check (configured Chainlink address unless `fork_replay`) is the same feed check and applies once `config/84532.toml` exists. Original: **P18 deployment pitfalls from the P11 review (F-4).** `deployer` is whoever executes CREATE. (i) `new X{salt: s}` inside `forge script` goes through the CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`, which becomes `deployer` and can never call `wire`: the contract is bricked, permanently NotWired. (ii) A factory that deploys in one call and exposes a separate `wireAll(...)` moves the front-running window from `wire` to the factory. P18 must: deploy and wire inside one factory call that takes no caller-supplied addresses; never use `{salt:}` for wired contracts; assert `deployer() == factory` and `wired()` from the deployment receipt; on Base Sepolia, assert that the price feed is the configured Chainlink address unless the environment is `fork_replay` (`ReplayAggregator` is operator-controlled). Also (P12 review F4) assert that both oracle feeds have code and equal the `config/<chain>.toml` addresses. Also update the threat-model row "Deployer key": with a factory, the deployer is the factory. | Claude | at P18 |
| P11-2 | Resolved 2026-10-23: CHG-003 approved (option 1) and applied to spec §2.5, §3.3 constraint 8 and §11.1 (ADR-0031, proposed). The human's condition: the deploy-script wiring-graph check and the smoke-test assertions (`deployer() == factory`, `wired()` on every contract, peer-graph agreement) must be a named acceptance criterion in **P18's own prompt text**. The prompt kit is not in this repository (there is no `prompts/` directory), so the human adds it there; the exact text was handed over on 2026-10-23. | — | closed |
| P12-1 | Resolved 2026-10-23: CHG-004 approved and applied. The floor is now `ceil(2·ORACLE_GAS/63) ≤ ORACLE_POST_FAILURE_GAS ≤ ORACLE_GAS`, start value 3,175, per ADR-0030 (which supersedes ADR-0024's bound). Before approving, the human required two checks, and both passed: the critical cases re-run on Base's real proxy, and an honest caller tested at the new floor. The permanent regression sweeps are `test_regression_proxiedFeed_*` (in `just test`) and `OracleGasRuleForkTest` (in `just test-fork`). | — | closed |
| P15-1 | **Decided 2026-10-24: option 1 — the pool interest hook becomes non-fatal** (P15 review F4; threat T-24). Options 2 and 3 rejected by the human. Written up as CHG-006 (approved, not yet applied) and ADR-0033 (proposed); implemented at P19 with three named acceptance criteria (Carry-forward row CHG-006). Until then the behaviour pinned by `test_F4_revertingPool_blocksNormalMode_notTheWindow` stands. | Claude | at P19 |
| P15-2 | **Closed 2026-10-24 (P17):** `invariant_I2_supplyDriftBound` runs over `CoreHandler` in A and B, through the window, with pool deposits toggled. Original: The I2 campaign (`VaultI2InvariantTest`) covers deployment A in the live phase with the pool always accepting. P17 must extend it to deployment B, the shutdown window and toggling pool deposits, and should use the name `invariant_I2_supplyDriftBound` that I2 cites (P15 review F7). `A` and `F` are already read from the ledger in E. | Claude | at P17 |
| P15-3 | Freezing at the right index depends on `ShutdownModule.check` accruing immediately before `onShutdown` (§5.1.11). The ShutdownModule prompt must test that the index right after a trigger equals `currentIndex()` just before it (P15 review F8). | Claude | at the ShutdownModule prompt |
| P16-1 | **Closed 2026-10-24.** CHG-007 approved and applied to `docs/invariants.md`: I5's clause about visited, unredeemed nodes now requires every visit before the last to be below MCR, and an unredeemed last visit at or above MCR to be a cancelled partial for exactly one legitimate reason (MIN_DEBT cap, CHG-002 post-check, stale hint — the first that holds); I15's "Breaks if" names the stored-`index` read. `RedemptionInvariantTest` asserts `lastVisitWithoutReason == 0`; negative tests: `RedemptionLastVisitTest.test_lastVisit_illegitimateStopIsRejected` and two contract mutants of a wrong early stop, both rejected. | Claude | closed |
| P17-1 | **Closed 2026-10-26: accepted by the human as documented residual risk, no code change at P19/P20; recorded as threat T-25 with its cost model in `docs/threat-model.md`.** Stake collapse in deployment A (found by the P17 campaign through the test-only `redistribute` harness; analysis in CHG-008's appendix). Each redistribution multiplies the snapshot ratio `totalStakesSnapshot/totalCollateralSnapshot` (§6.5.4) by roughly the share of stake that survives it, and nothing restores it while any stake is left. Campaign data (8 seeds × 256 runs × 200 calls, A): active stakes of 1–999 wei in every seed; **active positions with stake 0** (763 member-steps, 23 runs); **`totalStakes == 0` with a non-empty list** (432 steps, 18 runs), the state in which §6.4.1 sends every liquidation remainder to the DEFICIT path, which feeds the DEFICIT shutdown trigger (§6.11.1) — §6.4.4's statement that this is only reachable when the last position is liquidated is therefore false. Consequences: (i) reward misallocation of up to `1/stake` of a member's share of each later redistribution (confirmed); (ii) I13's derived bound (CHG-008) becomes weak, a relative tolerance of up to about `1/stake` (confirmed); (iii) a remainder recorded as deficit while positions are open, and a possible induced DEFICIT shutdown (state reached in the harness; not yet shown end to end with a real `liquidate`). The harness overstates the natural rate (it redistributes any position, without ICR < MCR or an empty pool). Rough attacker cost (float model, now committed as `scripts/analysis/stake_collapse_cost.py`, assumptions in its docstring; each round: open an own position at MCR, let interest take it below MCR, liquidate it into an empty pool, redeem the redistributed debt back out of honest positions, which re-stakes them at the lower ratio): with honest collateral `F` present, the cheapest schedule loses ≈ 5× `F` to reach 1,000-wei stakes on 1 WETH (~3·10⁴ liquidations) and ≈ 9× `F` to reach zero stakes (~6·10⁴ liquidations); faster schedules cost 15–170× `F` (redemption fees and the penalty left behind dominate). With no honest stake (an empty or young deployment, or one where the attacker holds all positions) the penalty and rewards return to the attacker: gas only, ~10 liquidations with capital ≈ 100× the minimum position, recovered. In real money, zero on a testnet. Decide: (a) measure with P20's real `liquidate` (regression of the zero-total state, end-to-end deficit path); (b) whether to change the protocol, e.g. reset or rescale the snapshots when the ratio falls below a threshold, or treat `totalStakes == 0` with open positions as a distinct case (spec change through `/spec-change`, which would also change I13's derivation); (c) correct §6.4.4 in any case. **Added by the P17 review (F4), both worse than the above:** (d) snapshots are reset only inside a liquidation, so a collapsed ratio survives even a full exit — every later position is staked 0 until a liquidation resets it, and that liquidation itself takes the DEFICIT path ("nothing restores it short of a deficit"); (e) after a DEFICIT-path reset, surviving positions keep stake 0 while new ones are staked 1:1, so survivors take no redistributed debt until they touch their position (bad debt lands only on newcomers), and debt-heavy redistributions then move only the newcomers' NICR — order inversions of any size, not rounding, which a spec-compliant P20 would fail in I13. The harness cannot reach (e): it never runs §6.4.1's DEFICIT branch. Options the review adds for (b): reset or rescale the snapshots also when `activeCount == 0` or below a ratio threshold, or restake survivors lazily. | human | before P20 |
| P17-2 | **Closed 2026-10-26:** CHG-009 approved and applied to `docs/invariants.md` I13 and spec §6.3.3; ADR-0034 accepted; the core handler asserts the hidden-key bound and no longer CHG-008's. | — | done |
| P18-1 | **Closed 2026-10-26:** ADR-0035 (blueprints) accepted and implemented at P19 (`9551f6d`; the real pool in A from its blueprint, `2ece808`). Base Sepolia's 2^24 per-transaction cap is unproven (`just sepolia-gas-cap`), so it is treated as binding; the factory transaction is ≈ 10.2M gas with the pool, guarded by `test_factory_initcodeAndGasWithinLimits`. | — | done |
| P18-2 | **Partly done: deployment A uses the real StabilityPool since P19; B keeps `StandInStrategy` until P33.** **Stand-ins to replace (same category as P16-F5 and P17-H2).** `StandInStrategy` (by P19's StabilityPool in A and P33's DutchAuctionHouse in B), `StandInDeficitLedger` (P21) and `StandInShutdownModule` (the ShutdownModule prompt). Each replacement must update `BagehotFactory`, extend `DeploymentChecks` (the new contract's peers, immutables and parameters; constraint 2 once `LIQUIDATION_PENALTY` lives on-chain), and re-run the smoke test. `Deploy.s.sol`, the factory and the stand-ins refuse every chain but 31337 until no stand-in is left. `StandInStrategy` has no `onLiquidation`: once P20 adds liquidation, liquidations in a local deployment revert until P19 (A) and P33 (B) replace it, so P20 must test against the real strategy contracts or a liquidation-capable test double, not this stand-in. | Claude | P19, P21, ShutdownModule prompt, P33 |
| CHG-010 / CHG-011 / CHG-013 | **Approved by the human 2026-10-26.** Code and model applied (`4c11d6b`); the spec and invariant texts await the protected-paths unlock (the file still lists them). | human (unlock) | — |
| CHG-014 | **Proposed (P20-L1):** `liquidate` checks that the WETH the strategy reports returning arrived (`CollReturnedNotReceived`). | human | no |
| CHG-015 | **Proposed (P20-L2, P20-I2):** spec wording — the no-stakes path needs no stake left, not no position left; the view window during `onLiquidation` in §5.10. | human | no |
| P19-A | **Spec-audit lows (P19), for the next `/spec-change` batch:** §4.4's `depositorCount[e]` definition is false for past epochs (the §5.3 pseudocode, which code follows, never decrements an old epoch); invariants.md names checks that do not exist yet (Halmos `check_I3_proRataSumBounded`, `check_I8_proRataSumBounded`; Python `check_I13`); the I1 "Checked in" line names `invariant_I1_holderBalances` for the pool row (it is `invariant_I1_poolHolder` / `invariant_I3_poolSolvencyAndU4`); the T-24 matrix omits `redeem` (same `_accrue`); the model raises `ValueError("InvalidParameter")` without an index (as every model module does). | Claude (with the human for spec text) | no |
| P18-3 | **Closed 2026-10-25.** The recipes pass `GIT_COMMIT=$(git describe --always --dirty --abbrev=12)` and `BAGEHOT_SOLC` (read from `foundry.toml`). `Deploy.checkProvenance` refuses a dirty tree or an unknown commit on every chain but 31337, and any compiler mismatch everywhere, and the manifest records both (5 tests). `deploy-local` and `smoke` take a variant (`just deploy-local B`, `just smoke <rpc> B`); both variants were deployed and smoke-tested on a fresh anvil. (An earlier note was wrong: the recipe line references `{{ANVIL_KEY0}}` and never contained the key, which is defined once at the top of the justfile.) | — | — |
| P08-2 | `.gitleaks.toml` gained a value-only allowlist for public EVM addresses (`^0x[0-9a-fA-F]{40}$`): Aave's `a_token`/`v_token` keys in `config/8453.toml` tripped `generic-api-key`. A first version also allowlisted the `config/` path; a probe showed it hid a 64-hex private key there, so it was removed before anything was pushed. Probes confirm a 0x+64-hex key, a `private_key`, and a bare 40-hex token are still caught. The original slip: the scan and the commit were chained with `;`, so the commit ran despite the findings — scans now gate commits with `&&`. | Claude | no |
| P02-4 | No vector exercises `redeem`'s `AuctionCallbackActive` branch (D-27, §6.7.2): the recorder cannot drive a buyer callback. Foundry test added at P16 (`RedemptionAuctionCallbackTest`, mock house); against the real house at P33; model test at P22. | Claude | at P22/P33 |
| P02-3 | The vector reference implementation is throwaway (scratchpad). Vectors are validated independently from P10 (Foundry) and P22 (Python model); a vector that disagrees with both implementations is a spec question for `/spec-change`. | Claude | at P10/P22 |
| P01-8 | The repository is public, so all seven commits expose the author email `ka.koszewski@gmail.com` permanently. Four of them are also authored `H3BCKN`. Neither can be changed without a force push, which the permission rules forbid. If this matters, GitHub's `noreply` address plus `git config user.email` fixes it for future commits. | human | no |

## Human actions required

<!-- things only the human can do: approvals, secrets, broadcasts -->

| # | action | why |
|---|---|---|
| 1 | `chmod +x .claude/hooks/*.py` | The three hooks are mode 644. They work as configured (invoked as `python3 <path>`), so nothing is broken, but P00 asks that they be executable. `.claude/hooks/**` is protected from edits, so this one is yours. |
| 2 | ~~`mkdir -p deployments data/raw data/processed && touch deployments/.gitkeep`~~ | `deployments/` done by the human 2026-10-25 (P18). `data/raw` and `data/processed`: see open issue P00-3. |
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
| 12 | Re-protect `docs/spec.md`, `spec/vectors/**` and `docs/invariants.md` (uncomment lines 7, 8, 10 of `.claude/protected-paths.txt`) once CHG-010 and CHG-011 are decided; add `docs/adr/0034-*.md` and `docs/adr/0035-*.md` (accepted 2026-10-26) | Unlocked for P19 by the human; Claude cannot edit the protected-paths file. |
| 13 | ~~Decide P17-1 and P17-2~~ — done 2026-10-26 (P17-1 accepted as residual risk T-25; CHG-009 approved). Now: decide CHG-010, P19-L1, CHG-011 and the P20 plan's questions | Before P20 |
