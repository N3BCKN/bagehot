---
name: python-model
description: Rules for the Bagehot Python protocol model, the differential harness and simulation agents — exact integer arithmetic mirroring Solidity, determinism, snapshots. Use whenever editing model/, differential/, agents/ or paths/.
user-invocable: false
paths: "model/**, differential/**, agents/**, paths/**"
---
## Protocol model (model/protocol/)
- Python `int` only for protocol state and math. No `float`, no `Decimal`, no numpy in the protocol
  core. `model/protocol/math.py` implements `mul_div(x, y, d, rounding)`, WAD/RAY helpers and `rpow`
  bit-for-bit identical to the Solidity library; both are validated against the same vectors.
- Mirror Solidity semantics: uint256 overflow raises `Overflow`; underflow raises `Underflow`;
  custom errors become exceptions with identical names; operations are atomic (on exception,
  state is unchanged — implement with copy-on-write or explicit rollback).
- Time is explicit: every operation takes `now: int` (seconds). Accrual uses it exactly as
  `block.timestamp`.
- Ordering of internal steps matches the spec (accrue → apply pending → act → reinsert).
- Sorted list tie-breaking identical to Solidity.
- `snapshot()` returns a canonical dict of every field the differential test compares, with
  integer values only and deterministic key order.
- Each operation returns emitted events in the same shape as the Solidity events.

## Differential harness (differential/)
- One anvil process per test session; `evm_snapshot`/`evm_revert` between examples.
- Before each transaction call `evm_setNextBlockTimestamp` with the model's `now`.
- Use unlocked anvil accounts (`eth_sendTransaction`); never handle real keys.
- Compare after every rule; tolerance zero. Revert parity is compared by error name.
- Hypothesis profiles: `quick` (CI, ~100 examples), `nightly` (~2000); print the seed on failure.

## Agents and paths (agents/, paths/)
- Floats allowed. All randomness from an injected `numpy.random.Generator`; never global state.
- Seeds derived with `numpy.random.SeedSequence(...).spawn(n)`; record them in results.
- Agents act through the protocol model's public API only.

## Quality
- Type hints everywhere; `ruff check` clean; dataclasses with `slots=True` for hot objects.
- Profile before optimising (`python -m cProfile`); keep the core readable over clever.
