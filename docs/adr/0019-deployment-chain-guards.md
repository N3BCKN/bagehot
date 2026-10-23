# ADR-0019: Guard the deployment chain ids and use keystore accounts only

- Status: accepted 2026-10-23 (P04 human gate)
- Date: 2026-10-22
- Prompt: P04
- Supersedes: —

## Context

Blueprint §15 and the project's hard rules. The study broadcasts transactions in three places:
local anvil, a localhost fork of Base, and the Base Sepolia demonstration (P42). A mistyped RPC
URL is enough to send a deployment somewhere it does not belong, and a research protocol with no
external audit must never appear on a mainnet, even harmlessly.

The second risk is credential handling. A raw signing key passed through an environment variable
ends up in shell history, process listings, CI logs and stray backups.

## Decision

Every deploy and broadcast script asserts `block.chainid` before it sends anything: 31337 (anvil,
including a localhost fork of Base) and 84532 (Base Sepolia) are allowed; 8453 is allowed **only**
when the RPC endpoint is localhost, i.e. a fork; everything else aborts. Base mainnet and Ethereum
mainnet are read-only sources of data.

Signing uses a Foundry keystore account (`--account <name>`) and nothing else. No script, test,
justfile recipe or CI job reads a raw signing key, and only the human types the password. Claude
never reads, prints, copies or writes keys, keystores, mnemonics or the local environment file
(`CLAUDE.md`); a pre-tool hook blocks shell commands that would, and the secret scanner runs over
the diff and the working tree on every PR (P01).

## Alternatives considered

- **Trust the RPC URL.** One typo away from a mainnet deployment, with no second line of defence.
- **A raw key in the environment.** Convenient, and the single most common way test credentials
  leak; it also makes every CI job a potential exfiltration point.

## Consequences

- A fork run needs anvil started against an archive RPC; the chain-id guard then sees 31337, or
  8453 with a localhost endpoint.
- Deployment manifests in `deployments/` record chain id, block and commit, and are written only
  by the scripts.
- The testnet signing account holds a minimal balance and has no other role in the system; because
  there are no admin roles (ADR-0009), losing it costs nothing but a redeployment.
