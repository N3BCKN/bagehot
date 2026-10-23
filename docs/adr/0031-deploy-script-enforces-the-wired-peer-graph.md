# ADR-0031: The deployment script enforces that the wired peer graph agrees

- Status: proposed
- Date: 2026-10-23
- Prompt: P11 (found by the security review), applied via `/spec-change` CHG-003
- Supersedes: —

## Context

Each contract's one-shot `wire` (ADR-0021) checks only that its own arguments are non-zero. Nothing
on-chain checks that the contracts were wired to *each other* consistently: `StableToken.wire` does
not know which strategy `VaultManager.wire` received, and no contract knows whether a role address
is the contract the factory created. Two failure modes follow, both found in the P11 security
review:

- a token wired to a different strategy than the VaultManager (e.g. an older pool build) makes every
  `onLiquidation` that calls `moveFrom`/`burnFrom` revert `Unauthorized` — **all liquidations dead**,
  and the deployment must be discarded;
- a role set to an externally owned account (e.g. `vaultManager_ = deployer`) is a **permanent
  unbacked-mint key**, breaking I2 and the "no admin" rule.

Spec §3.3 constraint 7 covered only the `auctionHouse` argument. The same review found two wording
mismatches: §2.5's lock rule read as if it covered StableToken (which makes no external call and has
no lock), and §11.1 listed only `Transfer` for StableToken although it also emits `Approval` and
`Wired`. Full text: `docs/changes/CHG-003-wiring-consistency-and-token-wording.md`.

## Decision

- Spec §3.3 gains **constraint 8**: every address passed to a `wire` is the contract the factory
  created for that role; each contract's wired peers equal those every other contract was wired with
  for that role; every contract's immutable `token`, `weth` and `oracle` are the deployment's.
  Enforced by the deployment script before broadcasting, and again by the post-deploy smoke test,
  which also asserts `deployer() == factory` and `wired()` for every contract in the deployment
  transaction's receipt.
- §2.5 states that StableToken makes no external call and takes no lock.
- §11.1's StableToken row lists `Transfer`, `Approval` and `Wired`.
- No contract changes: the check is not added on-chain (`code.length != 0` in `_requireNonZero` was
  considered and not chosen, below).

## Consequences

- P18's deploy script and smoke test carry these assertions as a named acceptance criterion of P18
  itself (the human's condition at approval), not as a carried-over note.
- A mis-wired deployment fails before broadcast, or at the latest in the smoke test, instead of
  surfacing as dead liquidations or an unbacked-mint key.
- On-chain, a mis-wired deployment remains possible if the script is bypassed; the protocol's
  guarantee therefore depends on deploying only through the scripted factory (ADR-0019, ADR-0021).
- The spec now matches StableToken's code and events, so spec audits stop flagging them.

## Alternatives considered

- **Also require `code.length != 0` for every wired address on-chain.** Not chosen: it rules out an
  EOA role but not a token wired to the wrong contract (the dead-liquidations case), so the
  deploy-script graph check is needed anyway; it would change the `wire` of all eight wired
  contracts and every wiring test for half of the protection.
- **Leave the spec as is.** Rejected: the graph check would rest on P18 remembering it, and the two
  wording mismatches would be flagged at every stage boundary.
