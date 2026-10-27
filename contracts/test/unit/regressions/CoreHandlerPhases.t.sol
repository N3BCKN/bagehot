// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../../src/core/VaultManager.sol";
import {CoreHandler} from "../../invariant/handlers/CoreHandler.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

/// @notice The core handler's rare phase actions really reach the window and the settled phase.
///         The campaign hits them only now and then (1 in 128 and 1 in 16 calls), so a hook that
///         always reverts must fail here deterministically (P17 review F1).
contract CoreHandlerPhasesTest is Test {
    using stdStorage for StdStorage;

    function _handler(bool variantB) internal returns (CoreHandler) {
        address[5] memory a =
            [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        return new CoreHandler(variantB, true, a);
    }

    function _throughThePhases(CoreHandler h) internal {
        VaultManager v = h.v();
        h.triggerShutdown(0);
        assertTrue(v.shutdown(), "the window was reached");
        h.settle(0);
        assertTrue(v.settled(), "the settled phase was reached");
        uint256 active = v.activeCount();
        h.reclaimGasReserve(0);
        assertEq(v.activeCount(), active - 1, "a gas reserve was reclaimed");
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
        _allHold(h);
    }

    function _allHold(CoreHandler h) internal view {
        (bool ok, string memory why) = h.checkI1Holders();
        assertTrue(ok, why);
        (ok, why) = h.checkI8();
        assertTrue(ok, why);
        (ok, why) = h.checkI9();
        assertTrue(ok, why);
        (ok, why) = h.checkEventsAgree();
        assertTrue(ok, why);
    }

    function test_phases_B_shutdownSettleReclaim() public {
        _throughThePhases(_handler(true));
    }

    /// @dev In A the shutdown action waits for the tolerance regime (CHG-005), so redistribute first;
    ///      the first redistribution waits for one exact step.
    function test_phases_A_redistributeThenShutdownSettleReclaim() public {
        CoreHandler h = _handler(false);
        h.toggleOracle(1); // healthy, a no-op: one exact step, which the first redistribution waits for
        h.redistribute(0);
        assertEq(h.redistributions(), 1, "the redistribution ran");
        assertGt(h.stepsNonExact(), 0, "tolerance regime reached");
        _throughThePhases(h);
    }

    /// @dev seed 1, B, fail-on-revert: a redemption attempt in the settled phase ran the live-phase
    ///      redemption classifier on settled positions, and its arithmetic panic escaped the action.
    function test_regression_redeemAfterSettlement_noEscapingRevert() public {
        CoreHandler h = _handler(true);
        h.triggerShutdown(1.1e18);
        h.settle(16);
        h.movePrice(9);
        h.movePrice(9);
        h.reclaimGasReserve(3_106_515_897);
        h.redeem(
            146_496_863_119_392_745_033_640_472_416_822_323_651_410_382_550_866_804_070_928_849_514,
            3_601_414_865_213_560_215_609_816_851_338_512_981_846_176_490_536,
            49_070_807,
            10
        );
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
    }

    /// @dev CHG-017: after settlement a position still reports pending collateral against a zeroed
    ///      `pendingColl`, so I8's collateral half is out of scope there; the debt half is not, and
    ///      a broken `pendingNormDebt` must still be caught (before CHG-017 the check returned early).
    function test_I8_afterSettlement_checksTheDebtHalfOnly() public {
        CoreHandler h = _handler(false);
        h.toggleOracle(1);
        h.redistribute(0);
        h.triggerShutdown(0);
        h.settle(0);
        VaultManager v = h.v();
        assertTrue(v.settled(), "settled");
        assertEq(v.pendingColl(), 0, "settlement zeroed pendingColl");
        uint256 pendingCollOfPositions;
        for (uint256 id = 1; id < v.nextId(); ++id) {
            VaultManager.Position memory p = v.positions(id);
            if (p.status != VaultManager.Status.Active) continue;
            (uint256 c,) = v.effective(id);
            pendingCollOfPositions += c - p.coll;
        }
        assertGt(pendingCollOfPositions, 0, "a position still reports pending collateral");
        (bool ok, string memory why) = h.checkI8();
        assertTrue(ok, why);
        assertGt(v.pendingNormDebt(), 0, "pending debt to break");
        stdstore.target(address(v)).sig("pendingNormDebt()").checked_write(uint256(0));
        (ok, why) = h.checkI8();
        assertFalse(ok, "the debt half is still checked after settlement");
        assertEq(why, "I8: sum of pending debt > pendingNormDebt");
    }
}
