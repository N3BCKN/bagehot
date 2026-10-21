# Progress

Claude updates this file at the end of every session. Status: todo · in progress · done · blocked.

| Prompt | Title | Status | Commit | Notes |
|---|---|---|---|---|
| P00 | Repository bootstrap and toolchain | done | | `just check` and `just static` green; all toolchains pinned; hooks verified |
| P01 | Continuous integration | todo | | |
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

## Human actions required

<!-- things only the human can do: approvals, secrets, broadcasts -->

| # | action | why |
|---|---|---|
| 1 | `chmod +x .claude/hooks/*.py` | The three hooks are mode 644. They work as configured (invoked as `python3 <path>`), so nothing is broken, but P00 asks that they be executable. `.claude/hooks/**` is protected from edits, so this one is yours. |
| 2 | `mkdir -p deployments data/raw data/processed && touch deployments/.gitkeep` | See open issue P00-3. Both `mkdir`s were declined during the session. |
| 3 | Copy `env.example` to `.env` and fill it in | Claude never reads or creates `.env`. Needed from P06 (`BASE_ARCHIVE_RPC`) onwards; `just fork`, `just smoke` and `just deploy-sepolia-dry` already fail with a clear message without it. |
| 4 | Confirm the `LICENSE` copyright holder | Currently `Copyright (c) 2026 H3BCKN`, taken from the git identity on this machine. |
| 5 | Decide whether `docs/redoubt-blueprint-v0.2.pdf` should be renamed | `CLAUDE.md` refers to it as `docs/blueprint-v0.2.pdf`, and the PDF itself uses the working name "Redoubt". Left untouched: renaming a source of truth is not Claude's call. |
