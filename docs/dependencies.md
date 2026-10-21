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

## Not installed

| Tool | Status |
|---|---|
| Echidna | Optional in blueprint §18.1; medusa covers the same ground. Not installed. |
| Certora | Optional in blueprint §18.1; out of scope for this project. |
| Docker Compose | Optional in blueprint §18.3; revisit at P41 if the indexer needs PostgreSQL. |
| Go | Not needed — medusa is installed as a release binary. |
