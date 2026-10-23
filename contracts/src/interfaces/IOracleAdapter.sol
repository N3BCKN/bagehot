// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What core contracts call on the OracleAdapter (spec §5.7).
interface IOracleAdapter {
    function fetchPrice() external returns (uint256 price, bool usable);
}
