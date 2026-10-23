// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice SortedPositions' external surface (spec §5.2).
interface ISortedPositions {
    function insert(uint256 id, uint256 upperHint, uint256 lowerHint) external;
    function remove(uint256 id) external;
    function reinsert(uint256 id, uint256 upperHint, uint256 lowerHint) external;
    function find(
        uint256 keyColl,
        uint256 keyNorm,
        uint256 id,
        uint256 excludeId,
        uint256 upperHint,
        uint256 lowerHint
    ) external view returns (bool found, uint256 prev, uint256 next);
    function contains(uint256 id) external view returns (bool);
    function getFirst() external view returns (uint256);
    function getLast() external view returns (uint256);
    function getNext(uint256 id) external view returns (uint256);
    function getPrev(uint256 id) external view returns (uint256);
    function getSize() external view returns (uint256);
}
