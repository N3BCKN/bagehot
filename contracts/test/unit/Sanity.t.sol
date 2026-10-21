// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Placeholder test so that every toolchain recipe has something to compile and run at P00.
///         Replaced by real unit tests from P10 onwards.
contract SanityTest is Test {
    function test_sanity_arithmeticHolds() public pure {
        assertEq(uint256(1) + 1, 2);
    }
}
