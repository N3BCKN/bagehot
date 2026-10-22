// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WadRayMath
/// @notice WAD (1e18) and RAY (1e27) fixed-point products, quotients and the power function
///         (docs/spec.md §2.1–§2.3). Bit-for-bit identical to `model/math.py`.
/// @dev Every function rounds in the direction its name says; callers pick the direction from
///      the spec's rounding table (§8). Overflow and zero divisors revert as in `Rounding`
///      (`Panic(0x11)` / `Panic(0x12)`, spec §2.2).
library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    function wmulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, WAD, Math.Rounding.Floor);
    }

    function wmulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, WAD, Math.Rounding.Ceil);
    }

    function wdivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, WAD, y, Math.Rounding.Floor);
    }

    function wdivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, WAD, y, Math.Rounding.Ceil);
    }

    function rmulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, RAY, Math.Rounding.Floor);
    }

    function rmulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, RAY, Math.Rounding.Ceil);
    }

    function rdivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, RAY, y, Math.Rounding.Floor);
    }

    function rdivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, RAY, y, Math.Rounding.Ceil);
    }

    /// @notice x^n in RAY, the spec's power function (§2.3).
    /// @dev rounding: Ceil on every product — the only direction the protocol uses (R4, R5, R19,
    ///      R23). See `rpow(x, n, rounding)` for the algorithm, the error bound and the domain.
    function rpow(uint256 x, uint256 n) internal pure returns (uint256) {
        return rpow(x, n, Math.Rounding.Ceil);
    }

    /// @notice x^n in RAY by square-and-multiply, least-significant bit first (spec §2.3).
    /// @dev The order of products is normative: implementations with another order (e.g.
    ///      MakerDAO's) differ in the low digits and fail `spec/vectors/math.json`. The final
    ///      squaring is skipped once no bits remain.
    ///
    ///      `rounding` applies to every product. The protocol only uses Ceil; Floor exists so tests
    ///      can bracket the exact value: rpow(x, n, Floor) <= x^n / RAY^(n-1) <= rpow(x, n, Ceil).
    ///      Both inequalities hold for all inputs, because every rounded product is monotone in its
    ///      arguments.
    ///
    ///      Error bound (P10, measured with spec/tools/rpow_error.py on 52,000 random inputs and
    ///      derived analytically): |rpow(x, n, r) - exact| <= n * max(1, exact / RAY) RAY units,
    ///      up to second-order terms of relative size n / RAY. The error grows with n, not with the
    ///      number of products, because an early rounding is doubled by every later squaring. For a
    ///      year of interest in one accrual (n ~ 3.2e7) that is a relative error below 4e-20.
    ///
    ///      Domain: reverts `Panic(0x11)` when any product exceeds 2^256 - 1, i.e. when the result
    ///      or the largest needed square x^(2^k), with 2^k the top bit of n, exceeds about 1.16e50
    ///      in real terms (2^256 / RAY). x <= RAY never overflows. For x = 2 * RAY the largest n is
    ///      166 (2^166 * RAY < 2^256 <= 2^167 * RAY).
    function rpow(uint256 x, uint256 n, Math.Rounding rounding) internal pure returns (uint256 z) {
        z = RAY;
        uint256 b = x;
        uint256 e = n;
        while (e > 0) {
            if (e & 1 == 1) {
                z = Math.mulDiv(z, b, RAY, rounding);
            }
            e >>= 1;
            if (e > 0) {
                b = Math.mulDiv(b, b, RAY, rounding);
            }
        }
    }
}
