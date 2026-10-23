// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISortKeySource} from "../interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../interfaces/ISortedPositions.sol";
import {Rounding} from "../lib/Rounding.sol";

/// @title HintHelpers
/// @notice Off-chain convenience for computing insert hints (docs/spec.md §6.3.2: "callers compute
///         hints off-chain"). Stateless and view-only: it changes nothing, holds nothing, has no
///         permissions, and no protocol decision depends on it — a bad hint costs at most a
///         `StaleHint` revert or extra walk steps, never a wrong order (insertion is exact).
/// @dev Not in the spec's contract list: added at P13 as a periphery view (approved by the human).
///      Its sampling uses `keccak256` of a caller-supplied seed — predictable, which is fine for a
///      view with no security role. The distance measure is the NICR at the spec's display precision
///      (§2.1 `NICR_PRECISION`, floor), used only to rank candidates. `getRedemptionHints` arrives
///      with the redemption loop at P16.
contract HintHelpers {
    uint256 public constant NICR_PRECISION = 1e20;

    ISortKeySource public immutable vaultManager;
    ISortedPositions public immutable sorted;

    constructor(ISortKeySource vaultManager_, ISortedPositions sorted_) {
        vaultManager = vaultManager_;
        sorted = sorted_;
    }

    /// @notice A list member whose NICR is close to that of `(keyColl, keyNorm)`, to pass as both
    ///         hints of an insert. Starts from the tail and samples `numTrials` ids uniformly from
    ///         `[1, nextId)`, keeping the closest member.
    /// @param numTrials number of samples; the loop is bounded by it (caller-supplied, view only)
    /// @return hintId the closest member found (0 if the list is empty)
    /// @return diff |nicr(hintId) − nicr(key)| at NICR_PRECISION
    /// @return latestRandomSeed the seed after the last sample, to continue sampling in a later call
    function getApproxHint(uint256 keyColl, uint256 keyNorm, uint256 numTrials, uint256 inputRandomSeed)
        external
        view
        returns (uint256 hintId, uint256 diff, uint256 latestRandomSeed)
    {
        latestRandomSeed = inputRandomSeed;
        hintId = sorted.getLast();
        if (hintId == 0) return (0, 0, latestRandomSeed);
        uint256 target = _nicr(keyColl, keyNorm);
        diff = _distance(_nicrOf(hintId), target);
        uint256 idCount = vaultManager.nextId() - 1; // ids run from 1 to nextId − 1; ≥ 1 if a member
        // exists
        for (uint256 i = 0; i < numTrials; ++i) {
            latestRandomSeed = uint256(keccak256(abi.encode(latestRandomSeed)));
            uint256 id = 1 + latestRandomSeed % idCount;
            if (!sorted.contains(id)) continue;
            uint256 d = _distance(_nicrOf(id), target);
            if (d < diff) {
                diff = d;
                hintId = id;
            }
        }
    }

    function _nicrOf(uint256 id) internal view returns (uint256) {
        (uint256 c, uint256 n) = vaultManager.sortKey(id);
        return _nicr(c, n);
    }

    /// @dev §5.1.12 `nicr`: mulDivDown(coll, NICR_PRECISION, norm); a zero debt ranks as infinite.
    function _nicr(uint256 c, uint256 n) internal pure returns (uint256) {
        return n == 0 ? type(uint256).max : Rounding.mulDivDown(c, NICR_PRECISION, n);
    }

    function _distance(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
