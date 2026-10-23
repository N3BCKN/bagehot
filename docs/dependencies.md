# Dependencies

Every tool and library is pinned to an exact version. Nothing is added or upgraded without the
human's approval; an upgrade means a new row here with the reason and a re-run of `just check`.

Host used for the versions below: macOS 15 (darwin 25.5.0), arm64. Verified on 2026-10-21.

## Solidity toolchain

| Tool | Version | Why | Install |
|---|---|---|---|
| foundry (forge, cast, anvil, chisel) | `1.8.1` (`982849d3140c01fd3b72905759581a132df7aa98`) | Compile, test, fuzz, fork, script, deploy. Blueprint §18.1. | `foundryup --install 1.8.1` (pre-existing on this host) |
| solc | `0.8.28` | Pinned in `contracts/foundry.toml`. Cancun-era, transient storage for `ReentrancyGuardTransient`, long tool-soak time. ADR-018 at P04. | downloaded by forge on first build |
| forge-std | `v1.17.0` (`f3dae6e6ee381f25eb6a246f7da9b85c91a68219`) | Test harness, cheatcodes, `vm.readFile`/`parseJson` for `spec/vectors/`. | `forge install foundry-rs/forge-std@v1.17.0` |
| OpenZeppelin Contracts | `v5.7.0` (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) | ERC20, SafeERC20, `Math.mulDiv` with explicit rounding, `ReentrancyGuardTransient`. Blueprint §18.1. | `forge install OpenZeppelin/openzeppelin-contracts@v5.7.0` |

Both libraries are git submodules under `contracts/lib/`, so the commit hash above is what `git`
records — the pin cannot drift.

## Analysis and verification

| Tool | Version | Why | Install |
|---|---|---|---|
| slither-analyzer | `0.11.6` | Static analysis, `just static`. Findings triaged in `static-analysis-triage.md`. | `uv tool install slither-analyzer==0.11.6` |
| aderyn | `0.6.8` | Second static analyser, different detector set. | pre-existing on this host (`cyfrinup`) |
| halmos | `0.3.3` | Symbolic proofs of simple properties, `just halmos`. | `uv tool install halmos==0.3.3` |
| bitwuzla | `0.8.1` (macOS arm64 sha256 `f603ff433151cb9f3929a9810a41405bfa57ffaa184fa736a38c32b64a3a9021`) | SMT solver for halmos. The two solvers bundled with halmos 0.3.3 (yices, z3) time out on every rounding proof at 128, 64 and 16 bits (P10-1); bitwuzla is halmos's recommended bit-vector solver. Approved by the human at P10 for a timeboxed attempt. Pinned and checksum-verified by halmos itself. | `HALMOS_ALLOW_DOWNLOAD=1 halmos --solver bitwuzla-0.8.1` (downloads once into halmos's cache) |
| medusa | `1.5.1` | Stateful fuzzing alongside the Foundry invariant runner, `just medusa`. | pinned release binary, see below |

### medusa

No Go toolchain on this host and no global install, so the official release binary is used
directly. `just medusa` references it through the `MEDUSA` variable in the `justfile`.

```
curl -fsSL -o medusa-mac-arm64.tar.gz \
  https://github.com/crytic/medusa/releases/download/v1.5.1/medusa-mac-arm64.tar.gz
shasum -a 256 medusa-mac-arm64.tar.gz
# a8b38bbd07a60f51e1b96304db58dba441b5053d7a61d1749458f3f7eaf5d3ce
tar -xzf medusa-mac-arm64.tar.gz -C .tools medusa && chmod +x .tools/medusa
```

`.tools/` is git-ignored: the binary is platform-specific, so each machine re-runs the snippet
above. Reproducing on another platform means the matching asset from the same `v1.5.1` tag.

## Python

| Tool | Version | Why | Install |
|---|---|---|---|
| uv | `0.11.26` | Environment and lock management. Blueprint §18.2. | pre-existing on this host (Homebrew) |
| CPython | `3.12.13` | Pinned by `.python-version`; `requires-python = ">=3.12,<3.13"`. | `uv python install 3.12` |

Runtime and dev dependencies are pinned with `==` in `pyproject.toml` and resolved transitively in
the committed `uv.lock`. Reproduce with `uv sync --locked`.

| Package | Version | Why |
|---|---|---|
| numpy | `2.2.6` | Exact-integer-adjacent array work in agents and statistics |
| pandas | `2.2.3` | Data frames for the pipeline and sweeps |
| pyarrow | `18.1.0` | Parquet storage for `data/processed/` |
| scipy | `1.15.3` | Statistics for calibration and the report |
| arch | `7.2.0` | Stationary and block bootstrap for the price-path generator |
| web3 | `7.8.0` | Driving anvil, forks, the bot and the differential harness |
| eth-abi | `5.2.0` | ABI encode/decode outside web3's high-level API |
| httpx | `0.28.1` | Data fetching (Dune, archive RPC) |
| pyyaml | `6.0.2` | `experiments/configs/S*.yaml` |
| pydantic | `2.10.6` | Validating configs and data cards |
| matplotlib | `3.10.0` | Report figures |
| psycopg[binary] | `3.2.4` | Indexer against PostgreSQL |
| pytest | `8.3.4` | Test runner; markers `slow`, `network`, `fork` |
| hypothesis | `6.125.1` | Property and stateful tests, differential harness |
| ruff | `0.9.6` | Lint and format; line length 100, `E,F,I,B,UP,SIM` |

## Other

| Tool | Version | Why | Install |
|---|---|---|---|
| just | `1.59.0` | Command vocabulary (`justfile`). Blueprint §18.3. | `uv tool install rust-just==1.59.0` |

`rust-just` is the PyPI distribution of the same `casey/just` release, chosen over Homebrew so the
version is pinned exactly and installs without a global change.

## CI (P01)

Local copies of the two tools CI runs, so a workflow can be validated before it is pushed. Both
are release binaries in the git-ignored `.tools/`, verified against the publisher's checksum file.

| Tool | Version | Why | Install |
|---|---|---|---|
| actionlint | `1.7.12` | Lints the GitHub workflows (shellcheck of `run:` blocks, expression and context errors). `.tools/actionlint .github/workflows/*.yml` | release binary, `actionlint_1.7.12_darwin_arm64.tar.gz`, sha256 `aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f` |
| gitleaks | `8.30.1` | Secret scanning, the `secrets` job. Configured by `.gitleaks.toml`. | release binary, `gitleaks_8.30.1_darwin_arm64.tar.gz`, sha256 `b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5` |

The workflows install the Linux builds of the same versions and verify these checksums:

| Asset | sha256 |
|---|---|
| `gitleaks_8.30.1_linux_x64.tar.gz` | `551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb` |
| `aderyn-x86_64-unknown-linux-gnu.tar.xz` (tag `aderyn-v0.6.8`) | `ffd6ca658962e211a3ac821c646f69c8e14bf1b1001cbfe091bcd4535a691e46` |
| `medusa-linux-x64.tar.gz` (tag `v1.5.1`) | `ddfe1517ae9028ef9fc331b00f5a6a9d5406f3fcd11a715d60c6b6fb3e4546d3` |

`gitleaks-action` is deliberately **not** used: it wants a `GITLEAKS_LICENSE` secret for
organisation repositories and write permissions to comment on pull requests. The PR workflow
carries no secrets and is `contents: read`, so it runs the binary directly.

### Pinned GitHub Actions

Every third-party action is pinned by full commit SHA, with the version in a trailing comment.
Verify them against the upstream tags before bumping; a tag can be moved, a SHA cannot.

| Action | Version | SHA |
|---|---|---|
| `actions/checkout` | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/cache` | `v6.1.0` | `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` |
| `actions/upload-artifact` | `v7.0.2` | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| `actions/download-artifact` | `v8.0.2` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| `astral-sh/setup-uv` | `v10.3.0` | `1c37ad07a6a961277cf70c0d37d6f313000f5884` |
| `foundry-rs/foundry-toolchain` | `v1.9.1` | `908c540300062bd5a7e473851cdb4282204cee09` |

The `foundry-toolchain` action's own version is `v1.9.1`; the Foundry release it installs is
pinned separately to `v1.8.1` by the `FOUNDRY_VERSION` workflow variable, to match the table at
the top of this file.

## Not installed

| Tool | Status |
|---|---|
| Echidna | Optional in blueprint §18.1; medusa covers the same ground. Not installed. |
| Certora | Optional in blueprint §18.1; out of scope for this project. |
| Docker Compose | Optional in blueprint §18.3; revisit at P41 if the indexer needs PostgreSQL. |
| Go | Not needed — medusa is installed as a release binary. |
