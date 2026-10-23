// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../../src/core/HintHelpers.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {ISortKeySource} from "../../src/interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../../src/interfaces/ISortedPositions.sol";
import {InvalidParameter, Unauthorized} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {MockVaultManagerKeys} from "../utils/MockVaultManagerKeys.sol";
import {Test} from "forge-std/Test.sol";

/// @notice SortedPositions: construction and wiring, every error, linking at head / middle / tail,
///         and each branch of the §6.3.2 hint validation, walks and exclusion. Keys are NICR × 100
///         over a debt of 100 unless stated, so `key(nicr)` = (nicr, 100).
contract SortedPositionsTest is Test {
    SortedPositions internal list;
    MockVaultManagerKeys internal keys;

    function setUp() public {
        keys = new MockVaultManagerKeys();
        list = new SortedPositions(30);
        list.wire(address(keys));
        keys.setList(list);
    }

    function _put(uint256 id, uint256 coll) internal {
        keys.setKey(id, coll, 100);
        keys.insert(id, 0, 0);
    }

    /// @dev Ids 1..5 with NICR 5,4,3,2,1 (head 1, tail 5).
    function _five() internal {
        for (uint256 id = 1; id <= 5; ++id) {
            _put(id, 600 - 100 * id);
        }
    }

    function _order() internal view returns (uint256[] memory out) {
        out = new uint256[](list.getSize());
        uint256 cur = list.getFirst();
        for (uint256 i; i < out.length; ++i) {
            out[i] = cur;
            cur = list.getNext(cur);
        }
        assertEq(cur, 0, "tail's next is 0");
    }

    function _assertOrder(uint256[5] memory expected) internal view {
        uint256[] memory got = _order();
        assertEq(got.length, 5);
        for (uint256 i; i < 5; ++i) {
            assertEq(got[i], expected[i]);
        }
    }

    // ------------------------------------------------------------------ construction and wiring

    function deployList(uint256 m) external returns (SortedPositions) {
        return new SortedPositions(m);
    }

    function test_constructor_maxHintStepsRange() public {
        uint256[2] memory bad = [uint256(0), 1001];
        for (uint256 i; i < 2; ++i) {
            try this.deployList(bad[i]) returns (SortedPositions) {
                fail("constructor did not revert");
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(InvalidParameter.selector, uint8(0)));
            }
        }
        assertEq(this.deployList(1).MAX_HINT_STEPS(), 1);
        assertEq(this.deployList(1000).MAX_HINT_STEPS(), 1000);
    }

    function test_wire_rules() public {
        SortedPositions l = new SortedPositions(5);
        vm.prank(address(0xBAD));
        vm.expectRevert(WiredBase.NotDeployer.selector);
        l.wire(address(keys));
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(0)));
        l.wire(address(0));
        address[] memory expected = new address[](1);
        expected[0] = address(keys);
        vm.expectEmit(address(l));
        emit WiredBase.Wired(expected);
        l.wire(address(keys));
        assertEq(address(l.vaultManager()), address(keys));
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        l.wire(address(keys));
    }

    function test_mutators_revertNotWiredBeforeUnauthorized() public {
        SortedPositions l = new SortedPositions(5);
        vm.startPrank(address(keys)); // even the future VaultManager
        vm.expectRevert(WiredBase.NotWired.selector);
        l.insert(1, 0, 0);
        vm.expectRevert(WiredBase.NotWired.selector);
        l.remove(1);
        vm.expectRevert(WiredBase.NotWired.selector);
        l.reinsert(1, 0, 0);
        vm.stopPrank();
        (bool found, uint256 p, uint256 n) = l.find(1, 1, 1, 0, 0, 0); // a view: no wiring needed
        assertTrue(found);
        assertEq(p + n, 0);
    }

    function testFuzz_mutators_onlyTheVaultManager(address caller) public {
        keys.setKey(1, 100, 100);
        if (caller == address(keys)) {
            keys.insert(1, 0, 0); // the VaultManager may
            assertTrue(list.contains(1));
            return;
        }
        vm.startPrank(caller);
        vm.expectRevert(Unauthorized.selector);
        list.insert(1, 0, 0);
        vm.expectRevert(Unauthorized.selector);
        list.remove(1);
        vm.expectRevert(Unauthorized.selector);
        list.reinsert(1, 0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ insert / remove / reinsert

    function test_insert_firstNodeAndEvents() public {
        keys.setKey(7, 300, 100);
        vm.expectEmit(address(list));
        emit SortedPositions.NodeInserted(7, 0, 0);
        keys.insert(7, 0, 0);
        assertTrue(list.contains(7));
        assertEq(list.getFirst(), 7);
        assertEq(list.getLast(), 7);
        assertEq(list.getSize(), 1);
        assertEq(list.getPrev(7), 0);
        assertEq(list.getNext(7), 0);
    }

    function test_insert_atHeadMiddleAndTail() public {
        _five();
        _put(6, 600); // new head: NICR 6
        _put(7, 50); // new tail: NICR 0.5
        _put(8, 250); // between 3 (NICR 3) and 4 (NICR 2)
        uint256[] memory o = _order();
        uint256[8] memory exp = [uint256(6), 1, 2, 3, 8, 4, 5, 7];
        for (uint256 i; i < 8; ++i) {
            assertEq(o[i], exp[i]);
        }
        assertEq(list.getFirst(), 6);
        assertEq(list.getLast(), 7);
        assertEq(list.getPrev(8), 3);
        assertEq(list.getNext(8), 4);
    }

    function test_insert_tieGoesAfterLowerIds() public {
        _five();
        _put(9, 300); // ties id 3 (NICR 3): after it
        assertEq(list.getPrev(9), 3);
        _put(10, 300);
        assertEq(list.getPrev(10), 9);
    }

    function test_insert_nodeExistsAndIdZero() public {
        _put(1, 100);
        vm.expectRevert(SortedPositions.NodeExists.selector);
        keys.insert(1, 0, 0);
        vm.expectRevert(SortedPositions.NodeExists.selector); // 0 is the null link, never a node
        keys.insert(0, 0, 0);
    }

    function test_insert_staleHintRevertsAndLeavesTheListUntouched() public {
        SortedPositions l = new SortedPositions(2);
        MockVaultManagerKeys k = new MockVaultManagerKeys();
        l.wire(address(k));
        k.setList(l);
        for (uint256 id = 1; id <= 5; ++id) {
            k.setKey(id, 600 - 100 * id, 100);
            k.insert(id, id == 1 ? 0 : id - 1, 0); // exact upper hint: zero steps
        }
        k.setKey(6, 50, 100); // belongs after 5: 4 steps from the head
        vm.expectRevert(SortedPositions.StaleHint.selector);
        k.insert(6, 0, 0);
        k.setKey(7, 550, 100); // belongs before 1: 4 steps up from the lower hint 5
        vm.expectRevert(SortedPositions.StaleHint.selector);
        k.insert(7, 0, 5);
        assertEq(l.getSize(), 5);
        assertFalse(l.contains(6));
        k.insert(6, 5, 0); // with a good hint it goes in
        assertEq(l.getLast(), 6);
    }

    function test_remove_headMiddleTailOnlyAndEvents() public {
        _five();
        vm.expectEmit(address(list));
        emit SortedPositions.NodeRemoved(3);
        keys.remove(3); // middle
        assertEq(list.getNext(2), 4);
        assertEq(list.getPrev(4), 2);
        keys.remove(1); // head
        assertEq(list.getFirst(), 2);
        assertEq(list.getPrev(2), 0);
        keys.remove(5); // tail
        assertEq(list.getLast(), 4);
        assertEq(list.getNext(4), 0);
        keys.remove(2);
        keys.remove(4); // only node
        assertEq(list.getSize(), 0);
        assertEq(list.getFirst(), 0);
        assertEq(list.getLast(), 0);
        assertFalse(list.contains(4));
        assertEq(list.getNext(4), 0); // a removed node's links are cleared
    }

    function test_remove_and_reinsert_nodeNotFound() public {
        vm.expectRevert(SortedPositions.NodeNotFound.selector);
        keys.remove(1);
        vm.expectRevert(SortedPositions.NodeNotFound.selector);
        keys.reinsert(1, 0, 0);
    }

    function test_reinsert_movesWithTheFreshKeyAndEmitsBothEvents() public {
        _five();
        keys.setKey(2, 50, 100); // id 2 drops to the bottom
        vm.expectEmit(address(list));
        emit SortedPositions.NodeRemoved(2);
        vm.expectEmit(address(list));
        emit SortedPositions.NodeInserted(2, 5, 0);
        keys.reinsert(2, 0, 0);
        _assertOrder([uint256(1), 3, 4, 5, 2]);
        assertEq(list.getSize(), 5);
    }

    // ------------------------------------------------------------------ find: hint branches

    function test_find_adjacentValidHints() public {
        _five();
        (bool f, uint256 p, uint256 n) = list.find(250, 100, 9, 0, 3, 4);
        assertTrue(f);
        assertEq(p, 3);
        assertEq(n, 4);
    }

    function test_find_validButNotAdjacentHintsWalkDownFromUpper() public {
        _five();
        (bool f, uint256 p, uint256 n) = list.find(150, 100, 9, 0, 1, 5); // between 4 and 5
        assertTrue(f);
        assertEq(p, 4);
        assertEq(n, 5);
    }

    function test_find_garbageAndWrongSideHintsAreDiscarded() public {
        _five();
        // 42 is not in the list; 5 is below the new key (bad upper); 1 is above it (bad lower)
        (bool f, uint256 p, uint256 n) = list.find(250, 100, 9, 0, 42, 42);
        assertTrue(f && p == 3 && n == 4);
        (f, p, n) = list.find(250, 100, 9, 0, 5, 1);
        assertTrue(f && p == 3 && n == 4);
    }

    function test_find_lowerHintWalksUp() public {
        _five();
        (bool f, uint256 p, uint256 n) = list.find(450, 100, 9, 0, 0, 5); // between 1 and 2
        assertTrue(f);
        assertEq(p, 1);
        assertEq(n, 2);
        (f, p, n) = list.find(900, 100, 9, 0, 0, 5); // new head, walking up to the top
        assertTrue(f);
        assertEq(p, 0);
        assertEq(n, 1);
    }

    function test_find_newHeadWithoutHints() public {
        _five();
        (bool f, uint256 p, uint256 n) = list.find(900, 100, 9, 0, 0, 0);
        assertTrue(f && p == 0 && n == 1);
    }

    function test_find_staleWalksReturnNotFound() public {
        SortedPositions l = new SortedPositions(1);
        MockVaultManagerKeys k = new MockVaultManagerKeys();
        l.wire(address(k));
        k.setList(l);
        for (uint256 id = 1; id <= 3; ++id) {
            k.setKey(id, 400 - 100 * id, 100);
            k.insert(id, id == 1 ? 0 : id - 1, 0);
        }
        (bool f,,) = l.find(50, 100, 9, 0, 0, 0); // walkDown from the head: 3 steps > 1
        assertFalse(f);
        (f,,) = l.find(900, 100, 9, 0, 0, 3); // walkUp from the tail: 3 steps > 1
        assertFalse(f);
    }

    // ------------------------------------------------------------------ find: exclusion (§6.3.2)

    function test_find_excludedHeadIsSkipped() public {
        _five();
        // reinsert of 1 with a key below everything: the walk starts at 2, ends after 5
        (bool f, uint256 p, uint256 n) = list.find(50, 100, 1, 1, 0, 0);
        assertTrue(f && p == 5 && n == 0);
        // and with a key above everything else, 1 would be the new head before 2
        (f, p, n) = list.find(900, 100, 1, 1, 0, 0);
        assertTrue(f && p == 0 && n == 2);
    }

    function test_find_excludedMiddleIsSkippedBothWays() public {
        _five();
        // exclude 3; key between 2 and 4 → (2, 4), from above and from below
        (bool f, uint256 p, uint256 n) = list.find(310, 100, 3, 3, 1, 0);
        assertTrue(f && p == 2 && n == 4);
        (f, p, n) = list.find(310, 100, 3, 3, 0, 5);
        assertTrue(f && p == 2 && n == 4);
        (f, p, n) = list.find(310, 100, 3, 3, 2, 4); // adjacent once 3 is gone
        assertTrue(f && p == 2 && n == 4);
    }

    function test_find_excludedHintIsDiscarded() public {
        _five();
        (bool f, uint256 p, uint256 n) = list.find(50, 100, 5, 5, 5, 5);
        assertTrue(f && p == 4 && n == 0);
    }

    function test_find_excludedOnlyNodeLeavesAnEmptyList() public {
        _put(1, 100);
        (bool f, uint256 p, uint256 n) = list.find(500, 100, 1, 1, 0, 0);
        assertTrue(f && p == 0 && n == 0);
    }

    function test_find_excludingANonMemberChangesNothing() public {
        _five();
        (bool f, uint256 p, uint256 n) = list.find(250, 100, 9, 42, 0, 0);
        assertTrue(f && p == 3 && n == 4);
    }

    // ------------------------------------------------------------------ CHG-005 regression

    /// @dev Permanent regression for CHG-005 (I13's tie clause). §6.3.2 permits this, and I13 must
    ///      not claim otherwise: B (12) inserted; D inserted 3 wei above B, then its key lowered by
    ///      4 wei (within I13's k) without a reinsert; A (19), with B's exact key, walks from the
    ///      head, stops before D and is linked ahead of it; D removed. A now sits directly ahead of
    ///      B with equal keys, neither changed since insertion, and no current member has drifted —
    ///      yet A is not *exact* (it was inserted while D was drifted), which is why I13's exact
    ///      regime requires every member to be exact, not merely undrifted.
    function test_CHG005_tieReversedThroughADriftedNeighbourThatHasSinceLeft() public {
        uint256 K = 2e18;
        keys.setKey(12, K, 1e18);
        keys.insert(12, 0, 0); // B
        keys.setKey(5, K + 3, 1e18);
        keys.insert(5, 0, 0); // D, just above B
        keys.setKey(5, K + 3 - 4, 1e18); // D drifts to just below B's key, without a reinsert
        keys.setKey(19, K, 1e18);
        keys.insert(19, 0, 0); // A: same key as B, higher id
        assertEq(list.getFirst(), 19, "A placed against D's lowered key, ahead of D");
        assertEq(list.getNext(19), 5);
        keys.remove(5); // D leaves; no remaining member has drifted
        assertEq(list.getFirst(), 19);
        assertEq(list.getNext(19), 12, "A directly ahead of B");
        (uint256 cA, uint256 nA) = keys.sortKey(19);
        (uint256 cB, uint256 nB) = keys.sortKey(12);
        assertEq(cA * nB, cB * nA, "exactly equal keys");
        assertGt(
            list.getFirst(), list.getNext(list.getFirst()), "so exact order (lower id first) is violated"
        );
        assertGe(cA * nB + 4 * (cA + nB) + 16, cB * nA, "while I13's tolerance check holds");
        // reinserting A while the list is exact restores exact order
        keys.reinsert(19, 0, 0);
        assertEq(list.getFirst(), 12);
        assertEq(list.getNext(12), 19);
    }

    // ------------------------------------------------------------------ HintHelpers

    function test_hintHelpers_emptyListAndClosestMember() public {
        HintHelpers h = new HintHelpers(ISortKeySource(address(keys)), ISortedPositions(address(list)));
        (uint256 id, uint256 d, uint256 seed) = h.getApproxHint(250, 100, 10, 7);
        assertEq(id, 0);
        assertEq(d, 0);
        assertEq(seed, 7);
        _five();
        keys.remove(4); // a non-member id is skipped when sampled
        (id, d, seed) = h.getApproxHint(310, 100, 200, 7);
        assertEq(id, 3, "closest NICR to 3.1 is id 3 (NICR 3)");
        assertEq(d, 0.1e20);
        assertTrue(seed != 7);
        (id,,) = h.getApproxHint(310, 100, 0, 7); // no trials: the tail
        assertEq(id, 5);
    }

    function test_hintHelpers_zeroDebtRanksAsInfinite() public {
        HintHelpers h = new HintHelpers(ISortKeySource(address(keys)), ISortedPositions(address(list)));
        _five();
        (uint256 id, uint256 d,) = h.getApproxHint(1, 0, 50, 3);
        assertEq(id, 1, "the highest NICR is closest to infinity");
        assertEq(d, type(uint256).max - 5e20);
    }

    function test_hintHelpers_hintIsUsableForInsert() public {
        HintHelpers h = new HintHelpers(ISortKeySource(address(keys)), ISortedPositions(address(list)));
        for (uint256 id = 1; id <= 40; ++id) {
            _put(id, 100 + 10 * id); // ascending keys: id 40 at the head
        }
        keys.setKey(41, 295, 100);
        (uint256 hint,,) = h.getApproxHint(295, 100, 40, 11);
        (bool f, uint256 p, uint256 n) = list.find(295, 100, 41, 0, hint, hint);
        assertTrue(f);
        keys.insert(41, hint, hint);
        assertEq(list.getPrev(41), p);
        assertEq(list.getNext(41), n);
    }
}
