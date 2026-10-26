// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StableToken} from "../../src/core/StableToken.sol";
import {InsufficientBalance, InvalidParameter, Unauthorized, ZeroAmount} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {PoolFixture} from "../utils/PoolFixture.sol";
import {PoolTestVault, SettledLedger, StabilityPoolHarness} from "../utils/PoolMocks.sol";
import {MockWETH} from "../utils/VaultMocks.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice StabilityPool (spec §4.4, §5.3, §6.6): construction and wiring, every revert, the
///         depositor functions, `onLiquidation`'s branches, `onInterest`'s decline, epochs, scales,
///         the dust sweep and the lock. Vectors: test/vectors/ProductSumVectors.t.sol.
contract StabilityPoolTest is PoolFixture {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant OWNER = address(0x0E);
    uint256 internal constant FUNDS = 1e30;
    uint256 internal constant PRICE = 2000e18;

    function setUp() public {
        _deployPool(MIN_DEPOSIT);
        _fund(ALICE, FUNDS);
        _fund(BOB, FUNDS);
        _fund(CAROL, FUNDS);
    }

    // ------------------------------------------------------------------ constructor, wire (§3.4)

    function test_constructor_storesParameters() public view {
        assertEq(address(pool.WETH()), address(weth));
        assertEq(address(pool.token()), address(token));
        assertEq(pool.LIQUIDATION_PENALTY(), PENALTY);
        assertEq(pool.MIN_DEPOSIT(), MIN_DEPOSIT);
        assertEq(pool.P(), 1e36);
        assertEq(pool.P_MIN(), 1e27);
        assertEq(pool.deployer(), address(this));
    }

    function test_constructor_argumentChecks_inOrder() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 0));
        new StabilityPool(address(0), address(0), 0.6e18, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 1));
        new StabilityPool(address(weth), address(0), 0.6e18, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 2));
        new StabilityPool(address(weth), address(token), 0.5e18 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 3));
        new StabilityPool(address(weth), address(token), 0.5e18, 1e18 - 1);
        StabilityPool p = new StabilityPool(address(weth), address(token), 0.5e18, 1e18); // both bounds
        // inclusive
        assertEq(p.MIN_DEPOSIT(), 1e18);
    }

    function test_wire_checks() public {
        StabilityPool p = new StabilityPool(address(weth), address(token), PENALTY, MIN_DEPOSIT);
        vm.prank(ALICE);
        vm.expectRevert(WiredBase.NotDeployer.selector);
        p.wire(address(tv), address(ledger));
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 0));
        p.wire(address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 1));
        p.wire(address(tv), address(0));
        address[] memory addrs = new address[](2);
        (addrs[0], addrs[1]) = (address(tv), address(ledger));
        vm.expectEmit(address(p));
        emit WiredBase.Wired(addrs);
        p.wire(address(tv), address(ledger));
        assertEq(p.vaultManager(), address(tv));
        assertEq(address(p.deficitLedger()), address(ledger));
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        p.wire(address(tv), address(ledger));
    }

    function test_everyMutator_notWired_reverts() public {
        StabilityPool p = new StabilityPool(address(weth), address(token), PENALTY, MIN_DEPOSIT);
        vm.expectRevert(WiredBase.NotWired.selector);
        p.deposit(1e18);
        vm.expectRevert(WiredBase.NotWired.selector);
        p.withdraw(1e18);
        vm.expectRevert(WiredBase.NotWired.selector);
        p.claimGains();
        vm.expectRevert(WiredBase.NotWired.selector);
        p.onLiquidation(1, OWNER, 1, 1, PRICE);
        vm.expectRevert(WiredBase.NotWired.selector);
        p.onInterest(1);
    }

    // ------------------------------------------------------------------ deposit (§5.3.1)

    function test_deposit_zero_revertsZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(ZeroAmount.selector);
        pool.deposit(0);
    }

    function test_deposit_belowMinimum_revertsDepositTooSmall() public {
        vm.prank(ALICE);
        vm.expectRevert(StabilityPool.DepositTooSmall.selector);
        pool.deposit(MIN_DEPOSIT - 1);
        _deposit(ALICE, MIN_DEPOSIT); // exactly the minimum
        assertEq(pool.compoundedDeposit(ALICE), MIN_DEPOSIT);
    }

    function test_deposit_topUpOfOneWei_allowedAboveMinimum() public {
        _deposit(ALICE, MIN_DEPOSIT);
        _deposit(ALICE, 1);
        assertEq(pool.compoundedDeposit(ALICE), MIN_DEPOSIT + 1);
        assertEq(pool.depositorCount(0), 1, "a top-up does not count twice");
    }

    function test_deposit_insufficientBalance_reverts() public {
        address poor = address(0xD00D);
        _fund(poor, 5e18);
        vm.prank(poor);
        vm.expectRevert(InsufficientBalance.selector);
        pool.deposit(5e18 + 1);
    }

    function test_deposit_accruesFirst_andPullsWithoutApproval() public {
        uint256 calls = tv.accrueCalls();
        vm.expectEmit(address(pool));
        emit StabilityPool.DepositUpdated(ALICE, 10e18, 1e36, 0, 0, 0, 0);
        vm.expectEmit(address(pool));
        emit StabilityPool.GainsPaid(ALICE, 0, 0);
        _deposit(ALICE, 10e18);
        assertEq(tv.accrueCalls(), calls + 1, "accrued");
        assertEq(token.balanceOf(address(pool)), 10e18);
        assertEq(token.balanceOf(ALICE), FUNDS - 10e18);
        assertEq(pool.totalDeposits(), 10e18);
        assertEq(pool.getTotalDeposits(), 10e18);
        assertEq(pool.depositorCount(0), 1);
    }

    function test_deposit_interestBookedDuringAccrual_goesToExistingDepositorsOnly() public {
        _deposit(ALICE, 10e18);
        tv.setPendingInterest(3e18); // booked inside bob's deposit, before his snapshot
        _deposit(BOB, 10e18);
        (, uint256 ia) = pool.gains(ALICE);
        (, uint256 ib) = pool.gains(BOB);
        assertEq(ia, 3e18, "all of it to alice");
        assertEq(ib, 0, "none to bob");
    }

    function test_deposit_paysPendingGainsFirst() public {
        _deposit(ALICE, 10e18);
        tv.offset(4e18, 1e18);
        tv.interest(2e18);
        (uint256 cg, uint256 ig) = pool.gains(ALICE);
        assertEq(cg, 1e18);
        // R15: perUnit = floor(2e18·1e18 / 6e18) = 333…333 (18 threes); G = perUnit · 0.6e36, so the
        // gain is floor(10e18 · 0.6 · 333…333 / 1e18) = 1,999,999,999,999,999,998
        assertEq(ig, 1_999_999_999_999_999_998);
        uint256 wethBefore = weth.balanceOf(ALICE);
        _deposit(ALICE, 1e18);
        assertEq(weth.balanceOf(ALICE) - wethBefore, 1e18, "collateral gain paid");
        assertEq(pool.compoundedDeposit(ALICE), 7e18, "6 compounded + 1");
        (cg, ig) = pool.gains(ALICE);
        assertEq(cg + ig, 0, "re-snapshotted");
        assertEq(pool.collGainsBalance(), 0);
        assertEq(pool.interestGainsBalance(), 2, "the floored 2 wei stay as dust (sum paid <= balance)");
    }

    // ------------------------------------------------------------------ withdraw (§5.3.2)

    function test_withdraw_zero_revertsZeroAmount() public {
        _deposit(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(ZeroAmount.selector);
        pool.withdraw(0);
    }

    function test_withdraw_noDeposit_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(StabilityPool.NoDeposit.selector);
        pool.withdraw(1);
    }

    function test_withdraw_remainderBelowMinimum_reverts() public {
        _deposit(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(StabilityPool.DepositTooSmall.selector);
        pool.withdraw(10e18 - MIN_DEPOSIT + 1);
        _withdraw(ALICE, 10e18 - MIN_DEPOSIT); // leaves exactly the minimum
        assertEq(pool.compoundedDeposit(ALICE), MIN_DEPOSIT);
    }

    function test_withdraw_capsAtCompounded_andMaxLeaves() public {
        _deposit(ALICE, 10e18);
        _deposit(BOB, 30e18);
        tv.offset(20e18, 0);
        assertEq(pool.compoundedDeposit(ALICE), 5e18);
        uint256 before = token.balanceOf(ALICE);
        vm.expectEmit(address(pool));
        emit StabilityPool.DepositUpdated(ALICE, 0, pool.P(), 0, 0, 0, 0);
        _withdraw(ALICE, 1e30); // more than the compounded value
        assertEq(token.balanceOf(ALICE) - before, 5e18, "capped");
        (uint256 initial,,,,,) = pool.deposits(ALICE);
        assertEq(initial, 0, "record deleted");
        assertEq(pool.depositorCount(0), 1);
        assertEq(pool.totalDeposits(), 15e18);
    }

    function test_withdraw_lastDepositorSweepsResidualToLedger() public {
        _deposit(ALICE, 1e18);
        _deposit(BOB, 3e18 + 1);
        tv.offset(1e18 + 3, 0);
        _withdraw(ALICE, type(uint256).max);
        uint256 residual = pool.totalDeposits() - pool.compoundedDeposit(BOB);
        assertGt(residual, 0, "rounding leaves a residual");
        vm.expectEmit(address(pool));
        emit StabilityPool.PoolDustSwept(residual);
        _withdraw(BOB, type(uint256).max);
        assertEq(pool.totalDeposits(), 0);
        assertEq(ledger.reserve(), residual);
        assertEq(token.balanceOf(address(ledger)), residual);
        assertEq(pool.depositorCount(0), 0);
    }

    function test_withdraw_sweepSkipped_afterLedgerSettled() public {
        MockWETH w = new MockWETH();
        StableToken t = new StableToken("T", "T");
        PoolTestVault v2 = new PoolTestVault(w, t);
        StabilityPoolHarness p = new StabilityPoolHarness(address(w), address(t), PENALTY, MIN_DEPOSIT);
        SettledLedger settled = new SettledLedger();
        v2.setPool(p);
        t.wire(address(v2), address(p), address(settled), makeAddr("shutdown"));
        p.wire(address(v2), address(settled));
        v2.mintTo(ALICE, 10e18);
        v2.mintTo(BOB, 10e18);
        vm.prank(ALICE);
        p.deposit(1e18);
        vm.prank(BOB);
        p.deposit(3e18 + 1);
        v2.offset(1e18 + 3, 0);
        vm.prank(ALICE);
        p.withdraw(type(uint256).max);
        uint256 residual = p.totalDeposits() - p.compoundedDeposit(BOB);
        vm.prank(BOB);
        p.withdraw(type(uint256).max);
        assertEq(p.totalDeposits(), residual, "residual stays, inert");
        assertEq(p.depositorCount(0), 0);
    }

    // ------------------------------------------------------------------ claimGains (§5.3.3)

    function test_claimGains_noDeposit_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(StabilityPool.NoDeposit.selector);
        pool.claimGains();
    }

    function test_claimGains_paysAndKeepsDeposit_belowMinimumAllowed() public {
        _deposit(ALICE, 2e18);
        tv.offset(1.5e18, 0.3e18); // compounded 0.5e18 < MIN_DEPOSIT
        vm.prank(ALICE);
        pool.claimGains();
        assertEq(weth.balanceOf(ALICE), 0.3e18);
        assertEq(pool.compoundedDeposit(ALICE), 0.5e18, "unchanged, minimum not applied");
        (uint256 cg, uint256 ig) = pool.gains(ALICE);
        assertEq(cg + ig, 0);
    }

    function test_claimGains_afterEpochChange_leavesWithoutSweep() public {
        _deposit(ALICE, 10e18);
        tv.offset(10e18, 1e18); // d == T: epoch 1
        assertEq(pool.currentEpoch(), 1);
        assertEq(pool.compoundedDeposit(ALICE), 0);
        vm.prank(ALICE);
        pool.claimGains();
        assertEq(weth.balanceOf(ALICE), 1e18, "old-epoch gain paid");
        (uint256 initial,,,,,) = pool.deposits(ALICE);
        assertEq(initial, 0, "left");
        assertEq(pool.depositorCount(0), 1, "an old-epoch record leaves epoch 0's count alone");
        assertEq(ledger.reserve(), 0);
    }

    // ------------------------------------------------------------------ offset (§6.6.2)

    function test_offset_singleDepositor_exactValues() public {
        _deposit(ALICE, 100e18);
        tv.offset(25e18, 2e18);
        assertEq(pool.P(), 0.75e36);
        assertEq(pool.compoundedDeposit(ALICE), 75e18);
        (uint256 cg,) = pool.gains(ALICE);
        assertEq(cg, 2e18);
        assertEq(token.balanceOf(address(pool)), 75e18, "burned");
    }

    function test_offset_equalToTotal_newEpoch() public {
        _deposit(ALICE, 10e18);
        _deposit(BOB, 30e18);
        vm.expectEmit(address(pool));
        emit StabilityPool.PoolOffset(40e18, 4e18, 1e17, 0, 1e36, 1, 0, 0);
        tv.offset(40e18, 4e18);
        assertEq(pool.currentEpoch(), 1);
        assertEq(pool.currentScale(), 0);
        assertEq(pool.P(), 1e36);
        assertEq(pool.totalDeposits(), 0);
        assertEq(pool.compoundedDeposit(ALICE), 0);
        (uint256 ca,) = pool.gains(ALICE);
        (uint256 cb,) = pool.gains(BOB);
        assertEq(ca, 1e18);
        assertEq(cb, 3e18);
        assertFalse(pool.acceptsInterest());
    }

    function test_offset_depositAfterEpochChange_startsFresh() public {
        _deposit(ALICE, 10e18);
        tv.offset(10e18, 1e18);
        _deposit(BOB, 5e18);
        assertEq(pool.depositorCount(1), 1);
        tv.offset(1e18, 1e18);
        assertEq(pool.compoundedDeposit(BOB), 4e18);
        (uint256 cb,) = pool.gains(BOB);
        assertEq(cb, 1e18, "all of the new epoch's gain");
        (uint256 ca,) = pool.gains(ALICE);
        assertEq(ca, 1e18, "alice keeps only her old-epoch gain");
        _deposit(ALICE, 2e18); // alice re-enters epoch 1; her old-epoch gain is paid
        assertEq(weth.balanceOf(ALICE), 1e18);
        assertEq(pool.depositorCount(1), 2);
        assertEq(pool.compoundedDeposit(ALICE), 2e18);
    }

    function test_offset_scaleChange_whenPFallsBelowPMin() public {
        _deposit(ALICE, 300e18);
        tv.offset(300e18 - 3e9, 0); // T − d = 3e9: P = 1e36 · 1e-11 < P_MIN
        assertEq(pool.currentScale(), 1);
        assertEq(pool.P(), 1e34, "rescaled by SCALE_FACTOR");
        assertEq(pool.compoundedDeposit(ALICE), 3e9);
    }

    function test_offset_manyTinyRemainders_crossSeveralScales_PStaysInRange() public {
        _fund(CAROL, 40e30);
        _deposit(ALICE, 1e30);
        _deposit(BOB, 1e30);
        uint256 maxScale;
        for (uint256 i; i < 40; ++i) {
            uint256 t = pool.totalDeposits();
            tv.offset(t - 1, t / 1000); // leave 1 wei each time; collateral 0.1 % of the debt
            assertGe(pool.P(), pool.P_MIN(), "P >= P_MIN");
            assertLe(pool.P(), pool.P_PRECISION(), "P <= P_PRECISION");
            assertLe(
                pool.compoundedDeposit(ALICE) + pool.compoundedDeposit(BOB), pool.totalDeposits(), "sum <= T"
            );
            if (pool.currentScale() > maxScale) maxScale = pool.currentScale();
            _deposit(CAROL, 1e30); // refill so the next offset can again leave 1 wei
        }
        assertGt(maxScale, 5, "crossed more scales than the compounding horizon");
        assertEq(pool.compoundedDeposit(ALICE), 0, "more than five scales: 0");
        (uint256 ca,) = pool.gains(ALICE);
        assertGt(ca, 0, "gains from the scales up to SCALE_SPAN remain");
    }

    function test_offset_manyTinyOffsets_keepTotalsConsistent() public {
        _deposit(ALICE, 3e18);
        _deposit(BOB, 7e18 + 1);
        for (uint256 i; i < 200; ++i) {
            tv.offset(1e15 + i, 3e11 + i);
        }
        (uint256 ca,) = pool.gains(ALICE);
        (uint256 cb,) = pool.gains(BOB);
        assertLe(ca + cb, pool.collGainsBalance(), "sum of gains <= balance");
        assertLe(pool.compoundedDeposit(ALICE) + pool.compoundedDeposit(BOB), pool.totalDeposits());
        _withdraw(ALICE, type(uint256).max);
        _withdraw(BOB, type(uint256).max);
        assertEq(pool.totalDeposits(), 0, "residual swept");
        assertEq(weth.balanceOf(address(pool)), pool.collGainsBalance(), "I1 WETH");
    }

    // ------------------------------------------------------------------ onLiquidation (§6.6.4)

    function test_onLiquidation_onlyVault() public {
        vm.expectRevert(Unauthorized.selector);
        pool.onLiquidation(1, OWNER, 1e18, 1e18, PRICE);
    }

    function test_onLiquidation_surplusToOwner_fullOffset() public {
        _deposit(ALICE, 10_000e18);
        uint256 debt = 2000e18;
        uint256 coll = 1.5e18; // seized = 2000 · 1.05 / 2000 = 1.05 WETH
        vm.expectEmit(address(pool));
        emit StabilityPool.PoolLiquidation(7, debt, coll, 1.05e18, 0.45e18, debt, 1.05e18, 0);
        (uint256 absorbed, uint256 returned) = tv.liquidate(7, OWNER, debt, coll, PRICE);
        assertEq(absorbed, debt);
        assertEq(returned, 0);
        assertEq(weth.balanceOf(OWNER), 0.45e18, "surplus");
        assertEq(pool.collGainsBalance(), 1.05e18);
        assertEq(pool.totalDeposits(), 8000e18);
    }

    function test_onLiquidation_seizedRoundsUp() public {
        _deposit(ALICE, 10_000e18);
        // debt·1.05/price = 1e18·1.05e18/3e21 = 3.5e14 exactly; one wei more debt rounds up
        tv.liquidate(1, OWNER, 1e18 + 1, 1e18, 3000e18);
        assertEq(pool.collGainsBalance(), 350_000_000_000_001, "ceil");
        assertEq(weth.balanceOf(OWNER), 1e18 - 350_000_000_000_001, "surplus rounds down");
    }

    function test_onLiquidation_icrBelowOnePlusPenalty_seizesAll() public {
        _deposit(ALICE, 10_000e18);
        tv.liquidate(1, OWNER, 2000e18, 1.04e18, PRICE);
        assertEq(weth.balanceOf(OWNER), 0, "no surplus");
        assertEq(pool.collGainsBalance(), 1.04e18);
    }

    function test_onLiquidation_partialOffset_returnsRest() public {
        _deposit(ALICE, 1000e18);
        uint256 debt = 4000e18;
        uint256 coll = 3e18; // seized 2.1
        (uint256 absorbed, uint256 returned) = tv.liquidate(1, OWNER, debt, coll, PRICE);
        assertEq(absorbed, 1000e18);
        assertEq(returned, 2.1e18 - 0.525e18, "seized - mulDivDown(seized, T, debt)");
        assertEq(weth.balanceOf(address(tv)), returned, "returned to the VaultManager");
        assertEq(weth.balanceOf(OWNER), 0.9e18);
        assertEq(pool.currentEpoch(), 1, "pool emptied exactly");
    }

    function test_onLiquidation_emptyPool_returnsAllSeized() public {
        (uint256 absorbed, uint256 returned) = tv.liquidate(1, OWNER, 2000e18, 1.5e18, PRICE);
        assertEq(absorbed, 0);
        assertEq(returned, 1.05e18);
        assertEq(weth.balanceOf(OWNER), 0.45e18);
        assertEq(pool.collGainsBalance(), 0);
        assertEq(pool.currentEpoch(), 0, "no offset");
    }

    // ------------------------------------------------------------------ onInterest (§6.6.5, ADR-0033)

    function test_onInterest_onlyVault() public {
        vm.expectRevert(Unauthorized.selector);
        pool.onInterest(1);
    }

    function test_onInterest_belowMinimum_declinesWithoutStateChange() public {
        assertFalse(pool.acceptsInterest());
        vm.prank(address(tv));
        assertFalse(pool.onInterest(5e18));
        assertEq(pool.interestGainsBalance(), 0);
        assertEq(pool.epochToScaleToG(0, 0), 0);
        assertEq(pool.lastInterestError(), 0);
    }

    function test_onInterest_books_withCarry() public {
        _deposit(ALICE, 3e18);
        assertTrue(pool.acceptsInterest());
        vm.expectEmit(address(pool));
        emit StabilityPool.PoolInterest(1e18, 333_333_333_333_333_333, 1e18);
        assertTrue(tv.interest(1e18));
        assertEq(pool.lastInterestError(), 1e18, "1e36 mod 3e18");
        (, uint256 ig) = pool.gains(ALICE);
        assertEq(ig, 1e18 - 1, "floor");
    }

    function test_onInterest_isLockFree_fromInsideADepositorCall() public {
        _deposit(ALICE, 3e18);
        tv.setPendingInterest(1e18);
        _deposit(BOB, 3e18); // accrue → onInterest while the pool lock is held
        assertEq(pool.interestGainsBalance(), 1e18);
    }

    // ------------------------------------------------------------------ gains across scales (§6.6.7)

    function test_gains_beyondScaleSpan_ignored() public {
        _fund(BOB, 10e30);
        _deposit(ALICE, 1e30);
        uint256 s = 0;
        // three scale changes, each with a collateral gain
        while (pool.currentScale() < 3) {
            uint256 t = pool.totalDeposits();
            tv.offset(t - t / 1e10, 1e18);
            if (pool.currentScale() > s) s = pool.currentScale();
            _deposit(BOB, 1e30);
        }
        (uint256 ca,) = pool.gains(ALICE);
        uint256 spanned =
            pool.epochToScaleToS(0, 0) + pool.epochToScaleToS(0, 1) / 1e9 + pool.epochToScaleToS(0, 2) / 1e18;
        assertEq(ca, (1e30 * spanned) / (1e36 * 1e18), "scale 3 not counted");
    }

    // ------------------------------------------------------------------ reentrancy (§5.10)

    function test_reentrantDepositorCall_reverts() public {
        _deposit(ALICE, 10e18);
        tv.setReenter(true);
        vm.prank(ALICE);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        pool.claimGains();
    }

    // ------------------------------------------------------------------ dust ledger stand-in

    function test_standInLedger_onPoolDust_onlyThePool() public {
        vm.expectRevert(Unauthorized.selector);
        ledger.onPoolDust(1);
        assertFalse(ledger.settled());
    }
}
