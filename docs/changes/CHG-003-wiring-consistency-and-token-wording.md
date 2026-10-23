# CHG-003: Require the wired peer graph to agree; state StableToken's lock and events exactly

- Status: proposed (awaiting human review)
- Raised: 2026-10-23, P11 (security-reviewer findings F-3, F-5, F-6)
- Affects: `docs/spec.md` §3.3 (new constraint 8), §2.5 / §5.10 (one sentence), §11.1 (StableToken
  row). No formula, rounding or algorithm changes; no vector changes.

## Problem

Three places where the spec is silent or inexact about what P11 built.

1. **Nothing requires the wiring of different contracts to agree** (§3.3). Constraint 7 covers only
   the `auctionHouse` argument. `StableToken.wire(vaultManager, strategy, …)` is not checked against
   the strategy passed to `VaultManager.wire` or `DeficitLedger.wire`, nor against the VaultManager
   whose immutable `token` is this token. Each `wire` rejects only `address(0)`.
2. **§2.5 says "every contract that holds or moves tokens" takes a reentrancy lock**, and §5.10 never
   exempts StableToken. Read literally, StableToken needs a lock; it has none, correctly — it makes no
   external call (OZ 5.7 `ERC20._update` has no hooks), so nothing can re-enter it.
3. **§11.1 says StableToken emits "ERC-20 `Transfer`, plus nothing else".** It also emits `Wired`
   (the "all" row says so) and OZ `Approval`. I14 rebuilds state from events, and the indexer reads
   this table.

## Evidence

- Item 1, two sequences (security review, P11):
  (a) the deployer wires the VaultManager to pool *X* and the token to an older pool build *Y* —
  every `onLiquidation` that calls `moveFrom`/`burnFrom` reverts `Unauthorized`, liquidations are
  dead and the deployment must be discarded;
  (b) a role set to an EOA (e.g. `vaultManager_ = deployer`) is a permanent unbacked-mint key —
  breaks I2 and `CLAUDE.md`'s "no admin" rule. `wire` accepts both because only zero is rejected.
  `StableTokenTest.test_wire_duplicateAddressesGiveTheUnionOfRoles` documents that repeated
  addresses are accepted today.
- Item 2: `StableToken.sol` has no external call; reviewer concurs.
- Item 3: `forge inspect StableToken events` lists `Transfer`, `Approval`, `Wired`.

## Options

1. **Spec wording plus a deploy-script constraint** (recommended).
   - §3.3 gains constraint 8: *"Every address passed to a `wire` is the contract the factory created
     for that role, and the graph agrees: each contract's wired peers are the same addresses every
     other contract was wired with for that role, and every contract's immutable `token`, `weth` and
     `oracle` are the deployment's. Enforced only by the deployment script (before broadcast) and the
     post-deploy smoke test, which also asserts `deployer() == factory` and `wired()` for every
     contract in the deployment transaction's receipt."* Added to the "enforced only by the
     deployment script" sentence.
   - §2.5, after the lock sentence: *"StableToken makes no external call and takes no lock; §5.10
     lists no path into it that could re-enter."*
   - §11.1 StableToken row: *"ERC-20 `Transfer` and `Approval`, and `Wired`; mint/burn appear as
     `Transfer` from/to `address(0)`."*
   Consequences: documentation and a P18 obligation; no contract change.
2. **Option 1 plus on-chain hardening:** `_requireNonZero` also requires `a.code.length != 0`,
   which rules out an EOA role (sequence b) on-chain. It works inside a factory, because children
   created with `new` have code by the time the factory calls `wire`. Consequences: one `EXTCODESIZE`
   per wired address at deployment only; a new revert case under `InvalidParameter`; every wire test
   needs contract addresses rather than constants. Does not catch sequence (a) — only the
   deploy-script graph check does.
3. **Leave the spec as is.** Item 1 then rests on P18 remembering it unprompted; items 2–3 remain
   literal mismatches a spec audit will flag at every stage boundary.

## Recommendation

Option 1. The graph check belongs in the deploy script, which is the only place that sees every
contract's arguments; option 2's code check is cheap but covers only half the problem and changes
the `wire` contract of eight contracts for a deployment-time mistake the script already catches.

## Impact

| Area | Impact |
|---|---|
| `docs/spec.md` | §3.3 constraint 8; one sentence in §2.5; §11.1 StableToken row (protected file) |
| `docs/invariants.md` | none — I11 already alerts on any `Wired` after the first |
| `spec/vectors/` | none |
| Solidity | none for option 1 (option 2: `Wired.sol` `_requireNonZero`) |
| Python model | none |
| Differential | none |
| Deploy script (P18) | asserts constraint 8 before broadcast and in the smoke test |
| Experiments, preregistration | none |
| ADR | short ADR after approval, referencing this file |
