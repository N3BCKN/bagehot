// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../../src/core/VaultManager.sol";
import {DeficitLedger} from "../../../src/safety/DeficitLedger.sol";
import {CoreInvariantsTest} from "../../invariant/CoreInvariants.t.sol";
import {CoreHandler} from "../../invariant/handlers/CoreHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shrunk sequences from the P17 core campaign, kept as regression tests.
contract CoreHandlerRegressionsTest is Test {
    CoreHandler internal h;

    function setUp() public {
        address[5] memory a =
            [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        h = new CoreHandler(false, true, a);
    }

    /// @dev seed 1, `invariant_noUnexpectedReverts`: three redemptions.
    function test_regression_noUnexpectedReverts_threeRedemptions() public {
        h.redeem(
            181_028_234_842_801_944_645_364_655_805_779_955_686_651_398_165_299_396_165_583_056_437_650_126,
            5_180_713_137_735_200_809,
            type(uint256).max - 1,
            6
        );
        h.redeem(
            1_027_706_938_944_749_525,
            type(uint256).max - 1,
            27_187_852_786_614_913_484_402_881_988_503_578_956_416_999_219_309,
            0
        );
        h.redeem(25_000_000_000_000_000_000, type(uint256).max, 2884, 1);
        emit log_named_bytes32("last unexpected selector", bytes32(h.lastUnexpected()));
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
        (bool ok, string memory why) = h.checkI5();
        assertTrue(ok, why);
        (ok, why) = h.checkEventsAgree();
        assertTrue(ok, why);
    }

    /// @dev seed 1, `invariant_stateReconstructionMatchesEvents`: a warp, then a redemption across the tail.
    function test_regression_eventsAgree_warpThenRedeemAcrossTail() public {
        h.warp(59_722);
        h.redeemAcrossTail(40_573_461_213_158_192_708_994_244_156_591_364_986_780, 1, 61);
        emit log_named_uint("gN", h.gN());
        emit log_named_uint("eN", h.eN());
        emit log_named_uint("gX", h.gX());
        emit log_named_uint("eX", h.eX());
        emit log_named_uint("gY", h.gY());
        emit log_named_uint("eY", h.eY());
        emit log_named_uint("eventMismatches", h.eventMismatches());
        (bool ok, string memory why) = h.checkEventsAgree();
        assertTrue(ok, why);
    }

    /// @dev seed 1, `invariant_I5_redemptionLeavesHealthyPositions`.
    function test_regression_I5_lastVisitReason() public {
        h.warp(2670);
        h.addCollateral(4_171_706_153, 1e18, 100e18);
        h.close(type(uint128).max);
        h.redeemAcrossTail(42_673, 2463, 212);
        h.open(1e24, 7500, 3175);
        h.addCollateral(
            1,
            46_892_095_256_427_457_244_492_470_082_972_464_813_245_702_881_294_824_898_255_566_044_487_671,
            324_058_724_736_941_045_706_213_239_669_622_352_136_285_254
        );
        h.redeem(1e20, type(uint128).max, 11, 195);
        (bool ok, string memory why) = h.checkI5();
        assertTrue(ok, why);
    }

    /// @dev seed 2, `invariant_stateReconstructionMatchesEvents`: shutdown, settlement, reclaim.
    function test_regression_eventsAgree_reclaimCountsLikeItsEvent() public {
        h.toggleOracle(1); // healthy, a no-op: one exact step, which the first redistribution waits for
        h.redistribute(3); // A: the tolerance regime first, which the shutdown action now waits for
        h.triggerShutdown(1e24);
        h.settle(1e23);
        h.reclaimGasReserve(681);
        assertTrue(h.v().settled());
        (bool ok, string memory why) = h.checkEventsAgree();
        assertTrue(ok, why);
    }

    /// @dev seed 1, `invariant_stateReconstructionMatchesEvents`: a price move, a warp, a withdrawal.
    function test_regression_eventsAgree_withdrawAfterWarp() public {
        h.movePrice(6484);
        h.warp(1037);
        h.withdrawCollateral(10_265, 1350);
        emit log_named_uint("gN", h.gN());
        emit log_named_uint("eN", h.eN());
        emit log_named_uint("gX", h.gX());
        emit log_named_uint("eX", h.eX());
        emit log_named_uint("gY", h.gY());
        emit log_named_uint("eY", h.eY());
        (bool ok, string memory why) = h.checkEventsAgree();
        assertTrue(ok, why);
    }

    /// @dev seed 3, `invariant_I13_sortedByNicrWithinTolerance`: repeated redistributions, then opens
    ///      staked against the snapshots, then one more redistribution. Needed k ≈ 8,125 wei against
    ///      the old constant 4; passes the derived bound (CHG-008).
    function test_regression_I13_toleranceAfterRedistributions() public {
        h.open(
            5_347_112_886_857_638_443_658_839_180_355_339_843_844_330_071_223_294_650_856_412_030_066_056_770,
            1,
            39_181_578_471
        );
        h.redeemAcrossTail(4, 701_406_685, 171);
        h.redistribute(1.1e18);
        h.redistribute(9081);
        h.close(type(uint128).max);
        h.open(
            12_171_142_204_496_915_590_757_369_535_295_135_017_365_585_924_266_051_572_671_161_776_024_569_092,
            7_355_527_236_050_371_379_519_248_623_994_858_698_775_475_302_745_220_203,
            223_426_901_339
        );
        h.close(7711);
        h.redistribute(999_999_999_974_962_499_999_999_992_314);
        h.redistribute(420_587);
        h.redistribute(27_752_769_538_569_770_422_260);
        h.redistribute(137_122_462_167_341_575_662_000_267_002_353_578_582_749_290_296);
        h.redistribute(7868);
        h.redistribute(7120);
        h.redistribute(1e27);
        h.open(3e18, 1e24, 13_193);
        h.open(12e18, 6622, 3175);
        h.open(30_000e18, 933, 583_300_186);
        h.redistribute(905_839_459_370_670_479_260_830_490_730_922);
        _dumpList();
        (bool ok, string memory why) = h.checkI13();
        assertTrue(ok, why);
        // the sequence still reaches what it pins: redistributions ran, the list left the exact regime,
        // and the old constant k = 4 would fail it
        assertGt(h.redistributions(), 0, "redistributions ran");
        assertGt(h.stepsNonExact(), 0, "tolerance regime reached");
        assertGt(h.maxNeededK(), 4, "k = 4 fails this sequence");
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
    }

    /// @dev P21, seeds 1–3, A, `afterInvariant`'s I8 unwind: once the handler could donate to the pool,
    ///      the unwind still expected the pool's balances without donations (I8 step 3: D_w + residual).
    function test_regression_I8_unwindCountsPoolDonations() public {
        CoreInvariantsTest t = new CoreInvariantsTest();
        t.setUp();
        CoreHandler hh = t.handler();
        hh.donate(3, 146e15, false); // k = 3: WETH to the pool (A)
        assertEq(hh.donatedWeth(address(hh.pool())), 146e15);
        t.afterInvariant();
    }

    /// @dev P21, seed 3, A, `afterInvariant`: I13's tolerance regime not reached by call 100 — the run's
    ///      one `liquidate` was as-is (mode 7). `_reachTolerance` now runs a priced liquidation from call
    ///      50 until the run has redistributed.
    function test_regression_I13_toleranceReachedWithoutLiquidateCalls() public {
        for (uint256 i; i < 60; ++i) {
            h.toggleOracle(1); // healthy, a no-op
        }
        assertGt(h.stepsAllExact(), 0, "exact regime");
        assertGt(h.stepsNonExact(), 0, "tolerance regime");
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
    }

    /// @dev P21 audit (M2), deterministic reach in A: a no-stakes deficit with its collateral, a `cover`
    ///      that burns, then shutdown and settlement of the vault and the ledger — the handler's own
    ///      checks (I1 holders and sums, the pool, I2, I4/I6/I7 with event provenance, I8) after each step.
    function test_reach_deficitCoverSettle_checksHold() public {
        h.toggleOracle(1); // healthy, a no-op: one exact step
        h.liquidate(2, 2, false); // the tolerance regime first (pool thinned, redistributed)
        assertGt(h.stepsNonExact(), 0, "tolerance regime");
        for (uint256 i; i < 5; ++i) {
            h.poolWithdraw(i, 0, true); // empty the pool, so the last liquidation leaves a remainder
        }
        for (uint256 i; i < 40 && h.v().activeCount() > 1; ++i) {
            h.close(i);
        }
        assertEq(h.v().activeCount(), 1, "one position left");
        h.warp(30 days); // interest for the reserve (the pool is empty: all of it to the ledger)
        h.liquidate(2, 2, true); // the last position: path 2
        assertEq(h.ok("liqDeficit"), 1, "no-stakes deficit");
        _checkAll("after the deficit");
        DeficitLedger led = h.ledger();
        assertGt(led.deficit(), 0, "deficit recorded");
        assertGt(led.recoveredColl(), 0, "collateral recovered");
        assertGt(led.reserve(), 0, "reserve accrued");
        h.cover();
        assertEq(h.ok("coverBurned"), 1, "cover burned");
        _checkAll("after cover");
        h.triggerShutdown(0);
        h.settle(0);
        assertTrue(led.settled(), "ledger settled");
        assertEq(led.recoveredColl(), 0, "collateral to the shutdown module");
        _checkAll("after settlement");
    }

    function _checkAll(string memory when) internal view {
        (bool ok, string memory why) = h.checkI1Holders();
        assertTrue(ok, string.concat(when, ": ", why));
        (ok, why) = h.checkI1Sums();
        assertTrue(ok, string.concat(when, ": ", why));
        (ok, why) = h.checkPool();
        assertTrue(ok, string.concat(when, ": ", why));
        (ok, why) = h.checkI2();
        assertTrue(ok, string.concat(when, ": ", why));
        (ok, why) = h.checkLiquidations();
        assertTrue(ok, string.concat(when, ": ", why));
        (ok, why) = h.checkI8();
        assertTrue(ok, string.concat(when, ": ", why));
        (ok, why) = h.checkEventsAgree();
        assertTrue(ok, string.concat(when, ": ", why));
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
    }

    function _dumpList() internal {
        VaultManager v = h.v();
        emit log_named_uint("LColl", v.LColl());
        emit log_named_uint("LDebt", v.LDebt());
        emit log_named_uint("totalStakesSnapshot", v.totalStakesSnapshot());
        emit log_named_uint("totalCollateralSnapshot", v.totalCollateralSnapshot());
        uint256 a = h.sorted().getFirst();
        for (uint256 b = h.sorted().getNext(a); b != 0; (a, b) = (b, h.sorted().getNext(b))) {
            (uint256 cA, uint256 nA) = v.sortKey(a);
            (uint256 cB, uint256 nB) = v.sortKey(b);
            emit log_named_uint("pair: A id", a);
            emit log_named_uint("      B id", b);
            emit log_named_uint("      cA", cA);
            emit log_named_uint("      nA", nA);
            emit log_named_uint("      cB", cB);
            emit log_named_uint("      nB", nB);
            emit log_named_uint("      stake A", v.positions(a).stake);
            emit log_named_uint("      stake B", v.positions(b).stake);
            if (cA * nB < cB * nA) {
                uint256 deficit = cB * nA - cA * nB;
                emit log_named_uint("      INVERTED by (cB*nA - cA*nB)", deficit);
                emit log_named_uint("      needed k (approx deficit/(cA+nB))", deficit / (cA + nB) + 1);
            }
        }
    }

    /// @dev seed 1: redistributions into an almost empty list collapse the stakes (P17-1). The 10⁻⁹
    ///      slack ceiling first proposed for CHG-008 failed here; the derived bound must hold after
    ///      every step regardless.
    function test_regression_I13_derivedBound_stakeCollapse() public {
        h.close(1e21);
        _step("close");
        h.close(1.5e22);
        _step("close");
        h.close(5_734_782_701);
        _step("close");
        h.addCollateral(
            83_141,
            653,
            83_089_753_538_390_877_918_022_851_752_150_632_420_028_087_893_217_406_984_075_386_609_266_820_417_942
        );
        _step("addCollateral");
        h.redistribute(3600);
        _step("redistribute");
        h.redistribute(1.1e18);
        _step("redistribute");
        h.redistribute(73);
        _step("redistribute");
        h.redistribute(945);
        _step("redistribute");
        h.redistribute(type(uint256).max);
        _step("redistribute");
        h.open(
            type(uint256).max - 1,
            204_499_225_902_607_416_737_384_513_044_247_755_978_468_592_852_909_811_318_237_285_711_342_116_203,
            27
        );
        _step("open");
        h.redeemAcrossTail(
            156_813_708_276_399_009_889_891_378_702_901_072_290_335, 1_674_015_769_847_113_511_638_982, 30
        );
        _step("redeemAcrossTail");
        h.redistribute(3600);
        _step("redistribute");
        h.redistribute(9);
        _step("redistribute");
        h.redistribute(14_411);
        _step("redistribute");
        h.redistribute(81);
        _step("redistribute");
        _dumpMembers();
        (bool ok, string memory why) = h.checkI13();
        assertTrue(ok, why);
        assertGt(h.redistributions(), 0, "redistributions ran");
        assertGt(h.stepsNonExact(), 0, "tolerance regime reached");
        assertEq(h.unexpectedReverts(), 0, h.lastUnexpectedAction());
        // the collapse this sequence pins: the stake per unit of collateral fell below 10⁻¹²
        VaultManager v = h.v();
        assertLt(
            v.totalStakesSnapshot() * 1e12, v.totalCollateralSnapshot(), "P17-1: snapshot ratio collapsed"
        );
    }

    function _step(string memory what) internal {
        (bool ok, string memory why) = h.checkI13();
        if (!ok) {
            emit log_string(string.concat("I13 fails after ", what, ": ", why));
            _dumpMembers();
            fail();
        }
    }

    function _dumpMembers() internal {
        VaultManager v = h.v();
        emit log_named_uint("totalStakes", v.totalStakes());
        emit log_named_uint("totalStakesSnapshot", v.totalStakesSnapshot());
        emit log_named_uint("totalCollateralSnapshot", v.totalCollateralSnapshot());
        emit log_named_uint("LColl", v.LColl());
        emit log_named_uint("redistributions", h.redistributions());
        for (uint256 id = h.sorted().getFirst(); id != 0; id = h.sorted().getNext(id)) {
            (uint256 c, uint256 n) = v.sortKey(id);
            VaultManager.Position memory p = v.positions(id);
            emit log_named_uint("member", id);
            emit log_named_uint("  stake", p.stake);
            emit log_named_uint("  stored coll", p.coll);
            emit log_named_uint("  effective coll", c);
            emit log_named_uint("  effective norm", n);
            emit log_named_uint("  LColl - snap", v.LColl() - p.snapLColl);
        }
    }
}
