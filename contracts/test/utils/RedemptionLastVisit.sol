// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Why a redemption's last visited node was not redeemed from although it was not below MCR
///         (I5 as reworded by CHG-007). Evaluated independently of the contract — OZ `Math` with the
///         rounding written out, not the protocol's helpers — in §6.7.3's order; the first condition
///         that holds is the reason, and `None` means the stop had no legitimate reason.
/// @dev Valid on the state *after* the call: a cancelled partial changes nothing about the node, the
///      nodes redeemed before it are already removed (as they were when it was visited), and the
///      index is the one the call used (it accrued in this block). `remaining` is the amount not yet
///      redeemed when the node was visited: requested minus everything the call redeemed.
library RedemptionLastVisit {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    enum Reason {
        None,
        MinDebtCap,
        Chg002PostCheck,
        StaleHint
    }

    struct Visit {
        uint256 id;
        uint256 remaining;
        uint256 feeRate;
        uint256 price;
        uint256 upperHint;
        uint256 lowerHint;
    }

    function classify(VaultManager v, SortedPositions sorted, Visit memory x) internal view returns (Reason) {
        (Reason early, uint256 newColl, uint256 newNorm) = _partialOf(v, x);
        if (early != Reason.None || newNorm == 0) return early;
        (bool found,,) = sorted.find(newColl, newNorm, x.id, x.id, x.upperHint, x.lowerHint);
        return found ? Reason.None : Reason.StaleHint;
    }

    /// @dev The exits before the list is probed. Returns `newNorm = 0` when there is no partial to
    ///      probe (a full redemption, which is never cancelled; an active position's remaining
    ///      normalised debt after a partial is ≥ MIN_DEBT's, so never 0).
    function _partialOf(VaultManager v, Visit memory x)
        private
        view
        returns (Reason early, uint256 newColl, uint256 newNorm)
    {
        (uint256 c, uint256 n) = v.effective(x.id);
        uint256 idx = v.index();
        uint256 debt = Math.mulDiv(n, idx, RAY, Math.Rounding.Ceil);
        if (x.remaining >= debt) return (Reason.None, 0, 0);
        uint256 d = Math.min(x.remaining, debt - v.MIN_DEBT());
        if (d == 0) return (Reason.MinDebtCap, 0, 0);
        bool belowMcr;
        (newColl, newNorm, belowMcr) = _after(v.MCR(), c, n, d, idx, x);
        if (belowMcr) return (Reason.Chg002PostCheck, 0, 0);
    }

    /// @dev The partial's result and whether it would leave ICR < MCR (dn down, out down, debt up).
    function _after(uint256 mcr, uint256 c, uint256 n, uint256 d, uint256 idx, Visit memory x)
        private
        pure
        returns (uint256 newColl, uint256 newNorm, bool belowMcr)
    {
        newNorm = n - Math.mulDiv(d, RAY, idx);
        newColl = c - Math.mulDiv(d, WAD - x.feeRate, x.price);
        belowMcr = newColl * x.price < mcr * Math.mulDiv(newNorm, idx, RAY, Math.Rounding.Ceil);
    }
}
