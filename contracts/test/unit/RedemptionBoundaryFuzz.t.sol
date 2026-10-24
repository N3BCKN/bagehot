// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Near the MCR / MIN_DEBT boundary, at random indices and prices: a position with zero or a
///         few wei of slack above MCR is redeemed by tiny and ordinary amounts. HintHelpers'
///         simulated outcome (redeemable, partial position — including its CHG-002 and MIN_DEBT
///         cancellations) must equal redeemCollateral's actual one, and every successful call must
///         leave the position at ≥ MIN_DEBT and ICR ≥ MCR (I5).
contract RedemptionBoundaryFuzzTest is RedemptionFixture {
    function _minColl(uint256 debt, uint256 index, uint256 price) internal pure returns (uint256) {
        uint256 n = Math.mulDiv(debt, RAY, index, Math.Rounding.Ceil);
        uint256 debtOf = Math.mulDiv(n, index, RAY, Math.Rounding.Ceil);
        return Math.mulDiv(MCR, debtOf, price, Math.Rounding.Ceil);
    }

    function testFuzz_hints_agreeWithRedeemCollateralNearTheBoundary(
        uint256 indexSeed,
        uint256 priceSeed,
        uint256 debtSeed,
        uint256 slack,
        uint256 amountSeed
    ) public {
        uint256 price = bound(priceSeed, 10e18, 3000e18) / 1e10 * 1e10; // the feed's 8 decimals
        uint256 debt = bound(debtSeed, MIN_DEBT, 3 * MIN_DEBT);
        // tiny amounts most of the time (the CHG-002 window), sometimes up to the whole debt
        uint256 amount = amountSeed % 4 == 0 ? bound(amountSeed, 1, debt + 1e18) : bound(amountSeed, 1, 300);
        uint256 id = _setupBoundary(bound(indexSeed, RAY, 4 * RAY), price, debt, bound(slack, 0, 3));
        _compare(id, amount, price, amountSeed);
    }

    function _setupBoundary(uint256 index, uint256 price, uint256 debt, uint256 slack)
        internal
        returns (uint256 id)
    {
        v.setIndex(index);
        _setPrice(price);
        _open(erin, 1e22, 20_000e18 + debt); // the redeemer, far above MCR at any price here
        id = _open(alice, _minColl(debt, index, price) + slack, debt);
        assertEq(sorted.getLast(), id);
    }

    function _compare(uint256 id, uint256 amount, uint256 price, uint256 seed) internal {
        (uint256 up, uint256 lo, uint256 partialId, uint256 redeemable) =
            hints.getRedemptionHints(amount, price, 5, rm.redemptionFeeRate(amount), 10, seed);
        vm.recordLogs();
        vm.prank(erin);
        try rm.redeem(amount, 5, WAD, up, lo) {}
        catch (bytes memory err) {
            assertEq(bytes4(err), RedemptionModule.NothingRedeemed.selector, "only NothingRedeemed");
            assertEq(redeemable, 0, "helper predicted a redemption");
            assertEq(partialId, 0);
            return;
        }
        (uint256 redeemed, uint256 actualPartial) = _outcome(vm.getRecordedLogs());
        assertEq(redeemed, redeemable, "redeemable");
        assertEq(actualPartial, partialId, "partial position");
        VaultManager.Position memory p = v.positions(id);
        if (p.status == VaultManager.Status.Active) {
            assertGe(v.debtOf(id), MIN_DEBT, "I5: MIN_DEBT");
            assertGe(p.coll * price, MCR * v.debtOf(id), "I5: ICR >= MCR");
        }
    }

    function _outcome(Vm.Log[] memory logs) internal pure returns (uint256 redeemed, uint256 partialId) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != VaultManager.PositionRedeemed.selector) continue;
            (uint256 d,,, bool closed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
            redeemed += d;
            if (!closed) partialId = uint256(logs[i].topics[1]);
        }
    }
}
