// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRedemptionViews} from "../interfaces/IRedemptionViews.sol";
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
///      (§2.1 `NICR_PRECISION`, floor), used only to rank candidates. `getRedemptionHints` (P16,
///      approved by the human) simulates `VaultManager.redeemCollateral` (§6.7.3) with the same
///      integer arithmetic, so a redeemer learns which position takes the final partial and where
///      it will be reinserted.
contract HintHelpers {
    uint256 public constant NICR_PRECISION = 1e20;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    /// @dev The quantities one redemption simulation reads once.
    struct Simulation {
        uint256 index;
        uint256 mcr;
        uint256 minDebt;
        uint256 price;
        uint256 feeRate;
        uint256 numTrials;
        uint256 seed;
    }

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
        return _approxHint(keyColl, keyNorm, numTrials, inputRandomSeed, sorted.getLast());
    }

    /// @notice Simulates `redeemCollateral(·, amount, feeRate, price, maxIterations, ·, ·)` on the
    ///         current state (§6.7.3), as a `redeem` in this block would run it after accruing: same
    ///         walk from the tail, same skip below MCR, same full redemptions, and the same
    ///         cancellations of the final partial — at exactly `MIN_DEBT`, below MCR after rounding
    ///         (CHG-002), or with no slot found. Pass the returned hints to `redeem` unchanged.
    /// @dev `feeRate` is the rate the redemption will pay (e.g. `RedemptionModule.redemptionFeeRate`).
    ///      The index is `currentIndex()`, which equals the index `redeemCollateral` reads after the
    ///      redemption's own accrual in the same block. The hints come from `find` on today's list
    ///      with the partial node excluded; positions the same call redeems fully lie behind it and
    ///      are removed before the partial, so a hint naming one is discarded by `find` and the walk
    ///      continues from the other hint (§6.3.2). rounding: as §6.7.3 (R1 up, R3 down, R18 down).
    /// @param numTrials samples for the approximate hint of the partial's new key (see `getApproxHint`)
    /// @return upperHint insert hint for the partial (0 if none)
    /// @return lowerHint insert hint for the partial (0 if none)
    /// @return partialId the position that takes the final partial, 0 if there is none
    /// @return redeemable the stablecoin `redeemCollateral` would redeem
    function getRedemptionHints(
        uint256 amount,
        uint256 price,
        uint256 maxIterations,
        uint256 feeRate,
        uint256 numTrials,
        uint256 inputRandomSeed
    ) external view returns (uint256 upperHint, uint256 lowerHint, uint256 partialId, uint256 redeemable) {
        IRedemptionViews v = IRedemptionViews(address(vaultManager));
        return _simulate(
            Simulation(v.currentIndex(), v.MCR(), v.MIN_DEBT(), price, feeRate, numTrials, inputRandomSeed),
            amount,
            maxIterations
        );
    }

    function _simulate(Simulation memory sim, uint256 amount, uint256 maxIterations)
        internal
        view
        returns (uint256 upperHint, uint256 lowerHint, uint256 partialId, uint256 redeemable)
    {
        uint256 remaining = amount;
        uint256 cur = sorted.getLast();
        for (uint256 it = 0; remaining > 0 && cur != 0 && it < maxIterations; ++it) {
            uint256 debt = _redeemableDebt(cur, sim);
            if (debt == 0) {
                cur = sorted.getPrev(cur); // below MCR: skipped
                continue;
            }
            if (remaining >= debt) {
                redeemable += debt; // full redemption
                remaining -= debt;
                cur = sorted.getPrev(cur);
                continue;
            }
            bool found;
            uint256 d;
            (found, d, upperHint, lowerHint) = _partialStep(cur, remaining, sim);
            if (found) {
                partialId = cur;
                redeemable += d;
            }
            break; // the partial — done or cancelled — is the last step
        }
    }

    /// @dev The node's debt (R1, up), or 0 when it is below MCR and the loop skips it. An active
    ///      position's debt is ≥ MIN_DEBT > 0, so 0 is unambiguous.
    function _redeemableDebt(uint256 id, Simulation memory sim) internal view returns (uint256 debt) {
        (uint256 c, uint256 n) = vaultManager.sortKey(id);
        debt = Rounding.mulDivUp(n, sim.index, RAY);
        if (c * sim.price < sim.mcr * debt) return 0;
    }

    /// @dev The partial: its amount, the CHG-002 post-check, then its slot. `found = false` when the
    ///      partial is cancelled (exactly `MIN_DEBT`, CHG-002, or no slot within the step limit).
    function _partialStep(uint256 id, uint256 remaining, Simulation memory sim)
        internal
        view
        returns (bool found, uint256 d, uint256 upperHint, uint256 lowerHint)
    {
        uint256 newColl;
        uint256 newNorm;
        (d, newColl, newNorm) = _partial(id, remaining, sim);
        if (d == 0) return (false, 0, 0, 0);
        (uint256 up, uint256 lo) = _startHints(id, newColl, newNorm, sim);
        (found, upperHint, lowerHint) = sorted.find(newColl, newNorm, id, id, up, lo);
        if (!found) return (false, 0, 0, 0);
    }

    /// @dev Where `find` starts for the partial's new key: the closest sampled member, or — when that
    ///      is the node itself, which `find` excludes — the node's neighbours. Sampling starts from the
    ///      partial node, not the tail: the nodes behind it are the ones this call redeems in full,
    ///      and starting among them could put the slot beyond MAX_HINT_STEPS (review F3).
    function _startHints(uint256 id, uint256 newColl, uint256 newNorm, Simulation memory sim)
        internal
        view
        returns (uint256, uint256)
    {
        (uint256 approx,,) = _approxHint(newColl, newNorm, sim.numTrials, sim.seed, id);
        if (approx == id) return (sorted.getPrev(id), sorted.getNext(id));
        return (approx, approx);
    }

    /// @dev §6.7.3's partial amounts and the CHG-002 post-check; `d = 0` when cancelled.
    function _partial(uint256 id, uint256 remaining, Simulation memory sim)
        internal
        view
        returns (uint256 d, uint256 newColl, uint256 newNorm)
    {
        (uint256 c, uint256 n) = vaultManager.sortKey(id);
        uint256 debt = Rounding.mulDivUp(n, sim.index, RAY);
        d = remaining < debt - sim.minDebt ? remaining : debt - sim.minDebt;
        if (d == 0) return (0, 0, 0);
        newNorm = n - Rounding.mulDivDown(d, RAY, sim.index);
        newColl = c - Rounding.mulDivDown(d, WAD - sim.feeRate, sim.price);
        if (newColl * sim.price < sim.mcr * Rounding.mulDivUp(newNorm, sim.index, RAY)) return (0, 0, 0);
    }

    /// @dev Samples `numTrials` ids and keeps the member closest to the key, starting from `start`
    ///      (a member, or 0 for an empty list).
    function _approxHint(
        uint256 keyColl,
        uint256 keyNorm,
        uint256 numTrials,
        uint256 inputRandomSeed,
        uint256 start
    ) internal view returns (uint256 hintId, uint256 diff, uint256 latestRandomSeed) {
        latestRandomSeed = inputRandomSeed;
        hintId = start;
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
