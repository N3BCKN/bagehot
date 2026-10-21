---
name: deploy
description: Deployment runbook for local anvil, Base mainnet fork, and Base Sepolia (Sepolia broadcast is executed by the human). Only when the user invokes it.
disable-model-invocation: true
argument-hint: "[local|fork <block>|sepolia]"
---
Target: $ARGUMENTS

Pre-flight (all targets): git tree clean; `just check` green; `config/<chainId>.toml` reviewed —
every external address has a source URL and retrieval date; deploy script chain guard present.

local:
1. `just anvil` in a background terminal (ask the human to start it if needed).
2. `just deploy-local`; confirm `deployments/31337.json` was written by the script.
3. `just smoke http://127.0.0.1:8545`.

fork <block>:
1. Confirm `BASE_ARCHIVE_RPC` exists without reading it (ask the human).
2. `just fork <block>` (port 8546), then `just deploy-fork`.
3. Fund test accounts only via `cast rpc anvil_setBalance` and `WETH.deposit()` on the fork.
4. Run the requested scenario script; save results under `reports/fork/<block>/`.

sepolia (the human broadcasts):
1. `just deploy-sepolia-dry` — simulation only. Show the planned transactions, addresses,
   gas estimate and parameters.
2. Hand the human the exact command:
   `cd contracts && GIT_COMMIT=$(git rev-parse --short HEAD) forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --account bagehot-deployer --broadcast --verify`
3. After the human confirms success: check the manifest, verification status on the explorer,
   then `just smoke base_sepolia`.
4. Update README addresses and `docs/progress.md`.

Never use --private-key outside localhost. Never read keystores or .env.
