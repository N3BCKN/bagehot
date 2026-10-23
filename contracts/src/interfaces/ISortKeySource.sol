// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What SortedPositions and HintHelpers read from the VaultManager (spec §4.2, §5.1.12).
interface ISortKeySource {
    /// @notice A position's sort key: effective collateral and effective normalised debt (§6.3.1).
    function sortKey(uint256 id) external view returns (uint256 effColl, uint256 effNorm);

    /// @notice The next position id to be assigned; ids run from 1 to nextId − 1 (§4.2).
    function nextId() external view returns (uint256);
}
