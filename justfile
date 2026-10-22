# Bagehot command vocabulary. Recipes referenced by CLAUDE.md, skills and prompts.
# P00 completes and verifies every recipe; later prompts may add recipes but never rename these.
# Recipes whose inputs arrive in a later stage guard themselves and say which prompt adds them.
set dotenv-load := true
set shell := ["bash", "-euo", "pipefail", "-c"]

ANVIL_KEY0 := "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # public anvil test key
MEDUSA := justfile_directory() / ".tools/medusa"  # pinned binary, see docs/dependencies.md

default: check

fmt:
    cd contracts && forge fmt
    uv run ruff format .

# fmt-check is unchanged in behaviour; the two halves exist so CI can run the Solidity check in
# the contracts job and the Python check in the python job without duplicating the commands.
fmt-check: fmt-check-sol fmt-check-py

fmt-check-sol:
    cd contracts && forge fmt --check

fmt-check-py:
    uv run ruff format --check .
    uv run ruff check .

build:
    cd contracts && forge build --sizes

test:
    cd contracts && forge test

test-nightly:
    @compgen -G "contracts/test/invariant/*.t.sol" >/dev/null \
      || { echo "no invariant tests yet — added at P17"; exit 1; }
    cd contracts && FOUNDRY_PROFILE=nightly forge test --match-path "test/invariant/*"

medusa:
    @test -f contracts/medusa.json \
      || { echo "contracts/medusa.json missing — added at P17"; exit 1; }
    @test -x "{{MEDUSA}}" \
      || { echo "medusa not found at {{MEDUSA}} — see docs/dependencies.md"; exit 1; }
    cd contracts && "{{MEDUSA}}" fuzz --config medusa.json

halmos:
    @compgen -G "contracts/test/symbolic/*.sol" >/dev/null \
      || { echo "no symbolic tests yet — added at P17"; exit 1; }
    cd contracts && halmos --match-contract Symbolic

# --foundry-compile-all: without it crytic-compile builds only src/, which produces no build-info
# while src/ is still empty. It also brings script/ into scope; test/, lib/ and src/mocks/ are
# dropped from the report by slither.config.json. aderyn needs at least one contract in src/.
# --fail-none: the exit code is not the gate — scripts/check_triage.py is, and it is stricter,
# failing on a finding of ANY severity that has no row in docs/static-analysis-triage.md.
static:
    mkdir -p reports/static
    cd contracts && slither . --config-file slither.config.json --foundry-compile-all \
      --fail-none --json ../reports/static/slither.json
    python3 scripts/check_triage.py reports/static/slither.json docs/static-analysis-triage.md
    @if [ -n "$(find contracts/src -name '*.sol' -print -quit)" ]; then \
        cd contracts && aderyn . --path-excludes src/mocks --output ../reports/static/aderyn.md; \
      else \
        echo "aderyn skipped: contracts/src/ holds no contracts yet — first one lands at P10"; \
      fi

coverage:
    cd contracts && forge coverage --report summary --no-match-path "test/fork/*"

gas:
    @test -f contracts/.gas-snapshot \
      || { echo "no gas snapshot yet — create one with 'just gas-update' (baseline at P37)"; exit 1; }
    cd contracts && forge snapshot --check

gas-update:
    cd contracts && forge snapshot

# `fork` is excluded here as well as `slow` and `network`: fork tests need a local anvil fork of
# Base and BASE_ARCHIVE_RPC, neither of which the quick loop or CI has. Same filter as CI.
py-test:
    uv run pytest -q -m "not slow and not network and not fork"

diff-quick:
    @compgen -G "differential/*.py" >/dev/null \
      || { echo "differential/ is empty — added at P23"; exit 1; }
    uv run pytest differential -q --hypothesis-profile=quick

diff-long:
    @compgen -G "differential/*.py" >/dev/null \
      || { echo "differential/ is empty — added at P23"; exit 1; }
    uv run pytest differential -q --hypothesis-profile=nightly

# P07: Chainlink ETH/USD and sequencer-uptime history on Base. BASE_ARCHIVE_RPC comes from the
# dotenv file loaded above and is never printed. `just oracle --dry-run` prints the budget only.
oracle *ARGS:
    uv run python -m data.fetch_oracle {{ARGS}}

data:
    @test -f data/fetch_all.py || { echo "data/fetch_all.py missing — added at P06"; exit 1; }
    uv run python -m data.fetch_all
    uv run python -m data.validate

calibrate:
    @test -f experiments/calibrate.py \
      || { echo "experiments/calibrate.py missing — added at P27"; exit 1; }
    uv run python -m experiments.calibrate

sweep scenario:
    @test -f experiments/sweep.py \
      || { echo "experiments/sweep.py missing — added at P29"; exit 1; }
    @test -f experiments/configs/{{scenario}}.yaml \
      || { echo "experiments/configs/{{scenario}}.yaml missing — scenarios are S1..S9"; exit 1; }
    uv run python -m experiments.sweep --config experiments/configs/{{scenario}}.yaml

report:
    @test -f experiments/report.py \
      || { echo "experiments/report.py missing — added at P32"; exit 1; }
    uv run python -m experiments.report

check: fmt-check build test py-test
    @if compgen -G "differential/*.py" >/dev/null; then just diff-quick; fi

anvil:
    anvil --chain-id 31337 --block-time 2

fork block:
    @test -n "${BASE_ARCHIVE_RPC:-}" \
      || { echo "BASE_ARCHIVE_RPC is not set — copy env.example to .env and fill it in"; exit 1; }
    anvil --fork-url "$BASE_ARCHIVE_RPC" --fork-block-number {{block}} --chain-id 8453 --port 8546

deploy-local:
    @test -f contracts/script/Deploy.s.sol \
      || { echo "contracts/script/Deploy.s.sol missing — added at P18"; exit 1; }
    cd contracts && GIT_COMMIT=$(git rev-parse --short HEAD) forge script script/Deploy.s.sol:Deploy \
      --rpc-url http://127.0.0.1:8545 --private-key {{ANVIL_KEY0}} --broadcast

deploy-fork:
    @test -f contracts/script/DeployFork.s.sol \
      || { echo "contracts/script/DeployFork.s.sol missing — added at P39"; exit 1; }
    cd contracts && BAGEHOT_FORK=1 GIT_COMMIT=$(git rev-parse --short HEAD) forge script \
      script/DeployFork.s.sol:DeployFork --rpc-url http://127.0.0.1:8546 --private-key {{ANVIL_KEY0}} --broadcast

# Simulation only: no keystore unlock, no broadcast. The human runs the real broadcast (see /deploy).
deploy-sepolia-dry:
    @test -f contracts/script/Deploy.s.sol \
      || { echo "contracts/script/Deploy.s.sol missing — added at P18"; exit 1; }
    @test -n "${DEPLOYER_ADDRESS:-}" \
      || { echo "DEPLOYER_ADDRESS is not set — copy env.example to .env and fill it in"; exit 1; }
    cd contracts && GIT_COMMIT=$(git rev-parse --short HEAD) forge script script/Deploy.s.sol:Deploy \
      --rpc-url base_sepolia --sender "$DEPLOYER_ADDRESS"

smoke rpc:
    @test -f contracts/script/SmokeTest.s.sol \
      || { echo "contracts/script/SmokeTest.s.sol missing — added at P18"; exit 1; }
    @test -n "${DEPLOYER_ADDRESS:-}" \
      || { echo "DEPLOYER_ADDRESS is not set — copy env.example to .env and fill it in"; exit 1; }
    cd contracts && forge script script/SmokeTest.s.sol:SmokeTest --rpc-url {{rpc}} --sender "$DEPLOYER_ADDRESS"
