// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice I13's hidden-key bound (CHG-009). Every member is given an ideal stake on one
///         common ratio, c·DP/(DP + L_p), so that with the real accumulators (shared by every member)
///         its hidden NICR is (DP + LColl)/(h_p + LDebt), where h_p = n_p·(DP + snapLColl_p)/c_p −
///         snapLDebt_p is constant while it stays in the list. Ordering by h is invariant under every
///         redistribution, whatever the real stakes. An observed key (C, N) maps to
///         h_obs = N·(DP + LColl)/C − LDebt. An insertion is exact against the neighbours' observed
///         keys, so it can sit off the hidden order only by the neighbours' deviation h − h_obs then;
///         ι records that. Values are exact rationals `x·y/den − off`; differences are taken exactly
///         (512-bit mulDiv/mulmod) and rounded up once, so an undrifted neighbour contributes 0.
library I13HiddenKeys {
    uint256 internal constant DP = 1e18;

    struct Rat {
        uint256 x;
        uint256 y;
        uint256 den;
        uint256 off;
    }

    /// @dev h of a member from its stored state at insertion (pending applied, snapshots = L then).
    function h(uint256 coll, uint256 normDebt, uint256 snapLColl, uint256 snapLDebt)
        internal
        pure
        returns (Rat memory)
    {
        return Rat(normDebt, DP + snapLColl, coll, snapLDebt);
    }

    /// @dev The h an ideal member would need for the observed key (C, N) at the current accumulators.
    function hObs(uint256 effColl, uint256 effNorm, uint256 lColl, uint256 lDebt)
        internal
        pure
        returns (Rat memory)
    {
        return Rat(effNorm, DP + lColl, effColl, lDebt);
    }

    /// @dev ⌈a − b⌉ exactly. With q = ⌊x·y/den⌋, r = x·y mod den on each side, a − b =
    ///      (qa − qb) − (offA − offB) + (ra/denA − rb/denB), and the last term lies in (−1, 1).
    function ceilDiff(Rat memory a, Rat memory b) internal pure returns (int256) {
        int256 whole = SafeCast.toInt256(Math.mulDiv(a.x, a.y, a.den))
            - SafeCast.toInt256(Math.mulDiv(b.x, b.y, b.den))
            - (SafeCast.toInt256(a.off) - SafeCast.toInt256(b.off));
        uint256 ra = mulmod(a.x, a.y, a.den);
        uint256 rb = mulmod(b.x, b.y, b.den);
        // ra/denA > rb/denB  ⇔  ra·denB > rb·denA, compared on full 512-bit products
        // domain)
        return whole + (_gt(ra, b.den, rb, a.den) ? int256(1) : int256(0));
    }

    struct Side {
        bool present;
        Rat h;
        Rat obs;
        int256 iota;
    }

    /// @dev ι of a member inserted between `ahead` (its predecessor) and `behind` (its successor):
    ///      max(0, ι_X + ⌈h_X − h_obs,X⌉, ι_Y + ⌈h_obs,Y − h_Y⌉). A missing side contributes
    /// nothing.
    function iota(Side memory ahead, Side memory behind) internal pure returns (int256 r) {
        if (ahead.present) r = _max(r, ahead.iota + ceilDiff(ahead.h, ahead.obs));
        if (behind.present) r = _max(r, behind.iota + ceilDiff(behind.obs, behind.h));
    }

    /// @dev The pair condition h_A − ι_A ≤ h_B + ι_B, exactly: ⌈h_A − h_B⌉ ≤ ι_A + ι_B.
    function pairHolds(Rat memory hA, int256 iotaA, Rat memory hB, int256 iotaB)
        internal
        pure
        returns (bool)
    {
        return ceilDiff(hA, hB) <= iotaA + iotaB;
    }

    /// @dev p·q > s·t for 256-bit operands, compared on their 512-bit products.
    function _gt(uint256 p, uint256 q, uint256 s, uint256 t) private pure returns (bool) {
        (uint256 hi1, uint256 lo1) = _mul512(p, q);
        (uint256 hi2, uint256 lo2) = _mul512(s, t);
        return hi1 > hi2 || (hi1 == hi2 && lo1 > lo2);
    }

    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        unchecked {
            lo = a * b;
            uint256 mm = mulmod(a, b, type(uint256).max);
            // hi = (mm − lo) − (mm < lo ? 1 : 0): the standard 512-bit product split (no overflow by
            // construction)
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }

    function _max(int256 a, int256 b) private pure returns (int256) {
        return a > b ? a : b;
    }
}
