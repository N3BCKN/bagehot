# ADR-0035: The factory creates every contract from pre-deployed blueprints, still in one transaction

- Status: proposed (direction approved by the human 2026-10-26; text awaiting acceptance)
- Date: 2026-10-26
- Prompt: P18 (open issue P18-1), before P19
- Supersedes: —

## Context

P18's `BagehotFactory` embeds the creation code of every contract it deploys, so its own initcode
grows with the protocol. Measured on anvil with local stand-ins for the strategy, DeficitLedger and
ShutdownModule:

- initcode 44,054 bytes against EIP-3860's 49,152;
- the deployment transaction used 8,785,491 gas for 35,513 bytes of runtime created (about 200 gas
  per deposited byte, 0.6M for the initcode as calldata, 0.29M for nine CREATEs, about 0.75M of
  constructor execution).

P19–P33 replace the stand-ins with StabilityPool, DutchAuctionHouse, DeficitLedger and
ShutdownModule. Embedding them breaks EIP-3860 at P19.

What the current design guarantees, and must keep:
- spec §3.3 constraint 8: every wired address is the contract the factory created for that role,
  checked together with `deployer() == factory` and `wired()` in the **deployment transaction's**
  receipt;
- ADR-0021's consequence that the inert, un-wired state cannot be exploited, which P18 strengthens
  to "no un-wired window at all" by creating and wiring in one constructor;
- P11-1: no `{salt:}`, and no caller-supplied **role** addresses.

Base Sepolia (`just sepolia-gas-cap`, read-only, 2026-10-26, around block 50,243,700):
- chain id 84532, block gas limit 120,000,000;
- `eth_call` with 16,777,216, 16,777,217 and 30,000,000 gas: all accepted;
- largest gas limit among transactions included in the last 1,000 blocks: 10,000,000.
This does not settle whether EIP-7825's 2²⁴ per-transaction cap is enforced: `eth_call` need not apply
it, and no included transaction exceeded it. Only broadcasting a transaction above 2²⁴ would settle
it, which needs the human's key. The design therefore treats 16,777,216 as binding.

## Decision

- Each contract's creation code is deployed beforehand as a **blueprint**: a data contract whose
  code is `0xFE ‖ creationCode` (EIP-5202 layout without its optional header). The leading invalid
  opcode makes a blueprint uncallable; it holds no state and no privilege.
- The factory takes the blueprint addresses as constructor arguments. Its constructor, for each
  role in a fixed order, copies the blueprint's code after the first byte with `EXTCODECOPY`,
  appends the ABI-encoded constructor arguments and calls `CREATE` — never `CREATE2`. It then makes
  every `wire` call, exactly as now. Creation and wiring stay in **one transaction**, and every
  wired contract's `deployer()` is the factory.
- The factory checks that each blueprint has code beginning with `0xFE`, and checks its `extcodehash`
  against a hash passed alongside it, reverting before any CREATE if one differs. The deploy script
  computes those hashes from the build artifacts, so a blueprint that is not today's compiled code
  cannot be used. The smoke test checks the deployed runtime code hashes again.
- Blueprints are deployed in earlier, ordinary transactions by the same script. They are not part of
  the deployment and are recorded in the manifest only for provenance.
- `DeploymentChecks` keeps every current assertion. CREATE provenance (`computeCreateAddress(factory,
  1..n)` and the factory's final nonce) is unchanged, since the factory still creates each role
  itself in order.
- `test_factory_initcodeAndGasWithinLimits` keeps guarding the deployment transaction's gas against
  2²⁴ with a 1M margin, and each contract's runtime against EIP-170 (24,576 bytes).
- If a variant ever cannot fit one transaction under the cap, splitting it is a spec change to §3.3
  constraint 8 through `/spec-change`, not an implementation detail.

## Consequences

- No spec text changes: one deployment transaction, `deployer() == factory`, every role created by
  the factory, no salt.
- The factory's initcode becomes small (blueprint addresses and hashes, plus the wiring logic);
  EIP-3860 stops being a limit on the protocol's total size.
- The binding limit is the deployment transaction's gas. Budget: the core (VaultManager,
  SortedPositions, RedemptionModule, StableToken, OracleAdapter, HintHelpers) costs about 7.8M gas;
  with a 1M margin under 16,777,216 the variant's strategy, DeficitLedger and ShutdownModule may
  total about 37 kB of runtime (about 41 kB if HintHelpers, wired to nothing and outside §3.4, is
  deployed separately). Estimates for those contracts, not yet written: 19–34 kB per variant, a
  margin of 3–18 kB.
- A literal reading of P11-1 ("no caller-supplied addresses") is relaxed for **code** addresses: the
  caller supplies where the code is read from, never which contract fills a role. The hash check
  makes a wrong blueprint revert rather than deploy, so a caller can only cause a failed deployment.
- One more step for the human on Base Sepolia: the blueprint transactions precede the deployment
  transaction. They are idempotent and reusable across A and B, since blueprints take no
  arguments.

## Alternatives considered

- **(a) A one-shot `deploy(bytes[] creationCodes)` on a pre-deployed factory.** One transaction and
  `deployer() == factory`, but about 80 kB of creation code as calldata adds about 1.2M gas to the
  very transaction that meets the gas cap.
- **(b) Sub-deployers coordinated in one transaction.** `deployer()` becomes a sub-deployer, which
  contradicts §3.3 constraint 8: a spec change, and more moving parts.
- **(c) Shrinking the contracts.** Buys a few kB; cannot absorb four contracts.
- **(e) Several deployment transactions, wired in the last.** Opens an un-wired window, harmless
  on-chain under ADR-0021, but contradicts constraint 8's single deployment transaction and P18's
  same-transaction requirement: a spec change.
