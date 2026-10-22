// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MathHarness} from "../utils/MathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, stdError} from "forge-std/Test.sol";

/// @notice Rounding: exactness and direction over the whole uint256 domain (spec §2.2).
/// @dev No vm.assume: every region of the input space asserts its own outcome — exact result,
///      Panic(0x11) when the result does not fit, Panic(0x12) for a zero divisor.
contract RoundingTest is Test {
    MathHarness internal h;

    // floor(X * 6 / 5) == type(uint256).max with remainder 3: floor fits, ceil does not.
    uint256 internal constant CEIL_EDGE_X =
        96_493_407_697_763_496_186_309_154_173_906_589_877_724_987_221_367_136_699_547_986_673_260_941_366_613;

    function setUp() public {
        h = new MathHarness();
    }

    /// @dev (hi, lo) of a + b for a 512-bit a and a 256-bit b.
    function _add(uint256 hi, uint256 lo, uint256 b) internal pure returns (uint256, uint256) {
        unchecked {
            uint256 sum = lo + b; // wraps; the carry is detected below
            return (hi + (sum < lo ? 1 : 0), sum);
        }
    }

    function testFuzz_mulDiv_exactOrReverts(uint256 x, uint256 y, uint256 d) public {
        if (d == 0) {
            vm.expectRevert(stdError.divisionError);
            h.mulDivDown(x, y, d);
            vm.expectRevert(stdError.divisionError);
            h.mulDivUp(x, y, d);
            return;
        }
        (uint256 hi, uint256 lo) = Math.mul512(x, y);
        if (hi >= d) {
            // x * y / d >= 2^256: neither direction fits
            vm.expectRevert(stdError.arithmeticError);
            h.mulDivDown(x, y, d);
            vm.expectRevert(stdError.arithmeticError);
            h.mulDivUp(x, y, d);
            return;
        }
        uint256 down = h.mulDivDown(x, y, d);
        uint256 r = mulmod(x, y, d);
        // down * d + r == x * y exactly, with r < d: down is the floor
        (uint256 h1, uint256 l1) = Math.mul512(down, d);
        (h1, l1) = _add(h1, l1, r);
        assertEq(h1, hi, "floor: high word");
        assertEq(l1, lo, "floor: low word");
        assertLt(r, d);
        if (r != 0 && down == type(uint256).max) {
            vm.expectRevert(stdError.arithmeticError); // the ceil's +1 does not fit
            h.mulDivUp(x, y, d);
            return;
        }
        uint256 up = h.mulDivUp(x, y, d);
        assertEq(up - down, r == 0 ? 0 : 1, "up - down in {0, 1}, 1 iff inexact");
    }

    function test_mulDivUp_ceilOverflowAtTheTopReverts() public {
        assertEq(h.mulDivDown(CEIL_EDGE_X, 6, 5), type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        h.mulDivUp(CEIL_EDGE_X, 6, 5);
    }

    function test_mulDiv_boundaries() public view {
        uint256 max = type(uint256).max;
        assertEq(h.mulDivDown(max, max, max), max);
        assertEq(h.mulDivUp(max, max, max), max);
        assertEq(h.mulDivUp(max, 1, 1), max);
        assertEq(h.mulDivDown(0, max, 1), 0);
        assertEq(h.mulDivUp(1, 1, max), 1);
        assertEq(h.mulDivDown(1, 1, max), 0);
    }

    function test_mulDiv_resultTooLargeReverts() public {
        vm.expectRevert(stdError.arithmeticError);
        h.mulDivDown(type(uint256).max, 2, 1);
    }

    function testFuzz_divUp(uint256 x, uint256 y) public {
        if (y == 0) {
            vm.expectRevert(stdError.divisionError);
            h.divUp(x, y);
            return;
        }
        assertEq(h.divUp(x, y), x / y + (x % y == 0 ? 0 : 1));
    }

    function test_divUp_zeroNumeratorWithZeroDivisorStillReverts() public {
        vm.expectRevert(stdError.divisionError);
        h.divUp(0, 0);
    }
}
