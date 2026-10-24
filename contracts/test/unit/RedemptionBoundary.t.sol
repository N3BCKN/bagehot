// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {ISortedPositions} from "../../src/interfaces/ISortedPositions.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionVectorBase} from "../utils/RedemptionVectorBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The MIN_DEBT / MCR boundary of the redemption loop on the real contracts:
///         - CHG-002 (ADR-0027, open issue P04-2): the 11-wei partial of
///           `redemption.json#partial_cancelled_below_mcr` is cancelled by the post-check branch of
///           `redeemCollateral` itself — not by the skip, the MIN_DEBT stop or a stale hint;
///         - HintHelpers.getRedemptionHints agrees with redeemCollateral on every redeem step of every
///           vector: the same redeemable amount, the same partial position, the same cancellations.
contract RedemptionBoundaryTest is RedemptionVectorBase {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    function _setupUntilFirstRedeem(string memory vp) internal returns (uint256 j) {
        _deploy(vp);
        for (; _has(_sp(vp, j)); ++j) {
            if (!_setupStep(_sp(vp, j))) return j;
        }
    }

    function _vectorIndex(string memory name) internal view returns (uint256 i) {
        for (; _has(_vp(i)); ++i) {
            if (_is(_s(string.concat(_vp(i), ".name")), name)) return i;
        }
        revert(name);
    }

    /// @dev Everything the 11-wei call could change, as one hash.
    function _stateHash(uint256 id) internal view returns (bytes32) {
        VaultManager.Position memory p = v.positions(id);
        uint256[] memory order = new uint256[](sorted.getSize());
        uint256 cur = sorted.getFirst();
        for (uint256 i; i < order.length; ++i) {
            order[i] = cur;
            cur = sorted.getNext(cur);
        }
        return keccak256(
            abi.encode(
                p,
                order,
                v.totalCollateral(),
                v.totalNormDebt(),
                v.totalStakes(),
                v.activeCount(),
                token.totalSupply(),
                weth.balanceOf(address(v)),
                rm.baseRate(),
                rm.lastFeeOperationTime()
            )
        );
    }

    /// @dev The state before the 11-wei call rules out every exit of §6.7.3 except CHG-002; returns
    ///      the fee rate the module will charge (accrued already, so the view is exact).
    function _ruleOutEveryOtherExit(uint256 alice) internal view returns (uint256 fee) {
        (uint256 c, uint256 n) = v.effective(alice);
        uint256 idx = v.index();
        assertEq(idx, v.currentIndex(), "accrued in this block: the module's accrue is a no-op");
        assertEq(idx, 1_230_423_227_649_962_415_141_542_910);
        uint256 debt = Math.mulDiv(n, idx, RAY, Math.Rounding.Ceil);
        assertFalse(c * price < v.MCR() * debt, "not the below-MCR skip");
        assertEq(c * price, v.MCR() * debt, "exactly at MCR: zero slack");
        assertGt(debt - v.MIN_DEBT(), 11, "not the MIN_DEBT stop (d = 11)");
        fee = rm.redemptionFeeRate(11);
        uint256 dn = Math.mulDiv(11, RAY, idx);
        uint256 out = Math.mulDiv(11, WAD - fee, price);
        assertEq(dn, 8, "8 wei of normalised debt cancelled");
        assertEq(out, 1, "for 1 wei of collateral");
        (bool found,,) = sorted.find(c - out, n - dn, alice, alice, 0, 0);
        assertTrue(found, "a slot exists with the call's hints (0, 0): not the stale-hint exit");
        uint256 debtAfter = Math.mulDiv(n - dn, idx, RAY, Math.Rounding.Ceil);
        assertLt((c - out) * price, v.MCR() * debtAfter, "without CHG-002 alice would end below MCR");
    }

    /// @notice P04-2 / CHG-002 line item. Every other exit is ruled out from the state first; then
    ///         `redeemCollateral` is called directly (as the module) and must visit alice, never probe
    ///         the list, and return (0, 0, 1) with nothing changed. The only branch of §6.7.3 that
    ///         ends a visit at an active, not-below-MCR, above-MIN_DEBT position without calling
    ///         `find` is the CHG-002 post-check.
    function test_redeem_tinyPartialAtMcrBoundary() public {
        _load();
        string memory vp = _vp(_vectorIndex("partial_cancelled_below_mcr"));
        _setupUntilFirstRedeem(vp);
        address erin = makeAddr("erin");
        uint256 alice = sorted.getLast();
        assertEq(alice, 2, "alice is the tail");

        uint256 fee = _ruleOutEveryOtherExit(alice);

        bytes32 before = _stateHash(alice);
        vm.expectCall(address(sorted), abi.encodeWithSelector(ISortedPositions.find.selector), 0);
        vm.prank(address(rm));
        (uint256 redeemed, uint256 collSent, uint256 iterations) =
            v.redeemCollateral(erin, 11, fee, price, 5, 0, 0);
        assertEq(
            abi.encode(redeemed, collSent, iterations), abi.encode(0, 0, 1), "visited once, nothing redeemed"
        );
        assertEq(_stateHash(alice), before, "no state change");
    }

    /// @notice The vector's two steps through the module: the 11-wei call reverts NothingRedeemed
    ///         with every field unchanged, then the 1,000-stable partial of the same position goes
    ///         through and raises her ICR (I5's affirmative outcome).
    function test_redeem_tinyPartialAtMcrBoundary_throughTheModule() public {
        _load();
        _setupUntilFirstRedeem(_vp(_vectorIndex("partial_cancelled_below_mcr")));
        address erin = makeAddr("erin");
        uint256 alice = sorted.getLast();
        bytes32 before = _stateHash(alice);
        vm.prank(erin);
        vm.expectRevert(RedemptionModule.NothingRedeemed.selector);
        rm.redeem(11, 5, WAD, 0, 0);
        assertEq(_stateHash(alice), before, "every field unchanged");

        // an ordinary partial of the same position raises her ICR 1.1 → 1.101897
        assertEq(v.icr(alice, price) / 1e12, 1_100_000);
        vm.prank(erin);
        rm.redeem(1000e18, 5, WAD, 0, 0);
        assertApproxEqAbs(v.icr(alice, price), 1.101897e18, 0.5e12, "1.101897 to six decimals (I5)");
        assertGt(v.icr(alice, price), 1.1e18);
    }

    // ------------------------------------------------------------------ hint helper agreement

    struct Outcome {
        uint256 redeemed;
        uint256 partialId;
    }

    function _actual(address caller, uint256 amount, uint256 maxIt, uint256 up, uint256 lo)
        internal
        returns (Outcome memory o)
    {
        vm.recordLogs();
        vm.prank(caller);
        try rm.redeem(amount, maxIt, WAD, up, lo) {}
        catch (bytes memory err) {
            assertEq(bytes4(err), RedemptionModule.NothingRedeemed.selector, "only NothingRedeemed");
            return o;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VaultManager.PositionRedeemed.selector) {
                (uint256 d,,, bool closed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                o.redeemed += d;
                if (!closed) o.partialId = uint256(logs[i].topics[1]);
            }
        }
    }

    /// @dev For one redeem step: with the state accrued to the step's block (as `redeem` will), ask
    ///      the helper, redeem with its hints, compare; then restore and let the vector go on.
    function _compareStep(string memory sp) internal returns (bool compared) {
        (address caller, uint256 amount, uint256 maxIt,,,) = _redeemArgs(sp);
        if (_has(string.concat(sp, ".revert")) && !_is(_s(string.concat(sp, ".revert")), "NothingRedeemed")) {
            return false; // the gate and the fee cap sit outside the loop the helper simulates
        }
        uint256 snap = vm.snapshotState();
        v.accrue();
        uint256 fee = rm.redemptionFeeRate(amount);
        (uint256 up, uint256 lo, uint256 partialId, uint256 redeemable) =
            hints.getRedemptionHints(amount, price, maxIt, fee, 20, 42);
        Outcome memory o = _actual(caller, amount, maxIt, up, lo);
        assertEq(o.redeemed, redeemable, "redeemable");
        assertEq(o.partialId, partialId, "partial position");
        vm.revertToState(snap);
        return true;
    }

    function _advance(string memory sp) internal {
        (address caller, uint256 amount, uint256 maxIt, uint256 maxFee, uint256 up, uint256 lo) =
            _redeemArgs(sp);
        vm.prank(caller);
        try rm.redeem(amount, maxIt, maxFee, up, lo) {} catch {}
    }

    function _agreeOnVector(string memory name) internal returns (uint256 compared) {
        _load();
        string memory vp = _vp(_vectorIndex(name));
        _deploy(vp);
        for (uint256 j; _has(_sp(vp, j)); ++j) {
            string memory sp = _sp(vp, j);
            if (_setupStep(sp)) continue;
            if (_compareStep(sp)) ++compared;
            _advance(sp);
        }
    }

    /// @notice The CHG-002 cancellation: helper says nothing redeemable for 11 wei, the 1,000 partial
    ///         goes to alice — and the contract agrees on both.
    function test_hints_agreeOnPartialCancelledBelowMcr() public {
        assertEq(_agreeOnVector("partial_cancelled_below_mcr"), 2);
    }

    /// @notice The MIN_DEBT stop (helper: 0 for 1,000; frank in full for 2,000).
    function test_hints_agreeOnMinDebtStop() public {
        assertEq(_agreeOnVector("min_debt_stop"), 2);
    }

    function test_hints_agreeOnSkipFullPartial() public {
        assertEq(_agreeOnVector("skip_full_partial"), 1);
    }

    /// @notice With the helper's hints the partial the vector cancels on a stale hint goes through.
    function test_hints_agreeOnStaleHintVector() public {
        assertEq(_agreeOnVector("stale_hint_cancels_partial"), 1);
    }

    function test_hints_agreeOnBaseRateDecayAndFee() public {
        assertEq(_agreeOnVector("base_rate_decay_and_fee"), 2);
    }

    function test_hints_agreeOnSingleNodePartial() public {
        assertEq(_agreeOnVector("single_node_partial"), 1);
    }

    function test_hints_agreeOnTcrGuard() public {
        assertEq(_agreeOnVector("tcr_guard"), 1);
    }
}
