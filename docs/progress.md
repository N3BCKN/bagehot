# Progress

Claude updates this file at the end of every session. Status: todo · in progress · done · blocked.

| Prompt | Title | Status | Commit | Notes |
|---|---|---|---|---|
| P00 | Repository bootstrap and toolchain | done | a4e5b1d | `just check` and `just static` green; all toolchains pinned; hooks verified |
| P01 | Continuous integration | done | c47245f | PR [#1](https://github.com/N3BCKN/bagehot/pull/1), run [39670041216](https://github.com/N3BCKN/bagehot/actions/runs/39670041216) green: 5 jobs pass, `differential (quick)` skipped as designed |
| P02 | Protocol specification (human gate) | todo | | |
| P03 | Invariants (human gate) | todo | | |
| P04 | ADRs and threat model skeleton | todo | | |
| P05 | Preregistration draft | todo | | |
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
