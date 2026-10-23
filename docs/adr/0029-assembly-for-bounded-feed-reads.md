# ADR-0029: Read the oracle feeds with a fixed-buffer assembly staticcall

- Status: accepted 2026-10-23 (human, P12 plan gate)
- Date: 2026-10-23
- Prompt: P12
- Supersedes: —

## Context

`contracts/CLAUDE.md` forbids inline assembly unless an ADR approves it. OracleAdapter's feed read
has requirements that high-level Solidity meets only partly (spec §6.10.1, §6.10.3, threats T-02
and T-03):

1. A **failed call** is a `staticcall` with gas `ORACLE_GAS` that reverts, runs out of gas, or
   returns **fewer than 160 bytes**. `try/catch` cannot express the third case: the ABI decoder
   reverts on short or malformed return data *outside* the `catch`, so a malformed feed would make
   `fetchPrice` revert instead of reporting "unusable". That has two effects: every operation that
   needs a price is blocked, and `ShutdownModule.check` reverts too, so the oracle failure clock
   never starts and an `ORACLE` shutdown can never trigger. `try/catch` is therefore ruled out.
2. A 160-byte answer may carry junk above bit 80 in `roundId` / `answeredInRound`. Decoding those
   words as `uint80` reverts for the same reason as in (1).
3. After a failed call, `require(gasleft() >= ORACLE_POST_FAILURE_GAS)` must measure only what the
   63/64 rule left behind. The argument for the threshold (`ceil(ORACLE_GAS / 63)`) assumes that
   nothing the feed controls costs gas between the call and the check.

The remaining candidates are a high-level `address.staticcall` followed by
`abi.decode(ret, (uint256, int256, uint256, uint256, uint256))`, and a fixed-buffer assembly call.
Both satisfy (1) and (2), because decoding into full 256-bit words never reverts on content. They
differ on (3) and on cost.

**Measurement** (P12, Foundry, 100,000-gas cap, a hostile feed returning N bytes):

| N | high-level `staticcall` | fixed 160-byte buffer |
|---|---|---|
| 160 (honest feed) | 6,405 gas | 8,395 gas (difference within cold-access noise) |
| 50,000 | 37,220 | 22,551 |
| 150,000 (≈ the largest a capped feed can return) | 151,173 | 79,516 |
| 200,000 | callee out of gas, fails identically in both | |

A high-level `staticcall` copies all return data, **including revert data**, into the caller's
memory, so the caller pays for its memory expansion. That cost is bounded by what the feed can
generate within its own capped gas: at most about 72,000 extra gas per read, about 145,000 for both
feeds. It arises only from a hostile or compromised feed. The same copy also sits between a
*reverting* call and the gas check, so feed-chosen revert data lowers `gasleft()` before the check.
A caller who left an honest margin can then get `InsufficientGasForOracle` instead of a recorded
failure. That is recoverable (retry with more gas), but it is feed-controlled.

## Decision

One `internal view` function in OracleAdapter, `_readFeed(address feed)`, performs the read in
assembly, and it is the only assembly in `src/` outside dependencies:

```
// selector of latestRoundData() at the free-memory pointer; the 160-byte output overwrites it
ok   := staticcall(ORACLE_GAS, feed, ptr, 4, ptr, 160)
ok   := and(ok, iszero(lt(returndatasize(), 160)))
// on success read words 1, 2, 3 (answer, startedAt, updatedAt) with mload; words 0 and 4 unused
```

Properties the code must have, each checked by a test:

- **Memory-safe** (`assembly ("memory-safe")`): it writes only from the free-memory pointer
  onwards and does not advance it; the buffer is scratch.
- **Return data is never copied beyond 160 bytes**, whatever the feed returns or reverts with.
- **Words are read as full 256-bit values.** `answer` is the raw `int256` word; `roundId` and
  `answeredInRound` are never read, so junk in them cannot matter.
- **No `returndatacopy` and no `RETURNDATA`-sized loop**, so the instruction count between the
  call and the gas-rule check is constant and independent of the feed.
- The `ORACLE_GAS` cap is passed as the call's gas argument, never "all remaining gas".

The mock that needs non-ABI output (a 32-byte answer, junk `uint80` words, short `decimals`) does
so **without assembly**, with a Solidity `fallback(bytes calldata) external returns (bytes memory)`,
which returns its bytes unencoded. P11's `MockAggregator.ShortReturn` assembly block is removed in
P12 and replaced by that mock. It was an oversight against this rule.

## Consequences

- An honest read costs the same as with high-level code. A hostile feed's read cost is bounded by
  the callee's own spending; the caller pays no copy.
- The gas rule's margin depends only on the 63/64 rule, not on anything the feed returns. This is
  the property T-03 relies on.
- The security reviewer and every future reader must audit about 10 lines of assembly. They are
  confined to one function with a NatSpec block restating the properties above.
- Tests that depend on this decision: the malformed-return tests (32 bytes, 159 bytes, junk
  `uint80` words, empty return from an address with no code), a 150 KB return-bomb test asserting
  the read stays within a fixed gas budget, a 150 KB revert-data test asserting the failure is
  *recorded* rather than turned into `InsufficientGasForOracle`, and both gas-griefing sweeps.
- Reversing it means replacing one function with the high-level form below and dropping two
  tests. No storage or interface changes.

## Alternatives considered

- **`try/catch` on the interface call** (blueprint §8.8's sketch). Rejected: short or malformed
  return data reverts outside the `catch` (context, item 1), which fails closed in a way that also
  disables the ORACLE shutdown trigger.
- **High-level `staticcall` + length check + decoding into `uint256` words, no assembly.**
  Viable. It meets spec §6.10.1 completely and is what to fall back on if this ADR is rejected.
  Not chosen because a hostile feed can (a) add up to ~72k gas to every read and (b) put
  feed-controlled copying between a failed call and the gas check, eroding the margin that
  ORACLE_POST_FAILURE_GAS defends. Both effects are bounded and need a compromised feed, which
  could also lie within the price bounds. The case for assembly is defence in depth, not a
  correctness necessity, and this ADR records it as such.
- **High-level `staticcall` with a larger `ORACLE_POST_FAILURE_GAS` to absorb the copy.**
  Rejected: the copy cost scales with what the feed returns. A fixed margin large enough for the
  worst case (~72k) would also refuse honest callers far more often, which is the opposite of what
  the threshold is tuned for.
