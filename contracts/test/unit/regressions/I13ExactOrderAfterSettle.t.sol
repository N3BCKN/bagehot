// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreHandler} from "../../invariant/handlers/CoreHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Regression (nightly campaign, 2026-10-26): I13 reported "exact order" after settlement. Cause:
///         the handler's `reclaimGasReserve` action forgot the position's I13 exactness as if it had left
///         the list, but §5.1.10 leaves the node in the (frozen) list — so once every non-exact member had
///         reclaimed, the handler wrongly took the list for exactly ordered and applied the exact rule to
///         two drifted near-ties. A harness bug present since P17; the pair satisfies CHG-009's bound.
contract I13ExactOrderAfterSettleTest is Test {
    CoreHandler internal h;

    function _check(string memory at) internal view {
        (bool ok, string memory why) = h.checkI13();
        assertTrue(ok, string.concat(at, ": ", why));
    }

    function test_regression_I13_reclaimKeepsListMembers() public {
        address[5] memory a =
            [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        h = new CoreHandler(false, true, a);
        h.close(14_665);
        h.close(21_979_553_151_239_153_028);
        h.close(496_594_352_990_056_166_254_180_290_147_895_985_071_502_376_882_243);
        h.redistribute(200_000);
        h.open(1901, 4145, 5_000_000_000_000_000_000_000);
        h.close(169_973_496_001);
        h.redistribute(
            145_871_456_528_644_020_949_010_199_077_095_880_307_434_130_261_927_316_314_852_668_241_616_257
        );
        h.redistribute(638_212_885);
        h.redistribute(148_101_062_245_844_138_749_113_262_304_708_944_246);
        h.movePrice(16_223);
        h.redistribute(40);
        h.redistribute(0);
        h.redistribute(30_000_000_000_000_000_000_000);
        h.redistribute(
            13_324_479_021_105_063_735_937_233_391_351_185_526_471_341_460_505_680_481_517_806_830_406_862_091_833
        );
        h.redistribute(828_417);
        h.open(1302, 34_999_999_999_999_995_837, 31_337);
        h.open(
            115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935,
            6160,
            1_805_951_431
        );
        h.open(
            39_242_272_039_108_867_875_346_062_562_497_781_931_283_800_541_561_421_888_344_010_388_860_231_811_874,
            603_748_643,
            50
        );
        h.redistribute(63);
        _check("redistribute 63");
        h.triggerShutdown(1_050_000_000_000_000_000);
        _check("triggerShutdown");
        h.close(2);
        _check("close 2");
        h.settle(100_000);
        _check("settle");
        h.reclaimGasReserve(23_543);
        _check("reclaim 1");
        h.reclaimGasReserve(13_654_639_141_076_844_800);
        _check("reclaim 2");
        assertEq(h.sorted().getSize(), 2, "settlement leaves the nodes in the list (5.1.10)");
        assertGt(h.nonExact(), 0, "both remaining members are still non-exact");
    }
}
