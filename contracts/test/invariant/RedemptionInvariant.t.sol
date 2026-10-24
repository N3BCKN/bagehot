// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../../src/core/HintHelpers.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";
import {MockShutdownGate} from "../utils/RedemptionMocks.sol";
import {MockLedgerViews} from "../utils/VaultMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Drives redemptions among opens, price moves and time warps (deployment A, live phase).
///         Every check of a redemption is made by the handler right after the call, on the state the
///         call left and at the price it fetched, and recorded as a violation count the invariants
///         assert to be zero (a failing assert inside a handler would only be a discarded revert).
///         I2's counters come from events only, redemptions included (§10.2).
contract RedemptionHandler is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_POSITIONS = 24; // keeps unhinted opens inside MAX_HINT_STEPS

    VaultManager public v;
    StableToken public token;
    SortedPositions public sorted;
    MockAggregator public feed;
    RedemptionModule public rm;
    MockShutdownGate public gate;
    HintHelpers public hints;
    address[4] internal actors;
    uint256 public price = 2000e18;

    // I2 counters (events only)
    uint256 public gN;
    uint256 public gX;
    uint256 public gY;
    // I5 / I15
    uint256 public i5Violations;
    uint256 public i15Violations;
    uint256 public partialOrderViolations;
    uint256 public skipViolations;
    // coverage
    uint256 public redeemsOk;
    uint256 public redeemsGated;
    uint256 public redeemsNothing;
    uint256 public partials;
    uint256 public fulls;
    uint256 public skipsSeen;
    /// @notice Successful calls whose last visit was a cancelled partial (CHG-007, pending: the
    ///         reason check for this visit is added once the human decides).
    uint256 public lastVisitCancelled;

    constructor(
        VaultManager v_,
        StableToken token_,
        SortedPositions sorted_,
        MockAggregator feed_,
        RedemptionModule rm_,
        MockShutdownGate gate_,
        HintHelpers hints_,
        address[4] memory a
    ) {
        (v, token, sorted, feed) = (v_, token_, sorted_, feed_);
        (rm, gate, hints) = (rm_, gate_, hints_);
        actors = a;
    }

    // ------------------------------------------------------------------ actions

    function open(uint256 actorSeed, uint256 debtSeed, uint256 icrSeed) external {
        if (v.activeCount() >= MAX_POSITIONS) return;
        address who = actors[actorSeed % actors.length];
        // a quarter of the opens sit at exactly MIN_DEBT, where a partial is cancelled
        uint256 debt = debtSeed % 4 == 0 ? 2000e18 : bound(debtSeed, 2000e18, 30_000e18);
        uint256 icr = bound(icrSeed, 1.1e18, 3e18);
        uint256 I = v.currentIndex();
        uint256 debtOf =
            Math.mulDiv(Math.mulDiv(debt, RAY, I, Math.Rounding.Ceil), I, RAY, Math.Rounding.Ceil);
        uint256 coll = Math.mulDiv(Math.max(icr, 1.1e18), debtOf, price, Math.Rounding.Ceil) + 1;
        vm.recordLogs();
        vm.prank(who);
        try v.openPosition(coll, debt, 0, 0) {} catch {}
        _countI2(vm.getRecordedLogs());
    }

    function movePrice(uint256 seed) external {
        price = bound(seed, 1000e18, 2600e18) / 1e10 * 1e10;
        feed.setRound(1, int256(price / 1e10), block.timestamp);
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 7 days));
        feed.setRound(1, int256(price / 1e10), block.timestamp);
    }

    /// @dev What one redeem call saw before it ran.
    struct Call {
        uint256 amount;
        uint256 maxIt;
        uint256 up;
        uint256 lo;
        bool gated;
        uint256[] order; // tail first: the visit order
        bool[] below; // below MCR at the visit (the views read currentIndex = the call's index)
    }

    function redeem(uint256 actorSeed, uint256 amountSeed, uint256 itSeed, bool useHints) external {
        address who = actors[actorSeed % actors.length];
        uint256 bal = token.balanceOf(who);
        if (bal == 0) return;
        Call memory c = _prepare(bal, amountSeed, itSeed, useHints);
        vm.recordLogs();
        vm.prank(who);
        try rm.redeem(c.amount, c.maxIt, 1e18, c.up, c.lo) {
            ++redeemsOk;
            if (c.gated) ++i15Violations;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _countI2(logs);
            _checkRedemption(logs, c);
        } catch (bytes memory err) {
            _onRevert(c.gated, bytes4(err));
        }
    }

    function _prepare(uint256 bal, uint256 amountSeed, uint256 itSeed, bool useHints)
        internal
        view
        returns (Call memory c)
    {
        c.amount = amountSeed % 3 == 0 ? bound(amountSeed, 1, 1e6) : bound(amountSeed, 1, bal);
        c.maxIt = bound(itSeed, 1, 8);
        c.order = _tailFirst(c.maxIt);
        c.below = new bool[](c.order.length);
        for (uint256 k; k < c.order.length; ++k) {
            c.below[k] = v.isLiquidatable(c.order[k], price);
        }
        c.gated = gate.belowCritical(price); // systemDebt reads currentIndex: the post-accrual value
        if (useHints) (c.up, c.lo) = _hints(c.amount, c.maxIt);
    }

    function _onRevert(bool gated, bytes4 sel) internal {
        if (sel == RedemptionModule.TCRBelowCritical.selector) {
            ++redeemsGated;
            if (!gated) ++i15Violations;
        } else {
            if (gated) ++i15Violations; // the gate must have fired first
            if (sel == RedemptionModule.NothingRedeemed.selector) ++redeemsNothing;
        }
    }

    // ------------------------------------------------------------------ checks

    function _checkRedemption(Vm.Log[] memory logs, Call memory c) internal {
        (uint256[] memory redeemed, uint256 nRedeemed, uint256 iterations, bool partialSeen) = _parse(logs);
        if (partialSeen && redeemed[nRedeemed - 1] != c.order[iterations - 1]) ++partialOrderViolations;
        for (uint256 k; k < iterations; ++k) {
            if (_contains(redeemed, nRedeemed, c.order[k])) continue;
            if (k == iterations - 1 && !c.below[k]) {
                ++lastVisitCancelled; // CHG-007 pending
                continue;
            }
            ++skipsSeen;
            if (!c.below[k]) ++skipViolations;
        }
    }

    function _parse(Vm.Log[] memory logs)
        internal
        returns (uint256[] memory redeemed, uint256 n, uint256 iterations, bool partialSeen)
    {
        redeemed = new uint256[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.PositionRedeemed.selector) {
                uint256 id = uint256(logs[i].topics[1]);
                (,,, bool closed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                if (partialSeen) ++partialOrderViolations; // nothing after the partial
                if (closed) {
                    ++fulls;
                } else {
                    partialSeen = true;
                    ++partials;
                }
                redeemed[n++] = id;
                _checkI5(id);
            } else if (t == RedemptionModule.Redeemed.selector) {
                (,,,, iterations,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    /// @dev I5: closed by redemption, or ≥ MIN_DEBT and ICR ≥ MCR at the redemption's price.
    function _checkI5(uint256 id) internal {
        VaultManager.Position memory p = v.positions(id);
        if (p.status == VaultManager.Status.ClosedByRedemption) return;
        uint256 debt = v.debtOf(id);
        (uint256 c,) = v.effective(id);
        if (debt < v.MIN_DEBT() || c * price < v.MCR() * debt) ++i5Violations;
    }

    function _countI2(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(v)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.InterestAccrued.selector) {
                ++gN;
            } else if (t == VaultManager.PositionUpdated.selector) {
                (,,,,,, uint8 op) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint8));
                if (op == 1 || op == 4 || op == 5) ++gX;
                else if (op == 6) ++gY;
            } else if (t == VaultManager.PositionRedeemed.selector) {
                (,,, bool closed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                if (closed) ++gY;
                else ++gX;
            }
        }
    }

    // ------------------------------------------------------------------ helpers

    function _tailFirst(uint256 maxIt) internal view returns (uint256[] memory order) {
        uint256 n = Math.min(maxIt, sorted.getSize());
        order = new uint256[](n);
        uint256 cur = sorted.getLast();
        for (uint256 k; k < n; ++k) {
            order[k] = cur;
            cur = sorted.getPrev(cur);
        }
    }

    function _hints(uint256 amount, uint256 maxIt) internal view returns (uint256 up, uint256 lo) {
        if (token.totalSupply() == 0) return (0, 0);
        (up, lo,,) = hints.getRedemptionHints(amount, price, maxIt, rm.redemptionFeeRate(amount), 15, amount);
    }

    function _contains(uint256[] memory a, uint256 n, uint256 x) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (a[i] == x) return true;
        }
        return false;
    }
}

/// @notice I5 and I15 (and I2 with redemptions) under random redemptions, price moves and warps.
contract RedemptionInvariantTest is RedemptionFixture {
    RedemptionHandler internal handler;

    function setUp() public override {
        super.setUp();
        // a healthy base so the system is live and the redeemers hold stablecoin
        // TCR 1.49 at 2,000: price moves down to 1,000 reach the critical-TCR gate
        _open(erin, 25e18, 30_000e18);
        _open(alice, 9e18, 15_000e18);
        _open(bob, 10e18, 15_000e18);
        _open(carol, 12e18, 15_000e18);
        address[4] memory a = [alice, bob, carol, erin];
        handler = new RedemptionHandler(v, token, sorted, feed, rm, gate, hints, a);
        targetContract(address(handler));
    }

    function invariant_I5_redemptionLeavesHealthyPositions() public view {
        assertEq(handler.i5Violations(), 0, "I5: a redeemed position left below MIN_DEBT or MCR");
        assertEq(handler.partialOrderViolations(), 0, "I5: at most one partial, and it is the last visit");
        assertEq(
            handler.skipViolations(), 0, "I5: a visited, unredeemed node before the last was not below MCR"
        );
    }

    function invariant_I15_noRedemptionBelowCritical() public view {
        assertEq(handler.i15Violations(), 0, "I15: the gate disagreed with its condition");
    }

    /// @dev §10.2 with redemption's counts: −N·RAY ≤ E ≤ X·I + Y·RAY (A = F = 0 here).
    function invariant_I2_supplyDriftBoundUnderRedemption() public view {
        uint256 I = v.index();
        uint256 lhs = v.totalNormDebt() * I;
        uint256 rhs = (token.totalSupply() - ledger.auctionDebt() - ledger.deficit()) * RAY;
        // the fixture's four opens precede the handler: 4 counts of X, no accrual yet
        uint256 x = handler.gX() + 4;
        if (lhs >= rhs) assertLt(lhs - rhs, x * I + handler.gY() * RAY, "I2 upper");
        else assertLt(rhs - lhs, handler.gN() * RAY, "I2 lower");
    }

    function afterInvariant() external {
        emit log_named_uint("redeems ok", handler.redeemsOk());
        emit log_named_uint("redeems gated (I15)", handler.redeemsGated());
        emit log_named_uint("redeems NothingRedeemed", handler.redeemsNothing());
        emit log_named_uint("full redemptions", handler.fulls());
        emit log_named_uint("partials", handler.partials());
        emit log_named_uint("skips checked", handler.skipsSeen());
        emit log_named_uint(
            "successful calls ending on a cancelled partial (CHG-007)", handler.lastVisitCancelled()
        );
    }
}
