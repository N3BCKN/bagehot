// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Rounding} from "../../src/lib/Rounding.sol";
import {WadRayMath} from "../../src/lib/WadRayMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev External entry points to the internal math libraries, so tests can assert reverts.
contract MathHarness {
    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Rounding.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return Rounding.mulDivUp(x, y, d);
    }

    function divUp(uint256 x, uint256 y) external pure returns (uint256) {
        return Rounding.divUp(x, y);
    }

    function wmulDown(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.wmulDown(x, y);
    }

    function wmulUp(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.wmulUp(x, y);
    }

    function wdivDown(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.wdivDown(x, y);
    }

    function wdivUp(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.wdivUp(x, y);
    }

    function rmulDown(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.rmulDown(x, y);
    }

    function rmulUp(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.rmulUp(x, y);
    }

    function rdivDown(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.rdivDown(x, y);
    }

    function rdivUp(uint256 x, uint256 y) external pure returns (uint256) {
        return WadRayMath.rdivUp(x, y);
    }

    function rpowUp(uint256 x, uint256 n) external pure returns (uint256) {
        return WadRayMath.rpow(x, n);
    }

    function rpowDown(uint256 x, uint256 n) external pure returns (uint256) {
        return WadRayMath.rpow(x, n, Math.Rounding.Floor);
    }
}
