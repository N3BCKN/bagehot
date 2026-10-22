// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MathHarness} from "../utils/MathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, stdError} from "forge-std/Test.sol";

/// @notice WAD/RAY products and rpow (spec §2.3): order, direction, monotonicity, bounds, domain.
contract WadRayMathTest is Test {
    MathHarness internal h;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_RATE = 21_979_553_151_239_153_028; // spec §3.1, ANNUAL_RATE = 1

    function setUp() public {
        h = new MathHarness();
    }

    function testFuzz_wadRay_areMulDivWithTheirUnit(uint128 x, uint128 y) public view {
        uint256 d = uint256(y) + 1;
        assertEq(h.wmulDown(x, y), Math.mulDiv(x, y, WAD, Math.Rounding.Floor));
        assertEq(h.wmulUp(x, y), Math.mulDiv(x, y, WAD, Math.Rounding.Ceil));
        assertEq(h.wdivDown(x, d), Math.mulDiv(x, WAD, d, Math.Rounding.Floor));
        assertEq(h.wdivUp(x, d), Math.mulDiv(x, WAD, d, Math.Rounding.Ceil));
        assertEq(h.rmulDown(x, y), Math.mulDiv(x, y, RAY, Math.Rounding.Floor));
        assertEq(h.rmulUp(x, y), Math.mulDiv(x, y, RAY, Math.Rounding.Ceil));
        assertEq(h.rdivDown(x, d), Math.mulDiv(x, RAY, d, Math.Rounding.Floor));
        assertEq(h.rdivUp(x, d), Math.mulDiv(x, RAY, d, Math.Rounding.Ceil));
        assertLe(h.wmulUp(x, y) - h.wmulDown(x, y), 1);
        assertLe(h.rdivUp(x, d) - h.rdivDown(x, d), 1);
    }

    function test_wdiv_byZeroReverts() public {
        vm.expectRevert(stdError.divisionError);
        h.wdivDown(1, 0);
        vm.expectRevert(stdError.divisionError);
        h.rdivUp(1, 0);
    }

    // ------------------------------------------------------------------ rpow: fixed points
    function testFuzz_rpow_fixedPoints(uint256 x, uint256 n) public view {
        x = bound(x, 0, 4 * RAY);
        n = bound(n, 1, 2 ** 64);
        assertEq(h.rpowUp(x, 0), RAY, "x^0 = 1");
        assertEq(h.rpowUp(RAY, n), RAY, "1^n = 1");
        assertEq(h.rpowUp(0, n), 0, "0^n = 0");
        assertEq(h.rpowDown(RAY, n), RAY);
    }

    // ------------------------------------------------------------------ rpow: order of products
    function _repeated(uint256 x, uint256 n, bool up) internal view returns (uint256 z) {
        z = RAY;
        for (uint256 i; i < n; ++i) {
            z = up ? h.rmulUp(z, x) : h.rmulDown(z, x);
        }
    }

    function testFuzz_rpow_equalsRepeatedProductForNUpToThree(uint256 x, uint256 n) public view {
        x = bound(x, 0, 2 * RAY);
        n = bound(n, 0, 3);
        // Up to n = 3 both orders round the same products: rpow is repeated rmul.
        assertEq(h.rpowUp(x, n), _repeated(x, n, true));
        assertEq(h.rpowDown(x, n), _repeated(x, n, false));
    }

    function testFuzz_rpow_andRepeatedProductBracketTheSameValue(uint256 x, uint256 n) public view {
        x = bound(x, RAY / 2, 2 * RAY);
        n = bound(n, 4, 64);
        // From n = 4 the orders differ in the low digits, but each Floor/Ceil pair brackets the
        // exact x^n, so every lower result is <= every upper result.
        uint256 lo = Math.max(h.rpowDown(x, n), _repeated(x, n, false));
        uint256 hi = Math.min(h.rpowUp(x, n), _repeated(x, n, true));
        assertLe(lo, hi);
    }

    // ------------------------------------------------------------------ rpow: monotonicity
    function testFuzz_rpow_growthIsNondecreasingInN(uint256 x, uint256 n) public view {
        x = bound(x, RAY, RAY + MAX_RATE);
        n = bound(n, 0, 2 ** 26);
        assertGe(h.rpowUp(x, n + 1), h.rpowUp(x, n));
        assertGe(h.rpowDown(x, n + 1), h.rpowDown(x, n));
    }

    function testFuzz_rpow_decayIsNonincreasingInN(uint256 x, uint256 n) public view {
        x = bound(x, RAY / 2, RAY);
        n = bound(n, 0, 2 ** 20);
        assertLe(h.rpowUp(x, n + 1), h.rpowUp(x, n));
        assertLe(h.rpowDown(x, n + 1), h.rpowDown(x, n));
    }

    function testFuzz_rpow_isNondecreasingInX(uint256 a, uint256 b, uint256 n) public view {
        a = bound(a, 0, 2 * RAY);
        b = bound(b, a, 2 * RAY);
        n = bound(n, 0, 160); // 2 * RAY never overflows below n = 167
        assertLe(h.rpowUp(a, n), h.rpowUp(b, n));
        assertLe(h.rpowDown(a, n), h.rpowDown(b, n));
    }

    // ------------------------------------------------------------------ rpow: error bound
    function testFuzz_rpow_upMinusDownWithinTwiceTheBound(uint256 x, uint256 n) public view {
        x = bound(x, RAY, RAY + MAX_RATE);
        n = bound(n, 0, 2 ** 26);
        uint256 up = h.rpowUp(x, n);
        uint256 down = h.rpowDown(x, n);
        // Each side is within n * max(1, value/RAY) of the exact value (P10 bound), so the
        // bracket is at most twice that; +1 absorbs the integer part of value/RAY.
        uint256 factor = Math.max(1, up / RAY + 1);
        assertLe(down, up);
        assertLe(up - down, 2 * n * factor);
    }

    // ------------------------------------------------------------------ rpow: domain
    function test_rpow_overflowBoundaryForTwoRay() public {
        assertEq(h.rpowUp(2 * RAY, 166), (uint256(1) << 166) * RAY, "2^166 fits, exactly");
        vm.expectRevert(stdError.arithmeticError);
        h.rpowUp(2 * RAY, 167);
        vm.expectRevert(stdError.arithmeticError);
        h.rpowDown(2 * RAY, 167);
    }

    function testFuzz_rpow_neverOverflowsAtOrBelowRay(uint256 x, uint256 n) public view {
        x = bound(x, 0, RAY);
        assertLe(h.rpowUp(x, n), RAY);
        assertLe(h.rpowDown(x, n), RAY);
    }
}
