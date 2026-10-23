// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {ISortKeySource} from "../../src/interfaces/ISortKeySource.sol";

/// @notice Stands in for the VaultManager in SortedPositions tests: serves sort keys from a table
///         (spec/vectors README: "SortedPositions with a mock key source") and is the wired caller
///         of the list's mutators. `setKey` without a reinsert models a key that moved lazily
///         (redistribution drift, I13).
contract MockVaultManagerKeys is ISortKeySource {
    struct Key {
        uint256 coll;
        uint256 norm;
    }

    SortedPositions public list;
    mapping(uint256 => Key) public keys;
    uint256 public nextId = 1;

    function setList(SortedPositions list_) external {
        list = list_;
    }

    function setKey(uint256 id, uint256 coll, uint256 norm) external {
        keys[id] = Key(coll, norm);
        if (id >= nextId) nextId = id + 1;
    }

    function sortKey(uint256 id) external view returns (uint256, uint256) {
        Key memory k = keys[id];
        return (k.coll, k.norm);
    }

    function insert(uint256 id, uint256 upperHint, uint256 lowerHint) external {
        list.insert(id, upperHint, lowerHint);
    }

    function remove(uint256 id) external {
        list.remove(id);
    }

    function reinsert(uint256 id, uint256 upperHint, uint256 lowerHint) external {
        list.reinsert(id, upperHint, lowerHint);
    }
}
