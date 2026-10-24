// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";

/// @notice Gas of the redemption loop with many tiny positions (P16 plan): every iteration's cost is
///         bounded, `maxIterations` bounds the loop, and a run of below-MCR positions at the tail only
///         consumes iterations. Numbers are logged for docs/progress.md; the bounds are generous
///         ceilings, not snapshots.
contract RedemptionGasTest is RedemptionFixture {
    uint256 internal constant N = 50;

    /// @dev N positions at MIN_DEBT, NICR rising with i, so position 1 is the tail. Each is opened
    ///      after the previous one with exact hints.
    function _openTiny(uint256 collBase) internal {
        uint256 prev;
        for (uint256 i; i < N; ++i) {
            vm.prank(alice);
            prev = v.openPosition(collBase + i * 1e15, MIN_DEBT, 0, prev);
        }
    }

    function test_gas_fullRedemptionsOfManyTinyPositions() public {
        _open(erin, 1000e18, 200_000e18); // head; holds the stablecoin
        _openTiny(2.3e18); // ICR 2.3–2.35 at 2,000
        uint256 g = gasleft();
        vm.prank(erin);
        rm.redeem(N * MIN_DEBT, N, WAD, 0, 0);
        uint256 used = g - gasleft();
        assertEq(v.activeCount(), 1, "all N closed");
        emit log_named_uint("gas, redeem closing 50 MIN_DEBT positions", used);
        emit log_named_uint("gas per full redemption", used / N);
        assertLt(used / N, 90_000, "per-position ceiling");
        assertLt(used, 10_000_000, "50 positions fit well inside a block");
    }

    function test_gas_runOfBelowMcrPositionsOnlyCostsIterations() public {
        _open(erin, 1000e18, 200_000e18);
        _openTiny(2.21e18); // 2.210–2.259 WETH: every one is below MCR under 973.9
        _setPrice(970e18); // erin (ICR 4.85) and the TCR stay healthy
        assertTrue(v.isLiquidatable(sorted.getLast(), 970e18));
        assertTrue(v.isLiquidatable(sorted.getNext(sorted.getFirst()), 970e18), "the richest tiny one too");
        uint256 g = gasleft();
        vm.prank(erin);
        try rm.redeem(1000e18, N, WAD, 0, 0) {
            fail("N iterations are all skips");
        } catch (bytes memory err) {
            assertEq(bytes4(err), RedemptionModule.NothingRedeemed.selector);
        }
        uint256 skips = g - gasleft();
        emit log_named_uint("gas, 50 skips (the whole call, reverted)", skips);
        emit log_named_uint("gas per skipped node, fixed costs included", skips / N);
        // a skip reads ~5 cold position slots (coll, normDebt, stake, snapshots) and the list links
        assertLt(skips / N, 25_000, "a skip is a few cold reads");
        vm.prank(erin);
        rm.redeem(1000e18, N + 1, WAD, 0, 0); // N skips, then a partial on erin
        assertEq(v.debtOf(1), 199_000e18);
        g = gasleft();
        vm.prank(erin);
        vm.expectRevert(RedemptionModule.NothingRedeemed.selector);
        rm.redeem(1000e18, 5, WAD, 0, 0); // maxIterations stops the walk long before erin
        emit log_named_uint("gas, maxIterations = 5 over the run", g - gasleft());
    }

    /// @notice Review F3: more full redemptions than MAX_HINT_STEPS (30) before the partial. The hint
    ///         helper must still find the partial's slot (sampling starts at the partial node, not
    ///         among the tail nodes this call removes) and agree with the contract.
    function test_hints_manyFullRedemptionsBeforeThePartial() public {
        _open(erin, 1000e18, 200_000e18); // head; holds the stablecoin
        uint256 big = _open(bob, 4.8e18, 4000e18); // NICR 0.0012, above every tiny one
        uint256 prev = big;
        for (uint256 i; i < 35; ++i) {
            vm.prank(alice);
            prev = v.openPosition(2.3e18 + i * 1e15, MIN_DEBT, 0, prev); // NICR ≤ 0.001167
        }
        uint256 amount = 35 * MIN_DEBT + 500e18; // 35 full redemptions, then a partial on `big`
        uint256 fee = rm.redemptionFeeRate(amount);
        (uint256 up, uint256 lo, uint256 partialId, uint256 redeemable) =
            hints.getRedemptionHints(amount, PRICE, 40, fee, 0, 0);
        assertEq(partialId, big, "the helper finds the partial's slot");
        assertEq(redeemable, amount);
        vm.prank(erin);
        rm.redeem(amount, 40, WAD, up, lo);
        assertEq(token.balanceOf(erin), 200_000e18 - amount, "the contract redeems the same amount");
        assertEq(v.debtOf(big), 3500e18);
    }
}
