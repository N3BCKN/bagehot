"""Every deliberate difference between the model and the chain the differential test allows — the
single list (P23, human condition 2026-10-27). Each entry says what is excused and why. The harness
applies exactly these and nothing else: a difference not listed here is a mismatch.

Three kinds:
- `EXCLUDED_EVENTS`: chain events the model does not emit; filtered out of the per-transaction event
  comparison and nowhere else.
- `REVERT_NAMES`: how a chain revert is named for comparison with the model's exception name.
- `NOT_GENERATED`: paths the harness never drives, because one side cannot express them. They are
  covered elsewhere, named per entry.

The snapshots themselves have no excused field: both sides produce the same keys
(`System.snapshot()` and `Chain.snapshot()`), and the comparison is full equality. Return values
are compared for every function that declares outputs; a function that declares none (e.g.
`claimGains`, `accrue`) returns nothing on chain, so the model's internal `Receipt.value` for it has
no counterpart — not an excused difference, an absent value.
"""

from __future__ import annotations

EXCLUDED_EVENTS: dict[str, str] = {
    "Approval": (
        "ERC-20 allowances are not modelled (model/protocol/events.py). Actors approve the vault "
        "for WETH once, during setup, before the base snapshot; OZ v5's transferFrom spends an "
        "allowance without emitting Approval, so no operation the harness compares can emit one — "
        "the filter is a guard, not an expected event."
    ),
    "Wired": (
        "Deployment only (§3.4): the factory wires every contract in its constructor, before the "
        "base snapshot. The model builds the graph whole and has no wiring step."
    ),
}

# model exception name -> the chain revert name it stands for
REVERT_NAMES: dict[str, str] = {
    "Overflow": "Panic(0x11)",  # checked arithmetic (P22-DIFF-PANIC)
    "Underflow": "Panic(0x11)",  # checked subtraction: the same panic code on chain
    "DivisionByZero": "Panic(0x12)",
    # "WethTransferFailed": spec §2.5 — any revert raised inside WETH carries this name; the chain
    # side derives it from the call trace (Chain._revert), so it compares as itself.
}

NOT_GENERATED: dict[str, str] = {
    "wiring": (
        "No `wire` call, no call before wiring, no call from the deployer to a wiring function "
        "(P22-DIFF-WIRED). The model has no wiring state, so NotWired / AlreadyWired / "
        "NotDeployer would be false mismatches. Covered by Foundry: test_wire_*, MisWiredFactory, "
        "DeploymentChecks."
    ),
    "gas": (
        "Every transaction carries 30M gas, so InsufficientGasForOracle / "
        "InsufficientGasForPoolHook and starved guarded calls never arise; the model has no gas. "
        "Covered by Foundry: the oracle and pool-hook gas tests (ADR-0030, ADR-0033)."
    ),
    "failing pool hook": (
        "PoolInterestRedirected needs a stability pool whose onInterest reverts or runs out of "
        "gas; the deployed pool only fails on G overflow, which no realistic sequence reaches. "
        "Covered by Foundry's VaultManagerPoolHookTest matrix and the model's interest tests."
    ),
    "non-ABI feed replies": (
        "Short, junk-word, huge or out-of-gas replies come from `RawFeed` / `BurnGas` (ADR-0029), "
        "which the model cannot express: its feed read returns a round or None. Every §6.10.1 row "
        "the model can express is generated (rows 1-10: sequencer call fails, down, bad startedAt, "
        "grace period, price call fails, non-positive, bad updatedAt, stale, out of bounds). "
        "Covered by OracleAdapter.t.sol / OracleAdapterFuzz.t.sol and spec/vectors/oracle.json."
    ),
    "StaleHint": (
        "Hints are drawn from the model's list (adjacent pairs, one side, closed or unknown ids), "
        "so hint validation and both walks are compared, but `StaleHint` needs a walk longer than "
        "MAX_HINT_STEPS (30) — more positions than an example opens. Covered by "
        "SortedPositions.t.sol / SortedPositionsFuzz.t.sol and the model's I9 tests."
    ),
    "component access control": (
        "Actors call the wired-only hooks the model checks a caller for — VaultManager.onShutdown, "
        "onSettlement, redeemCollateral, DeficitLedger.onSettlement (`DiffMachine.intrude`). The "
        "other §9 restrictions (StableToken.mint / burnFrom / moveFrom, SortedPositions.insert / "
        "remove / reinsert, StabilityPool.onLiquidation / onInterest, the ledger's vault hooks) "
        "guard contracts the model represents as components called only through their wired "
        "callers, with no caller argument, so there is nothing to compare. Covered by the "
        "`Unauthorized` tests in each contract's unit suite."
    ),
    "shutdown module": (
        "The ShutdownModule is the stand-in until its prompt (P22-SM): the harness calls the hooks "
        "as the wired shutdown address — accrue then onShutdown; VaultManager.onSettlement then "
        "DeficitLedger.onSettlement — each pair in one block, as System.trigger_shutdown / settle "
        "do. On chain a pair is two transactions against one atomic model call, so pairs are "
        "generated only in phase (both succeed); out of phase the stand-in calls one hook alone "
        "(`DiffMachine.hook_out_of_phase`). The real module's check(), triggers and claims (I10) "
        "are not driven."
    ),
    "deployment failures": (
        "The harness starts from a valid deployment; constructor argument errors are compared by "
        "the unit tests on each side, not here (P22-DIFF-PANIC)."
    ),
}


def model_revert_name(exc: BaseException) -> str:
    name = type(exc).__name__
    return REVERT_NAMES.get(name, name)
