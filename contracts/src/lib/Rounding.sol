// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Rounding
/// @notice The only way the protocol divides amounts, prices, indices, shares or accumulators
///         (docs/spec.md §2.2). Every call site names its direction from the rounding table (§8).
/// @dev Wraps OpenZeppelin `Math.mulDiv` (512-bit intermediate) — ADR-0017. Errors follow spec
///      §2.2: a zero divisor reverts `Panic(0x12)`, a result that does not fit in 256 bits
///      (including the +1 of a ceil) reverts `Panic(0x11)`. The Python model (`model/protocol/math.py`)
///      raises `DivisionByZero` / `Overflow` for the same inputs.
library Rounding {
    /// @notice floor(x * y / d).
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Floor);
    }

    /// @notice ceil(x * y / d).
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }

    /// @notice ceil(x / y). Reverts `Panic(0x12)` when y == 0, also for x == 0.
    function divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.ceilDiv(x, y);
    }
}
