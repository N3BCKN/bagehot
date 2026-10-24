// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISortedPositions} from "../../src/interfaces/ISortedPositions.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";
import {RedemptionLastVisit} from "../utils/RedemptionLastVisit.sol";

/// @notice The I5 last-visit check (CHG-007) on real redemptions: each legitimate cancellation is
///         recognised with the right reason, and a stop with no legitimate reason — the contract
///         ending the loop although the partial should have gone through — is rejected (`None`, the
///         invariant's violation). The illegitimate stop is induced by making `find` lie to the
///         VaultManager during the call only; the check then runs on the real list.
contract RedemptionLastVisitTest is RedemptionFixture {
    function _classify(uint256 id, uint256 remaining, uint256 fee, uint256 price, uint256 up, uint256 lo)
        internal
        view
        returns (RedemptionLastVisit.Reason)
    {
        return
            RedemptionLastVisit.classify(
                v, sorted, RedemptionLastVisit.Visit(id, remaining, fee, price, up, lo)
            );
    }

    /// @dev erin (redeemer, head), a position at 4,000 debt, and the tail bob redeemed in full first.
    function _fullThenPartialSetup() internal returns (uint256 idAlice) {
        _open(erin, 100e18, 20_000e18);
        _open(carol, 10e18, 5000e18);
        idAlice = _open(alice, 3e18, 4000e18);
        _open(bob, 2.4e18, 4000e18); // the tail
    }

    function test_lastVisit_minDebtCapIsLegitimate() public {
        _open(erin, 100e18, 20_000e18);
        uint256 p2 = _open(carol, 2.22e18, MIN_DEBT);
        _open(dave, 2.21e18, MIN_DEBT); // the tail
        uint256 fee = rm.redemptionFeeRate(2500e18);
        vm.prank(erin);
        rm.redeem(2500e18, 10, WAD, 0, 0); // dave in full; carol visited at exactly MIN_DEBT
        assertEq(token.balanceOf(erin), 20_000e18 - MIN_DEBT);
        assertEq(uint8(_classify(p2, 500e18, fee, PRICE, 0, 0)), uint8(RedemptionLastVisit.Reason.MinDebtCap));
    }

    function test_lastVisit_chg002IsLegitimate() public {
        // redemption.json#partial_cancelled_below_mcr: alice at exactly MCR, index 1.2304, price 10
        _setPrice(10e18);
        _open(erin, 2000e18, 10_000e18);
        vm.warp(block.timestamp + 134_028_000);
        _setPrice(10e18);
        uint256 alice_ = _open(alice, 6600e18 + 110, 60_000e18 + 999);
        uint256 fee = rm.redemptionFeeRate(11);
        assertEq(
            uint8(_classify(alice_, 11, fee, 10e18, 0, 0)), uint8(RedemptionLastVisit.Reason.Chg002PostCheck)
        );
    }

    function test_lastVisit_ordinaryPartialHasNoCancellationReason() public {
        uint256 idAlice = _fullThenPartialSetup();
        uint256 fee = rm.redemptionFeeRate(4500e18);
        // before the call, with bob still listed, the partial on alice would go through
        assertEq(uint8(_classify(idAlice, 500e18, fee, PRICE, 0, 0)), uint8(RedemptionLastVisit.Reason.None));
    }

    /// @notice The negative test the human required: the contract stops on the last node although
    ///         none of MIN_DEBT cap, CHG-002 or a stale hint applies. The check returns `None`, which
    ///         the invariant counts as `lastVisitWithoutReason` and asserts to be zero.
    function test_lastVisit_illegitimateStopIsRejected() public {
        uint256 idAlice = _fullThenPartialSetup();
        uint256 fee = rm.redemptionFeeRate(4500e18);
        // the bug: during the call, `find` reports no slot although one exists
        vm.mockCall(
            address(sorted), abi.encodeWithSelector(ISortedPositions.find.selector), abi.encode(false, 0, 0)
        );
        vm.prank(erin);
        rm.redeem(4500e18, 10, WAD, 0, 0);
        vm.clearMockedCalls();
        assertEq(v.debtOf(idAlice), 4000e18, "the contract stopped on alice without redeeming");
        assertEq(token.balanceOf(erin), 16_000e18, "only bob's 4,000 was redeemed");
        // the independent check, on the real list: no legitimate reason — a violation
        assertEq(uint8(_classify(idAlice, 500e18, fee, PRICE, 0, 0)), uint8(RedemptionLastVisit.Reason.None));
    }
}

/// @notice The stale-hint reason, with MAX_HINT_STEPS = 1.
contract RedemptionLastVisitStaleTest is RedemptionFixture {
    function setUp() public override {
        maxHintSteps = 1;
        super.setUp();
    }

    function test_lastVisit_staleHintIsLegitimate() public {
        vm.prank(erin);
        uint256 idErin = v.openPosition(100e18, 20_000e18, 0, 0);
        vm.prank(carol);
        uint256 idCarol = v.openPosition(10e18, 5000e18, idErin, 0);
        vm.prank(alice);
        uint256 idAlice = v.openPosition(3e18, 4000e18, idCarol, 0);
        vm.prank(bob);
        v.openPosition(2.4e18, 4000e18, idAlice, 0);
        uint256 fee = rm.redemptionFeeRate(4500e18);
        vm.prank(erin);
        rm.redeem(4500e18, 10, WAD, idErin, idErin); // two steps from erin: stale with one step
        assertEq(v.debtOf(idAlice), 4000e18);
        assertEq(
            uint8(
                RedemptionLastVisit.classify(
                    v, sorted, RedemptionLastVisit.Visit(idAlice, 500e18, fee, PRICE, idErin, idErin)
                )
            ),
            uint8(RedemptionLastVisit.Reason.StaleHint)
        );
        // with the hints the helper would give, the same partial has no cancellation reason
        assertEq(
            uint8(
                RedemptionLastVisit.classify(
                    v, sorted, RedemptionLastVisit.Visit(idAlice, 500e18, fee, PRICE, idCarol, 0)
                )
            ),
            uint8(RedemptionLastVisit.Reason.None)
        );
    }
}
