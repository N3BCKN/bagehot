# Bagehot

A testnet-only, research-grade CDP protocol: a USD-pegged stablecoin, WETH as the only collateral,
a fixed interest rate, and two interchangeable liquidation strategies — a stability pool
(deployment A) and a Dutch auction (deployment B).

The point is not the protocol. The point is to derive risk parameters from data and compare the
two liquidation mechanisms under identical conditions, with the hypotheses written down before the
first sweep runs. **The product is a reproducible report; the contracts are its vehicle.**

> ⚠️ **This will never hold real funds.** Deployments are limited to local anvil, local forks of
> Base, and Base Sepolia (84532). Base mainnet and Ethereum mainnet are read-only. There are no
> owners, admin roles, setters, pausers, proxies or upgradeability — every parameter is an
> immutable constructor argument.

## Quickstart

Requires the toolchain in [docs/dependencies.md](docs/dependencies.md), all pinned to exact
versions.

```bash
uv sync --locked          # Python 3.12 environment from the committed lock
just check                # format check, build, Solidity tests, Python tests
just static               # slither + aderyn
```

`just` with no arguments is `just check`. Run `just --list` for the full command vocabulary.

## Repository layout

| Path | What lives there |
|---|---|
| `contracts/` | Foundry project: `src/{core,liquidation,redemption,safety,lib,mocks}`, `test/`, `script/` |
| `spec/vectors/` | JSON test vectors shared by Foundry and pytest |
| `model/` | Python protocol model (exact integers) plus oracle, liquidity and cost models |
| `agents/`, `paths/` | Simulation agents and price-path generators |
| `experiments/` | Sweep runner, `configs/S1..S9.yaml`, calibration, report generation |
| `differential/` | Hypothesis state machine comparing the model against the contracts on anvil |
| `data/` | `fetch_*.py`, `validate.py`, `cards/` (committed); `raw/` and `processed/` are ignored |
| `bot/`, `indexer/` | Liquidation bot, event indexer with an invariant monitor |
| `config/` | Per-chain deployment configs (addresses with source URLs) |
| `deployments/` | Manifests, written by deploy scripts only |
| `docs/` | Spec, invariants, ADRs, preregistration, threat model, report drafts |

## Documents, in reading order

1. [docs/spec.md](docs/spec.md) — units, state, formulas, rounding, algorithms, permissions
2. [docs/invariants.md](docs/invariants.md) — I1–I14 with formulas, tolerances and their tests
3. [docs/adr/](docs/adr/) — decisions; changing one means a new ADR
4. [docs/preregistration.md](docs/preregistration.md) — frozen before the first sweep
5. [docs/progress.md](docs/progress.md) — status of every build prompt

If the code and the spec disagree, the spec wins.

## Reproducibility

Report numbers come only from scripts in `experiments/`. `reports/`, `data/processed/`,
`data/raw/` and `deployments/` are never hand-edited. Python dependencies are locked in `uv.lock`;
Solidity dependencies are git submodules pinned to release tags; the tool versions and their
checksums are in `docs/dependencies.md`.

## Licence

MIT — see [LICENSE](LICENSE).
