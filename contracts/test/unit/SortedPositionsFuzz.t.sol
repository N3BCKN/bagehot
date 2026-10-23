// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {MockVaultManagerKeys} from "../utils/MockVaultManagerKeys.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Random insert / remove / re-key-and-reinsert sequences against a sorted-array reference.
/// @dev The reference places a key by counting the members that precede it (spec §6.3.1) — no
///      walk, no hints — and the list must equal it after every operation. Hints are drawn from
///      exact neighbours, neighbours off by k, random members, garbage ids and 0. Keys come from a
///      small range so exact ties (decided by id) are frequent.
contract SortedPositionsFuzzTest is Test {
    SortedPositions internal list;
    MockVaultManagerKeys internal keys;
    uint256[] internal ref; // member ids, head first
    uint256 internal nextId = 1;
    uint256 internal rng;

    function _setUp(uint256 maxSteps, uint256 seed) internal {
        keys = new MockVaultManagerKeys();
        list = new SortedPositions(maxSteps);
        list.wire(address(keys));
        keys.setList(list);
        rng = seed;
        delete ref;
        nextId = 1;
    }

    function _rand(uint256 n) internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return rng % n;
    }

    function _precedes(uint256 a, uint256 b) internal view returns (bool) {
        (uint256 ca, uint256 na) = keys.sortKey(a);
        (uint256 cb, uint256 nb) = keys.sortKey(b);
        return ca * nb > cb * na || (ca * nb == cb * na && a < b);
    }

    /// @dev Reference position of `id` among the current members (excluding itself).
    function _refIndex(uint256 id) internal view returns (uint256 pos) {
        for (uint256 i; i < ref.length; ++i) {
            if (ref[i] != id && _precedes(ref[i], id)) ++pos;
        }
    }

    function _refInsert(uint256 id) internal {
        uint256 pos = _refIndex(id);
        ref.push(0);
        for (uint256 i = ref.length - 1; i > pos; --i) {
            ref[i] = ref[i - 1];
        }
        ref[pos] = id;
    }

    function _refRemove(uint256 id) internal {
        uint256 j;
        for (uint256 i; i < ref.length; ++i) {
            if (ref[i] != id) ref[j++] = ref[i];
        }
        ref.pop();
    }

    function _hint(uint256 pos) internal returns (uint256 up, uint256 lo) {
        uint256 mode = _rand(6);
        if (mode == 0) return (0, 0);
        if (mode == 1) return (pos == 0 ? 0 : ref[pos - 1], pos < ref.length ? ref[pos] : 0); // exact
        if (mode == 2 || mode == 3) {
            // off by k in either direction
            uint256 k = 1 + _rand(4);
            uint256 a = pos > k ? pos - k : 0;
            uint256 b = pos + k < ref.length ? pos + k : (ref.length == 0 ? 0 : ref.length - 1);
            return (ref.length == 0 ? 0 : ref[a], ref.length == 0 ? 0 : ref[b]);
        }
        if (mode == 4) {
            return
                (ref.length == 0 ? 0 : ref[_rand(ref.length)], ref.length == 0 ? 0 : ref[_rand(ref.length)]);
        }
        return (1000 + _rand(1000), _rand(2) == 0 ? 0 : 2000 + _rand(10)); // garbage
    }

    function _newKey(uint256 id) internal {
        keys.setKey(id, 1 + _rand(12), 1 + _rand(4)); // ratios repeat often: ties
    }

    function _assertMatches() internal view {
        assertEq(list.getSize(), ref.length, "size");
        uint256 cur = list.getFirst();
        uint256 prev;
        for (uint256 i; i < ref.length; ++i) {
            assertEq(cur, ref[i], "order");
            assertEq(list.getPrev(cur), prev, "prev link");
            assertTrue(list.contains(cur));
            prev = cur;
            cur = list.getNext(cur);
        }
        assertEq(cur, 0, "tail next");
        assertEq(list.getLast(), prev, "tail");
    }

    function _step() internal {
        uint256 op = ref.length == 0 ? 0 : _rand(3);
        if (op == 0) {
            uint256 id = nextId++;
            _newKey(id);
            (uint256 up, uint256 lo) = _hint(_refIndex(id));
            keys.insert(id, up, lo);
            _refInsert(id);
        } else if (op == 1) {
            uint256 id = ref[_rand(ref.length)];
            keys.remove(id);
            _refRemove(id);
        } else {
            uint256 id = ref[_rand(ref.length)];
            _newKey(id);
            _refRemove(id);
            (uint256 up, uint256 lo) = _hint(_refIndex(id));
            keys.reinsert(id, up, lo);
            _refInsert(id);
        }
        _assertMatches();
    }

    /// @dev MAX_HINT_STEPS high enough that no walk is stale: the list equals the reference.
    function testFuzz_randomSequences_matchTheSortedArray(uint256 seed) public {
        _setUp(1000, seed);
        for (uint256 i; i < 60; ++i) {
            _step();
        }
    }

    /// @dev With MAX_HINT_STEPS = 2: an insert either lands exactly where the reference says, or
    ///      reverts StaleHint and changes nothing; with exact neighbour hints it never reverts.
    function testFuzz_tightStepBound_exactOrStaleNeverMisplaced(uint256 seed) public {
        _setUp(2, seed);
        uint256 stale;
        for (uint256 i; i < 60; ++i) {
            uint256 id = nextId++;
            _newKey(id);
            uint256 pos = _refIndex(id);
            (uint256 up, uint256 lo) = _hint(pos);
            try keys.insert(id, up, lo) {
                _refInsert(id);
            } catch (bytes memory err) {
                assertEq(bytes4(err), SortedPositions.StaleHint.selector);
                ++stale;
                // the exact hint always works
                keys.insert(id, pos == 0 ? 0 : ref[pos - 1], pos < ref.length ? ref[pos] : 0);
                _refInsert(id);
            }
            _assertMatches();
        }
    }
}
