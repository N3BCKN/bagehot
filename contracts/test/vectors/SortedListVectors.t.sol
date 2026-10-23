// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {MockVaultManagerKeys} from "../utils/MockVaultManagerKeys.sol";
import {Test} from "forge-std/Test.sol";

/// @notice SortedPositions against spec/vectors/sorted_list.json (protected, normative): the order
///         with ties, and every hint-validation, walk, StaleHint and excludeId case of §6.3.2.
contract SortedListVectorsTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("../spec/vectors/sorted_list.json");
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _s(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _step(uint256 v, uint256 i) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(v), "].steps[", vm.toString(i), "]");
    }

    function _deploy(uint256 maxSteps) internal returns (SortedPositions list, MockVaultManagerKeys vm_) {
        vm_ = new MockVaultManagerKeys();
        list = new SortedPositions(maxSteps);
        list.wire(address(vm_));
        vm_.setList(list);
        for (uint256 id = 1; id <= 6; ++id) {
            string memory k = string.concat(".vectors[0].inputs.keys.", vm.toString(id));
            vm_.setKey(id, _u(string.concat(k, ".coll")), _u(string.concat(k, ".norm")));
        }
    }

    /// @dev Replays the six inserts of order_with_ties, checking each (prev, next). With `exactHints`
    ///      each insert gets its expected neighbours as hints (no walk), so a find case with a tiny
    ///      MAX_HINT_STEPS can still start from the full list.
    function _buildDefault(SortedPositions list, MockVaultManagerKeys keys, bool exactHints) internal {
        for (uint256 i; i < 6; ++i) {
            string memory p = _step(0, i);
            uint256 id = _u(string.concat(p, ".id"));
            uint256 up = _u(string.concat(p, exactHints ? ".result.prev" : ".upperHint"));
            uint256 lo = _u(string.concat(p, exactHints ? ".result.next" : ".lowerHint"));
            keys.insert(id, up, lo);
            assertEq(list.getPrev(id), _u(string.concat(p, ".result.prev")), "prev");
            assertEq(list.getNext(id), _u(string.concat(p, ".result.next")), "next");
        }
    }

    function test_vectors_orderWithTies() public {
        (SortedPositions list, MockVaultManagerKeys keys) = _deploy(_u(".vectors[0].inputs.MAX_HINT_STEPS"));
        _buildDefault(list, keys, false);
        uint256 cur = list.getFirst();
        for (uint256 i; i < 6; ++i) {
            assertEq(cur, _u(string.concat(".vectors[0].expected.order[", vm.toString(i), "]")), "order");
            cur = list.getNext(cur);
        }
        assertEq(cur, 0);
        assertEq(list.getFirst(), _u(".vectors[0].expected.head"));
        assertEq(list.getLast(), _u(".vectors[0].expected.tail"));
        assertEq(list.getSize(), 6);
    }

    function test_vectors_findInsertPosition() public {
        uint256 n;
        for (; vm.keyExistsJson(json, _step(1, n)); ++n) {
            _checkFind(_step(1, n));
        }
        assertEq(n, 10, "all find cases read");
    }

    struct FindCase {
        string name;
        uint256 c;
        uint256 n;
        uint256 id;
        uint256 ex;
        uint256 up;
        uint256 lo;
    }

    function _case(string memory p) internal view returns (FindCase memory f) {
        f.name = _s(string.concat(p, ".case"));
        f.c = _u(string.concat(p, ".keyColl"));
        f.n = _u(string.concat(p, ".keyNorm"));
        f.id = _u(string.concat(p, ".id"));
        f.ex = _u(string.concat(p, ".excludeId"));
        f.up = _u(string.concat(p, ".upperHint"));
        f.lo = _u(string.concat(p, ".lowerHint"));
    }

    function _checkFind(string memory p) internal {
        uint256 snap = vm.snapshotState();
        (SortedPositions list, MockVaultManagerKeys keys) = _deploy(_u(string.concat(p, ".MAX_HINT_STEPS")));
        if (vm.keyExistsJson(json, string.concat(p, ".list"))) {
            // a case on its own list: insert exactly the ids it names, in order, without hints
            string[] memory ids = vm.parseJsonStringArray(json, string.concat(p, ".list"));
            for (uint256 i; i < ids.length; ++i) {
                keys.insert(vm.parseUint(ids[i]), 0, 0);
            }
        } else {
            _buildDefault(list, keys, true);
        }
        FindCase memory f = _case(p);
        (bool found, uint256 prev, uint256 next) = list.find(f.c, f.n, f.id, f.ex, f.up, f.lo);
        bool expFound = vm.parseJsonBool(json, string.concat(p, ".result.found"));
        assertEq(found, expFound, f.name);
        if (expFound) {
            assertEq(prev, _u(string.concat(p, ".result.prev")), f.name);
            assertEq(next, _u(string.concat(p, ".result.next")), f.name);
        } else {
            // insert reverts where find returns found = false (§5.2)
            assertEq(_s(string.concat(p, ".result.revert")), "StaleHint", f.name);
            keys.setKey(f.id, f.c, f.n);
            vm.expectRevert(SortedPositions.StaleHint.selector);
            keys.insert(f.id, f.up, f.lo);
        }
        vm.revertToState(snap);
    }
}
