// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {PriceUnusable} from "../../src/lib/Errors.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {CoreHandler} from "../invariant/handlers/CoreHandler.sol";
import {CountingOracle} from "../utils/CountingOracle.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The I9 ∩ I12 boundary (human's requirement at the P17 plan): with the oracle unusable for
///         each of the nine reasons of §6.10.1, the rescue paths repay, addCollateral and close still
///         succeed and perform no oracle read (I9 takes precedence), while every price-required
///         operation — open, borrow, withdrawCollateral, redeem — reverts PriceUnusable (I12). The
///         rescue paths are checked again in the shutdown window, where I9 also applies. Both
///         deployments.
contract RescuePathsUnusableOracleTest is Test {
    CoreHandler internal h;
    VaultManager internal v;
    StableToken internal token;
    CountingOracle internal counting;
    RedemptionModule internal rm;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _variantB() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        address[5] memory a = [alice, bob, makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        h = new CoreHandler(_variantB(), false, a);
        v = h.v();
        token = h.token();
        counting = h.counting();
        rm = h.rm();
    }

    /// @dev `toggleOracle(seed)` selects reason 1 + (seed / 3) % 9 when seed % 3 == 0.
    function _setReason(uint256 reason) internal {
        h.toggleOracle(3 * (reason - 1));
        (, bool usable, OracleAdapter.Reason r) = h.oracle().peek();
        assertFalse(usable);
        assertEq(uint256(r), reason, "the mode produces its reason");
    }

    function test_rescuePathsLiveAndPriceGatedOpsBlocked_everyUnusableReason() public {
        for (uint256 reason = 1; reason <= 9; ++reason) {
            uint256 snap = vm.snapshotState();
            vm.warp(block.timestamp + 1 days); // interest accrues inside the rescue paths too
            _setReason(reason);
            _rescuePathsSucceedWithoutOracleReads(reason);
            _priceRequiredOpsRevert(reason);
            vm.revertToState(snap);
        }
    }

    /// @dev I9's scope includes the window: the same three paths under every unusable reason.
    function test_rescuePathsLiveInTheWindow_everyUnusableReason() public {
        v.accrue();
        vm.prank(address(h.gate()));
        v.onShutdown();
        assertTrue(v.shutdown(), "in the window");
        for (uint256 reason = 1; reason <= 9; ++reason) {
            uint256 snap = vm.snapshotState();
            vm.warp(block.timestamp + 1 days);
            _setReason(reason);
            _rescuePathsSucceedWithoutOracleReads(reason);
            vm.revertToState(snap);
        }
    }

    function _rescuePathsSucceedWithoutOracleReads(uint256 reason) internal {
        uint256 reads = counting.reads();
        // id 2 is alice's 15,000-debt position; id 3 bob's
        vm.prank(bob);
        v.addCollateral(2, 1e18, 0, 0); // anyone may add
        vm.prank(alice);
        v.repay(2, 1000e18, 0, 0);
        uint256 shortfall = v.debtOf(3) - token.balanceOf(bob) + 1; // before the prank: a call consumes it
        vm.prank(alice);
        token.transfer(bob, shortfall);
        vm.prank(bob);
        v.close(3);
        assertEq(uint8(v.positions(3).status), uint8(VaultManager.Status.ClosedByOwner), "close went through");
        assertEq(counting.reads(), reads, string.concat("no oracle read, reason ", vm.toString(reason)));
    }

    /// @dev Each revert is checked by its selector; a reverted call changes no state.
    function _priceRequiredOpsRevert(uint256) internal {
        vm.startPrank(alice);
        vm.expectRevert(PriceUnusable.selector);
        v.openPosition(10e18, 2000e18, 0, 0);
        vm.expectRevert(PriceUnusable.selector);
        v.borrow(2, 1e18, 0, 0);
        vm.expectRevert(PriceUnusable.selector);
        v.withdrawCollateral(2, 1, 0, 0);
        vm.expectRevert(PriceUnusable.selector);
        rm.redeem(1e18, 5, 1e18, 0, 0);
        vm.stopPrank();
    }
}

contract RescuePathsUnusableOracleBTest is RescuePathsUnusableOracleTest {
    function _variantB() internal pure override returns (bool) {
        return true;
    }
}
