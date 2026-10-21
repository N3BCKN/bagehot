# contracts/ — Solidity conventions

Applies to everything under `contracts/`. The `solidity-rules` skill holds the full security
checklist; this file holds conventions.

## Toolchain
- Solidity pinned in `foundry.toml` (see ADR-018); `evm_version = "cancun"`; optimizer on, 200 runs;
  `via_ir = false` unless an ADR says otherwise.
- Dependencies: OpenZeppelin Contracts 5.x and forge-std, pinned by tag/commit in `lib/`.
  Use OZ `Math.mulDiv(x, y, d, Math.Rounding.{Floor,Ceil})` inside `lib/Rounding.sol` wrappers.

## Layout and style
- `src/core`, `src/liquidation`, `src/redemption`, `src/safety`, `src/lib`, `src/mocks`, `src/interfaces`.
- One contract per file; interfaces in `src/interfaces/I*.sol`; NatSpec on every external function
  including rounding direction and who may call it.
- Order: errors, events, constants, immutables, storage, modifiers, constructor, wiring, external,
  public, internal, private, views.
- Custom errors only (`error StalePrice();`), no revert strings. Names match the spec; the Python
  model raises exceptions with the same names.
- Events for every state change, with the fields listed in the spec — the indexer rebuilds state
  from events alone (I14).
- Units in names when ambiguous: `debtWad`, `indexRay`, `priceWad`, `feeBps`.

## Safety conventions
- Checks–effects–interactions everywhere; `ReentrancyGuardTransient` on every external
  state-changing entry point of contracts that hold or move tokens.
- External calls only to: WETH, the stable token, the oracle feeds (through OracleAdapter), the
  wired protocol contracts, and the auction buyer callback (P33). Nothing else.
- Every loop is bounded by a caller-supplied or immutable maximum.
- `unchecked` only with a comment proving no overflow/underflow; prefer none.
- No `tx.origin`, no `block.prevrandao`, no `selfdestruct`, no `delegatecall`, no assembly unless an
  ADR approves it.
- Views that depend on accrued interest compute the current index without writing state.

## Tests
- `test/unit/<Contract>.t.sol`, `test/invariant/`, `test/symbolic/` (Halmos `check_` functions),
  `test/fork/` (pinned block numbers, skipped when `BASE_ARCHIVE_RPC` is absent),
  `test/vectors/` (load `spec/vectors/*.json` via `vm.readFile` + `vm.parseJson`).
- Test names: `test_<function>_<condition>_<expected>`, `testFuzz_…`, `invariant_I<n>_<name>`.
- Every custom error has at least one test that triggers it.
