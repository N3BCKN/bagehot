// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {MockVaultManagerKeys} from "../utils/MockVaultManagerKeys.sol";
import {Test, console} from "forge-std/Test.sol";

/// @notice Insert gas (P13 acceptance: O(1) with good hints). Storage of the list and of the key
///         source is marked cold before each measurement (`vm.cool`), as in a fresh transaction.
///         Numbers include the mock VaultManager's call into the list, a constant.
contract SortedPositionsGasTest is Test {
    SortedPositions internal list;
    MockVaultManagerKeys internal keys;

    function _build(uint256 maxSteps, uint256 n) internal {
        keys = new MockVaultManagerKeys();
        list = new SortedPositions(maxSteps);
        list.wire(address(keys));
        keys.setList(list);
        // ids 1..n, NICR strictly decreasing with the id; each inserted after its predecessor
        for (uint256 id = 1; id <= n; ++id) {
            keys.setKey(id, 1e30 - id * 1e18, 1e18);
            keys.insert(id, id - 1, 0);
        }
    }

    /// @dev Gas of inserting a new node that belongs right after `after_`, with the given hints.
    function _measure(uint256 after_, uint256 up, uint256 lo) internal returns (uint256 used) {
        uint256 id = 1_000_000 + after_;
        keys.setKey(id, 1e30 - after_ * 1e18 - 5e17, 1e18); // between after_ and after_ + 1
        vm.cool(address(list));
        vm.cool(address(keys));
        uint256 g = gasleft();
        keys.insert(id, up, lo);
        used = g - gasleft();
        assertEq(list.getPrev(id), after_, "placed exactly");
    }

    /// @dev Exact neighbour hints at list sizes 10, 100 and 1,000: the cost does not grow with size.
    function test_gas_goodHintIsConstantInListSize() public {
        uint256[3] memory sizes = [uint256(10), 100, 1000];
        uint256[3] memory used;
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            _build(1000, sizes[i]);
            // the same spot (after id 5) at every size, so the calldata — hint ids — is identical
            used[i] = _measure(5, 5, 6);
            console.log("size", sizes[i], "insert gas, exact hints:", used[i]);
            vm.revertToState(snap);
        }
        assertEq(used[1], used[0], "size 100 = size 10");
        assertEq(used[2], used[0], "size 1,000 = size 10");
    }

    /// @dev An upper hint k positions too high walks k steps; the cost is linear in k.
    function test_gas_offByKHintIsLinearInK() public {
        _build(1000, 200);
        uint256 exact = _measure(100, 100, 101);
        uint256[3] memory ks = [uint256(1), 5, 25];
        uint256[3] memory used;
        for (uint256 i; i < 3; ++i) {
            uint256 spot = 120 + 20 * i; // a fresh spot per case; ids 120..160 all have 2-byte calldata
            used[i] = _measure(spot, spot - ks[i], 0); // upper hint k nodes above the spot
            console.log("off by", ks[i], "insert gas:", used[i]);
        }
        console.log("exact hints:", exact);
        uint256 perStep = (used[2] - used[1]) / 20;
        console.log("marginal gas per extra walk step:", perStep);
        // linear: the 1 -> 5 increment matches 4 steps at the 5 -> 25 rate within 2 %
        uint256 predicted = used[0] + 4 * perStep;
        assertApproxEqRel(used[1], predicted, 0.02e18, "linear in k");
    }

    /// @dev A hint beyond MAX_HINT_STEPS reverts StaleHint after exactly MAX_HINT_STEPS reads.
    function test_gas_staleHintIsBoundedByMaxHintSteps() public {
        _build(30, 120);
        keys.setKey(999, 1e30 - 100 * 1e18 - 5e17, 1e18); // belongs after 100
        vm.cool(address(list));
        vm.cool(address(keys));
        uint256 g = gasleft();
        vm.expectRevert(SortedPositions.StaleHint.selector);
        keys.insert(999, 50, 0); // 50 nodes above: more than 30 steps
        uint256 used = g - gasleft();
        console.log("stale hint (MAX_HINT_STEPS = 30), gas to revert:", used);
        keys.setKey(998, 1e30 - 100 * 1e18 - 5e17, 1e18);
        vm.cool(address(list));
        vm.cool(address(keys));
        g = gasleft();
        vm.expectRevert(SortedPositions.StaleHint.selector);
        keys.insert(998, 1, 0); // 99 nodes above: still capped at 30 steps
        uint256 used2 = g - gasleft();
        assertApproxEqRel(used2, used, 0.02e18, "the revert costs the same however stale the hint");
    }
}
