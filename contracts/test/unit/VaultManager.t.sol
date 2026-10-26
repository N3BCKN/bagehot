// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {
    AlreadySettled,
    InsufficientBalance,
    InvalidParameter,
    NotSettled,
    NotTriggered,
    PriceUnusable,
    SystemSettled,
    SystemShutdown,
    Unauthorized,
    ZeroAmount
} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";
import {stdError} from "forge-std/StdError.sol";

/// @notice VaultManager part I (spec §5.1.1–5.1.6, §5.1.10–5.1.12): every function, every error in
///         pseudocode order, boundaries, events with all fields, and state / token deltas.
contract VaultManagerTest is VaultFixture {
    uint256 internal constant DEBT = 4000e18;
    uint256 internal constant COLL = 4e18; // ICR 2.0 at PRICE

    function _st(uint256 id) internal view returns (VaultManager.Position memory) {
        return vm_.positions(id);
    }

    function _shutdown() internal {
        vm.prank(SHUTDOWN);
        vm_.onShutdown();
    }

    function _settle() internal {
        _shutdown();
        vm.prank(SHUTDOWN);
        vm_.onSettlement();
    }

    // ------------------------------------------------------------------ construction and wiring

    function deployVault(uint256[8] memory a) external returns (VaultManager) {
        return new VaultManager(
            address(uint160(a[0])),
            address(uint160(a[1])),
            address(uint160(a[2])),
            a[3],
            a[4],
            a[5],
            a[6],
            a[7],
            200_000
        );
    }

    function _ctorReverts(uint256[8] memory a, uint8 index) internal {
        try this.deployVault(a) returns (VaultManager) {
            fail("constructor did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(InvalidParameter.selector, index));
        }
    }

    /// @dev A fresh array each call: `a = good` would alias one memory array.
    function _good() internal pure returns (uint256[8] memory) {
        return [uint256(1), 2, 3, 1.1e18, 1e18, 1, 0, 0];
    }

    function _with(uint256 i, uint256 v) internal pure returns (uint256[8] memory a) {
        a = _good();
        a[i] = v;
    }

    function test_constructor_rejectsEachArgumentAtItsBoundary() public {
        _ctorReverts(_with(0, 0), 0);
        _ctorReverts(_with(1, 0), 1);
        _ctorReverts(_with(2, 0), 2);
        _ctorReverts(_with(3, 1e18), 3); // MCR must exceed WAD
        _ctorReverts(_with(3, 2e18 + 1), 3);
        _ctorReverts(_with(4, 1e18 - 1), 4);
        _ctorReverts(_with(5, 0), 5);
        _ctorReverts(_with(6, 21_979_553_151_239_153_029), 6);
        _ctorReverts(_with(7, 10_001), 7);
        uint256[8] memory a = _good();
        (a[3], a[6], a[7]) = (2e18, 21_979_553_151_239_153_028, 10_000); // boundaries accepted
        VaultManager v = this.deployVault(a);
        assertEq(v.MCR(), 2e18);
        assertEq(v.lastAccrual(), block.timestamp);
        assertEq(v.index(), 1e27);
        assertEq(v.nextId(), 1);
    }

    function test_wire_checksAndOnce() public {
        VaultManager v = new VaultManager(
            address(weth), address(token), address(oracle), MCR, MIN_DEBT, GAS_RESERVE, RATE, 100, 200_000
        );
        address s = address(sorted);
        address st = address(0x5);
        vm.prank(alice);
        vm.expectRevert(WiredBase.NotDeployer.selector);
        v.wire(s, st, st, REDEMPTION, address(ledger), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(0)));
        v.wire(address(0), st, st, REDEMPTION, address(ledger), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(1)));
        v.wire(s, address(0), st, REDEMPTION, address(ledger), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(2))); // pool ∉ {0,
        // strategy}
        v.wire(s, st, address(0x6), REDEMPTION, address(ledger), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(2))); // B with POOL_SHARE_BPS
        // ≠ 0
        v.wire(s, st, address(0), REDEMPTION, address(ledger), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(3)));
        v.wire(s, st, st, address(0), address(ledger), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(4)));
        v.wire(s, st, st, REDEMPTION, address(0), SHUTDOWN);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(5)));
        v.wire(s, st, st, REDEMPTION, address(ledger), address(0));
        address[] memory exp = new address[](6);
        (exp[0], exp[1], exp[2], exp[3], exp[4], exp[5]) = (s, st, st, REDEMPTION, address(ledger), SHUTDOWN);
        vm.expectEmit(address(v));
        emit WiredBase.Wired(exp);
        v.wire(s, st, st, REDEMPTION, address(ledger), SHUTDOWN);
        assertEq(address(v.sorted()), s);
        assertEq(v.strategy(), st);
        assertEq(v.stabilityPool(), st);
        assertEq(v.redemptionModule(), REDEMPTION);
        assertEq(v.deficitLedger(), address(ledger));
        assertEq(v.shutdownModule(), SHUTDOWN);
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        v.wire(s, st, st, REDEMPTION, address(ledger), SHUTDOWN);
    }

    function test_mutators_revertNotWired() public {
        VaultManager v = new VaultManager(
            address(weth), address(token), address(oracle), MCR, MIN_DEBT, GAS_RESERVE, RATE, 0, 200_000
        );
        vm.startPrank(SHUTDOWN);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.openPosition(COLL, DEBT, 0, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.addCollateral(1, 1, 0, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.withdrawCollateral(1, 1, 0, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.borrow(1, 1, 0, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.repay(1, 1, 0, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.close(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.reclaimGasReserve(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        v.onShutdown();
        vm.expectRevert(WiredBase.NotWired.selector);
        v.onSettlement();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ openPosition

    function test_open_movesTokensStoresAndEmits() public {
        uint256 wethBefore = weth.balanceOf(alice);
        vm.expectEmit(address(vm_));
        emit VaultManager.PositionOpened(1, alice, DEBT);
        vm.expectEmit(address(vm_));
        emit VaultManager.PositionUpdated(1, COLL, DEBT, COLL, 0, 0, 1, 1);
        uint256 id = _open(alice, COLL, DEBT);
        assertEq(id, 1);
        VaultManager.Position memory p = _st(1);
        assertEq(p.owner, alice);
        assertEq(p.coll, COLL);
        assertEq(p.normDebt, DEBT); // index RAY: n = debt
        assertEq(p.stake, COLL); // no snapshot yet: stake = coll
        assertEq(uint8(p.status), 1);
        assertEq(token.balanceOf(alice), DEBT);
        assertEq(weth.balanceOf(alice), wethBefore - COLL - GAS_RESERVE);
        assertEq(weth.balanceOf(address(vm_)), COLL + GAS_RESERVE);
        assertEq(vm_.totalCollateral(), COLL);
        assertEq(vm_.totalNormDebt(), DEBT);
        assertEq(vm_.totalStakes(), COLL);
        assertEq(vm_.activeCount(), 1);
        assertEq(vm_.nextId(), 2);
        assertTrue(sorted.contains(1));
    }

    function test_open_icrBoundaryExactlyAtMcr() public {
        uint256 c = _minColl(DEBT); // coll·price ≥ MCR·debt with equality possible
        _open(alice, c, DEBT);
        vm.prank(bob);
        vm.expectRevert(VaultManager.IcrBelowMcr.selector);
        vm_.openPosition(c - 1, DEBT, 0, 0);
    }

    function test_open_debtBoundaryAndCollateralCap() public {
        weth.mint(bob, type(uint128).max);
        _open(alice, _minColl(MIN_DEBT), MIN_DEBT); // exactly MIN_DEBT
        vm.startPrank(bob);
        vm.expectRevert(VaultManager.DebtBelowMinimum.selector);
        vm_.openPosition(COLL, MIN_DEBT - 1, 0, 0);
        vm.expectRevert(VaultManager.CollateralTooLarge.selector);
        vm_.openPosition(uint256(type(uint128).max) + 1, DEBT, 0, 0);
        vm_.openPosition(type(uint128).max, DEBT, 0, 0); // the cap itself is fine
        vm.stopPrank();
    }

    function test_open_checkOrder() public {
        _shutdown();
        vm.startPrank(alice);
        vm.expectRevert(SystemShutdown.selector); // before the debt check
        vm_.openPosition(uint256(type(uint128).max) + 1, 0, 0, 0);
        vm.stopPrank();
    }

    function test_open_debtCheckBeforeCollateralCapBeforePrice() public {
        seq.setStatus(1, NOW); // price unusable
        vm.startPrank(alice);
        vm.expectRevert(VaultManager.DebtBelowMinimum.selector);
        vm_.openPosition(uint256(type(uint128).max) + 1, 1, 0, 0);
        vm.expectRevert(VaultManager.CollateralTooLarge.selector);
        vm_.openPosition(uint256(type(uint128).max) + 1, DEBT, 0, 0);
        vm.expectRevert(PriceUnusable.selector);
        vm_.openPosition(1, DEBT, 0, 0); // price before the ICR check
        vm.stopPrank();
    }

    function test_open_propagatesStaleHintAndSupplyCap() public {
        // StaleHint from the list: a 30-step list walk is exceeded
        for (uint256 i; i < 32; ++i) {
            _open(alice, COLL + i * 1e15, DEBT); // each new one has a higher NICR than the last: new head
        }
        vm.prank(bob);
        vm.expectRevert(SortedPositions.StaleHint.selector);
        vm_.openPosition(COLL - 1, DEBT, 32, 0); // belongs at the tail; upper hint 32 is the head
        weth.mint(bob, type(uint128).max);
        // SupplyCapExceeded from the token
        vm.prank(bob);
        vm.expectRevert(StableToken.SupplyCapExceeded.selector);
        vm_.openPosition(type(uint128).max, uint256(type(uint128).max), 0, 0);
    }

    // ------------------------------------------------------------------ addCollateral

    function test_addCollateral_anyoneCanAndStakeFollows() public {
        _open(alice, COLL, DEBT);
        vm.expectEmit(address(vm_));
        emit VaultManager.CollateralAdded(1, bob, 1e18);
        vm.expectEmit(address(vm_));
        emit VaultManager.PositionUpdated(1, COLL + 1e18, DEBT, COLL + 1e18, 0, 0, 1, 2);
        vm.prank(bob);
        vm_.addCollateral(1, 1e18, 0, 0);
        assertEq(_st(1).coll, COLL + 1e18);
        assertEq(vm_.totalCollateral(), COLL + 1e18);
        assertEq(vm_.totalStakes(), COLL + 1e18);
        assertEq(weth.balanceOf(address(vm_)), COLL + 1e18 + GAS_RESERVE);
    }

    function test_addCollateral_errorsInOrder() public {
        vm.startPrank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vm_.addCollateral(1, 0, 0, 0); // ZeroAmount before PositionNotActive
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        vm_.addCollateral(1, 1, 0, 0);
        vm.stopPrank();
        weth.mint(alice, type(uint128).max);
        _open(alice, type(uint128).max, DEBT);
        vm.prank(bob);
        vm.expectRevert(VaultManager.CollateralTooLarge.selector);
        vm_.addCollateral(1, 1, 0, 0);
        _settle();
        vm.prank(bob);
        vm.expectRevert(SystemSettled.selector);
        vm_.addCollateral(1, 0, 0, 0); // SystemSettled before ZeroAmount
    }

    function test_addCollateral_worksInTheWindow() public {
        _open(alice, COLL, DEBT);
        _shutdown();
        vm.prank(bob);
        vm_.addCollateral(1, 1, 0, 0);
        assertEq(_st(1).coll, COLL + 1);
    }

    // ------------------------------------------------------------------ withdrawCollateral

    function test_withdraw_toOwnerKeepingMcr() public {
        _open(alice, COLL, DEBT);
        uint256 maxOut = COLL - _minColl(DEBT);
        uint256 before = weth.balanceOf(alice);
        vm.expectEmit(address(vm_));
        emit VaultManager.CollateralWithdrawn(1, maxOut);
        vm.prank(alice);
        vm_.withdrawCollateral(1, maxOut, 0, 0); // down to exactly MCR
        assertEq(weth.balanceOf(alice), before + maxOut);
        assertEq(_st(1).coll, COLL - maxOut);
        assertEq(_st(1).stake, COLL - maxOut);
        vm.prank(alice);
        vm.expectRevert(VaultManager.IcrBelowMcr.selector);
        vm_.withdrawCollateral(1, 1, 0, 0);
    }

    function test_withdraw_errorsInOrder() public {
        _open(alice, COLL, DEBT);
        vm.startPrank(bob);
        vm.expectRevert(ZeroAmount.selector); // a non-owner gets ZeroAmount, not NotOwner (§2.5)
        vm_.withdrawCollateral(1, 0, 0, 0);
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        vm_.withdrawCollateral(2, 1, 0, 0);
        vm.expectRevert(VaultManager.NotOwner.selector);
        vm_.withdrawCollateral(1, 1, 0, 0);
        vm.stopPrank();
        seq.setStatus(1, NOW);
        vm.prank(alice);
        vm.expectRevert(PriceUnusable.selector); // price before InsufficientCollateral
        vm_.withdrawCollateral(1, COLL + 1, 0, 0);
        seq.setStatus(0, NOW - 100_000);
        vm.prank(alice);
        vm.expectRevert(VaultManager.InsufficientCollateral.selector);
        vm_.withdrawCollateral(1, COLL + 1, 0, 0);
        _shutdown();
        vm.prank(alice);
        vm.expectRevert(SystemShutdown.selector);
        vm_.withdrawCollateral(1, 0, 0, 0);
    }

    // ------------------------------------------------------------------ borrow

    function test_borrow_mintsToOwnerUpToMcr() public {
        _open(alice, COLL, DEBT);
        uint256 maxDebt = (COLL * PRICE) / MCR; // floor: coll·price ≥ MCR·debt
        uint256 more = maxDebt - DEBT;
        vm.expectEmit(address(vm_));
        emit VaultManager.Borrowed(1, more, more);
        vm.prank(alice);
        vm_.borrow(1, more, 0, 0);
        assertEq(token.balanceOf(alice), maxDebt);
        assertEq(_st(1).normDebt, maxDebt);
        assertEq(vm_.totalNormDebt(), maxDebt);
        vm.prank(alice);
        vm.expectRevert(VaultManager.IcrBelowMcr.selector);
        vm_.borrow(1, 1, 0, 0);
    }

    function test_borrow_errorsInOrder() public {
        _open(alice, COLL, DEBT);
        vm.startPrank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vm_.borrow(1, 0, 0, 0);
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        vm_.borrow(7, 1, 0, 0);
        vm.expectRevert(VaultManager.NotOwner.selector);
        vm_.borrow(1, 1, 0, 0);
        vm.stopPrank();
        seq.setStatus(1, NOW);
        vm.prank(alice);
        vm.expectRevert(PriceUnusable.selector);
        vm_.borrow(1, 1, 0, 0);
        _shutdown();
        vm.prank(alice);
        vm.expectRevert(SystemShutdown.selector);
        vm_.borrow(1, 0, 0, 0);
    }

    // ------------------------------------------------------------------ repay

    function test_repay_anyoneDownToMinDebtExactly() public {
        _open(alice, COLL, DEBT);
        vm.prank(alice);
        token.transfer(bob, DEBT);
        uint256 maxRepay = DEBT - MIN_DEBT;
        vm.expectEmit(address(vm_));
        emit VaultManager.Repaid(1, bob, maxRepay, maxRepay);
        vm.prank(bob);
        vm_.repay(1, maxRepay, 0, 0);
        assertEq(vm_.debtOf(1), MIN_DEBT);
        assertEq(token.balanceOf(bob), DEBT - maxRepay);
        assertEq(token.totalSupply(), MIN_DEBT);
        vm.prank(bob);
        vm.expectRevert(VaultManager.RepayExceedsMaximum.selector);
        vm_.repay(1, 1, 0, 0);
    }

    function test_repay_errorsInOrder() public {
        vm.startPrank(bob);
        vm.expectRevert(ZeroAmount.selector);
        vm_.repay(1, 0, 0, 0);
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        vm_.repay(1, 1, 0, 0);
        vm.stopPrank();
        _open(alice, COLL, DEBT);
        vm.prank(bob); // bob holds nothing
        vm.expectRevert(InsufficientBalance.selector);
        vm_.repay(1, 1, 0, 0);
        vm.prank(bob);
        vm.expectRevert(VaultManager.RepayExceedsMaximum.selector); // before the balance check
        vm_.repay(1, DEBT, 0, 0);
        _settle();
        vm.prank(alice);
        vm.expectRevert(SystemSettled.selector);
        vm_.repay(1, 0, 0, 0);
    }

    // ------------------------------------------------------------------ close

    function test_close_burnsExactDebtAndReturnsCollateralAndReserve() public {
        _open(alice, COLL, DEBT);
        uint256 before = weth.balanceOf(alice);
        vm.expectEmit(address(vm_));
        emit VaultManager.PositionClosed(1, DEBT, COLL, GAS_RESERVE);
        vm.expectEmit(address(vm_));
        emit VaultManager.PositionUpdated(1, 0, 0, 0, 0, 0, 2, 6);
        vm.prank(alice);
        vm_.close(1);
        assertEq(weth.balanceOf(alice), before + COLL + GAS_RESERVE);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
        assertEq(weth.balanceOf(address(vm_)), 0);
        assertEq(vm_.activeCount(), 0);
        assertEq(vm_.totalNormDebt(), 0);
        assertEq(vm_.totalCollateral(), 0);
        assertEq(vm_.totalStakes(), 0);
        assertFalse(sorted.contains(1));
        assertEq(uint8(_st(1).status), 2);
    }

    function test_close_errorsInOrder() public {
        vm.prank(alice);
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        vm_.close(1);
        _open(alice, COLL, DEBT);
        vm.prank(bob);
        vm.expectRevert(VaultManager.NotOwner.selector);
        vm_.close(1);
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        vm_.close(1);
        _settle();
        vm.prank(alice);
        vm.expectRevert(SystemSettled.selector);
        vm_.close(1);
    }

    function test_close_worksInTheWindowAndBelowMcr() public {
        _open(alice, _minColl(DEBT), DEBT);
        _setPrice(1000e18); // far below MCR now
        _shutdown();
        vm.prank(alice);
        vm_.close(1);
        assertEq(uint8(_st(1).status), 2);
    }

    /// @dev The prompt's dust pitfall: open rounds up, repay rounds down — close still works.
    function testFuzz_close_alwaysPossibleAfterRepays(uint256 a1, uint256 a2, uint256 a3) public {
        _open(alice, 10e18, 10_000e18);
        uint256[3] memory r = [a1, a2, a3];
        for (uint256 i; i < 3; ++i) {
            uint256 room = vm_.debtOf(1) - MIN_DEBT;
            if (room == 0) break;
            uint256 amt = bound(r[i], 1, room);
            vm.prank(alice);
            vm_.repay(1, amt, 0, 0);
        }
        uint256 owed = vm_.debtOf(1);
        assertGe(token.balanceOf(alice), owed);
        vm.prank(alice);
        vm_.close(1);
        assertEq(vm_.totalNormDebt(), 0);
        assertEq(token.totalSupply(), token.balanceOf(alice)); // what remains is alice's surplus
    }

    // ------------------------------------------------------------------ reclaimGasReserve and hooks

    function test_hooks_shutdownSettleReclaim() public {
        _open(alice, COLL, DEBT);
        _open(bob, COLL, DEBT);
        vm.prank(alice);
        vm.expectRevert(NotSettled.selector);
        vm_.reclaimGasReserve(1);
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        vm_.onShutdown();
        vm.prank(SHUTDOWN);
        vm.expectRevert(NotTriggered.selector);
        vm_.onSettlement();
        vm.expectEmit(address(vm_));
        emit VaultManager.VaultShutdown(1e27);
        _shutdown();
        assertTrue(vm_.shutdown());
        vm.prank(SHUTDOWN);
        vm.expectRevert(SystemShutdown.selector);
        vm_.onShutdown();
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        vm_.onSettlement();
        vm.expectEmit(address(vm_));
        emit VaultManager.VaultSettled(2 * COLL, 2);
        vm.prank(SHUTDOWN);
        uint256 coll = vm_.onSettlement();
        assertEq(coll, 2 * COLL);
        assertEq(weth.balanceOf(SHUTDOWN), 2 * COLL);
        assertEq(weth.balanceOf(address(vm_)), 2 * GAS_RESERVE);
        assertEq(vm_.totalCollateral(), 0);
        vm.prank(SHUTDOWN);
        vm.expectRevert(AlreadySettled.selector);
        vm_.onSettlement();
        // reclaim
        vm.prank(bob);
        vm.expectRevert(VaultManager.NotOwner.selector);
        vm_.reclaimGasReserve(1);
        uint256 before = weth.balanceOf(alice);
        vm.expectEmit(address(vm_));
        emit VaultManager.GasReserveReclaimed(1, alice, GAS_RESERVE);
        vm.prank(alice);
        vm_.reclaimGasReserve(1);
        assertEq(weth.balanceOf(alice), before + GAS_RESERVE);
        assertEq(uint8(_st(1).status), 5);
        assertEq(vm_.activeCount(), 1);
        vm.prank(alice);
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        vm_.reclaimGasReserve(1);
    }

    /// @dev The hooks check the caller before their own state (§5.1.11), in states where the order
    ///      matters (review V-5).
    function test_hooks_callerCheckedBeforeState() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // not NotTriggered
        vm_.onSettlement();
        _shutdown();
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // not SystemShutdown
        vm_.onShutdown();
    }

    /// @dev Checked arithmetic on absurd inputs panics (0x11), as the literal pseudocode does; the
    ///      model raises Overflow for the same inputs (review V-2).
    function test_overflow_panicsOnAbsurdInputs() public {
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError); // MCR · debtOf(n) overflows
        vm_.openPosition(1e18, 2 ** 200, 0, 0);
        _open(alice, COLL, DEBT);
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError); // p.coll + amount overflows
        vm_.addCollateral(1, type(uint256).max, 0, 0);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError); // MCR · debtOf(normDebt + dn) overflows
        vm_.borrow(1, 2 ** 255, 0, 0);
    }

    // ------------------------------------------------------------------ views

    function test_views() public {
        _open(alice, COLL, DEBT);
        (uint256 c, uint256 n) = vm_.effective(1);
        assertEq(c, COLL);
        assertEq(n, DEBT);
        (c, n) = vm_.sortKey(1);
        assertEq(c + n, COLL + DEBT);
        assertEq(vm_.currentIndex(), 1e27);
        assertEq(vm_.debtOf(1), DEBT);
        assertEq(vm_.icr(1, PRICE), 2e18);
        assertEq(vm_.icr(9, PRICE), type(uint256).max); // no debt
        assertEq(vm_.nicr(1), COLL * 1e20 / DEBT);
        assertFalse(vm_.isLiquidatable(1, PRICE));
        assertTrue(vm_.isLiquidatable(1, 1000e18)); // ICR 1.0 < MCR
        assertFalse(vm_.isLiquidatable(9, 1)); // not active
        assertEq(vm_.systemColl(), COLL);
        assertEq(vm_.systemDebt(), DEBT);
        assertEq(vm_.tcr(PRICE), 2e18);
        ledger.set(1e18, 10e18, 20e18);
        assertEq(vm_.systemColl(), COLL + 1e18);
        assertEq(vm_.systemDebt(), DEBT + 30e18);
        vm.prank(alice);
        vm_.close(1);
        ledger.set(0, 0, 0);
        assertEq(vm_.tcr(PRICE), type(uint256).max);
    }
}

/// @notice Deployment B: the house's lot counts towards system collateral.
contract VaultManagerVariantBTest is VaultFixture {
    function setUp() public override {
        variantB = true;
        super.setUp();
    }

    function test_systemCollIncludesTheHouseLotInB() public {
        _open(alice, 4e18, 4000e18);
        house.set(3e18);
        assertEq(vm_.systemColl(), 7e18);
        assertEq(vm_.stabilityPool(), address(0));
        assertEq(vm_.POOL_SHARE_BPS(), 0);
    }
}
