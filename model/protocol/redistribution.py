"""Redistribution (§6.5), bit-for-bit with the VaultManager's internal functions.

`_pending`, `_applyPending`, `_computeStake`, `_updateStake`, `_redistribute` and
`_updateSystemSnapshots` of `contracts/src/core/VaultManager.sol`. They act on the VaultManager's
storage, so each takes the `Vault` model and changes it in place; `Vault` calls them where the
contract calls its internals, inside its own transaction. Rounding R8 (pending, floor), R9 (floor
with error carry), R10 (stake, floor).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from model.protocol.math import checked as _c
from model.protocol.math import mul_div_down

if TYPE_CHECKING:
    from model.protocol.vault import Position, Vault

DECIMAL_PRECISION = 10**18


def pending(v: Vault, p: Position) -> tuple[int, int]:
    """§6.5.3, R8: the position's unapplied share, floored."""
    return (
        mul_div_down(p.stake, v.l_coll - p.snap_l_coll, DECIMAL_PRECISION),
        mul_div_down(p.stake, v.l_debt - p.snap_l_debt, DECIMAL_PRECISION),
    )


def apply_pending(v: Vault, pid: int) -> None:
    """§6.5.3: moves the pending share into the position, then re-snapshots it."""
    p = v.positions[pid]
    pc, pn = pending(v, p)
    if pc > 0 or pn > 0:
        p.coll += pc
        p.norm_debt += pn
        v.pending_coll -= pc
        v.pending_norm_debt -= pn
        v.total_collateral += pc
        v._emit(("RewardsApplied", pid, pc, pn))
    p.snap_l_coll, p.snap_l_debt = v.l_coll, v.l_debt


def compute_stake(v: Vault, coll: int) -> int:
    """§6.5.4, R10: `coll` at the stake-ratio snapshot; the identity before any snapshot."""
    if v.total_stakes_snapshot == 0 or v.total_collateral_snapshot == 0:
        return coll
    return mul_div_down(coll, v.total_stakes_snapshot, v.total_collateral_snapshot)


def update_stake(v: Vault, pid: int) -> None:
    p = v.positions[pid]
    new = compute_stake(v, p.coll)
    v.total_stakes = v.total_stakes - p.stake + new
    p.stake = new


def redistribute(v: Vault, coll_r: int, norm_r: int) -> None:
    """§6.5.2, R9: floor division with error carry. Precondition `total_stakes > 0`."""
    stakes = v.total_stakes
    coll_num = _c(coll_r * DECIMAL_PRECISION + v.last_error_coll)
    norm_num = _c(norm_r * DECIMAL_PRECISION + v.last_error_debt)
    d_coll, d_debt = coll_num // stakes, norm_num // stakes
    v.last_error_coll = coll_num - d_coll * stakes
    v.last_error_debt = norm_num - d_debt * stakes
    v.l_coll = _c(v.l_coll + d_coll)
    v.l_debt = _c(v.l_debt + d_debt)
    v.pending_coll += coll_r
    v.pending_norm_debt += norm_r
    v._emit(
        (
            "Redistributed",
            coll_r,
            norm_r,
            v.l_coll,
            v.l_debt,
            v.last_error_coll,
            v.last_error_debt,
            stakes,
        )
    )


def update_system_snapshots(v: Vault) -> None:
    """§6.5.4: the stake-ratio snapshot after a liquidation; reset when no stake is left."""
    if v.total_stakes == 0:
        v.total_stakes_snapshot = v.total_collateral_snapshot = 0
    else:
        v.total_stakes_snapshot = v.total_stakes
        v.total_collateral_snapshot = v.total_collateral + v.pending_coll
    v._emit(("SystemSnapshotsUpdated", v.total_stakes_snapshot, v.total_collateral_snapshot))
