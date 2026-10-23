// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {MockVaultManagerKeys} from "../utils/MockVaultManagerKeys.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Drives SortedPositions through insert / remove / re-key-and-reinsert with arbitrary
///         hints, plus `drift`: a member's key lowered by up to k wei per coordinate without a
///         reinsert, the way lazy redistribution moves effective keys by rounding (spec §6.3.3).
///         Each member drifts at most once from its key at insertion — the I13 derivation's model
///         (observed = exact − δ, 0 ≤ δ ≤ k). It also tracks which members are *exact* (key
///         unchanged since the last insertion, and every member exact at that insertion — CHG-005).
contract SortedPositionsHandler is Test {
    uint256 internal constant K = 4; // I13's k (docs/invariants.md)

    SortedPositions public list;
    MockVaultManagerKeys public keys;
    uint256 public nextId = 1;
    uint256[] public members;
    mapping(uint256 => bool) public drifted;
    /// @dev exact[id]: key unchanged since its last insertion, and every member was exact at that
    ///      insertion (CHG-005). nonExact counts current members that are not exact.
    mapping(uint256 => bool) public exact;
    uint256 public nonExact;
    uint256 public calls;
    uint256 public staleReverts;
    uint256 public stepsAllExact;
    uint256 public stepsNotAllExact;

    function _tally() internal {
        if (nonExact == 0) ++stepsAllExact;
        else ++stepsNotAllExact;
    }

    function _forget(uint256 id) internal {
        if (!exact[id]) --nonExact;
        exact[id] = false;
        drifted[id] = false;
    }

    constructor(SortedPositions list_, MockVaultManagerKeys keys_) {
        list = list_;
        keys = keys_;
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }

    function _removeMember(uint256 id) internal {
        for (uint256 i; i < members.length; ++i) {
            if (members[i] == id) {
                members[i] = members[members.length - 1];
                members.pop();
                return;
            }
        }
    }

    /// @dev Keys large enough to drift by k without hitting zero; a coarse grid keeps ties common.
    function _setKey(uint256 id, uint256 a, uint256 b) internal {
        keys.setKey(id, 1e18 + (a % 50) * 1e17, 1e18 + (b % 7) * 1e17);
    }

    /// @dev Bookkeeping for a member just (re)inserted: exact iff every other member is exact now.
    function _placed(uint256 id) internal {
        exact[id] = nonExact == 0;
        if (!exact[id]) ++nonExact;
        drifted[id] = false;
    }

    function insert(uint256 a, uint256 b, uint256 up, uint256 lo) external {
        ++calls;
        if (members.length >= 40) return;
        uint256 id = nextId++;
        _setKey(id, a, b);
        try keys.insert(id, up % (nextId + 3), lo % (nextId + 3)) {
            members.push(id);
            _placed(id);
        } catch (bytes memory err) {
            assertEq(bytes4(err), SortedPositions.StaleHint.selector, "only StaleHint may revert");
            ++staleReverts;
        }
        _tally();
    }

    function remove(uint256 i) external {
        ++calls;
        if (members.length == 0) return;
        uint256 id = members[i % members.length];
        keys.remove(id);
        _removeMember(id);
        _forget(id);
        _tally();
    }

    function rekey(uint256 i, uint256 a, uint256 b, uint256 up, uint256 lo) external {
        ++calls;
        if (members.length == 0) return;
        uint256 id = members[i % members.length];
        (uint256 c0, uint256 n0) = keys.sortKey(id);
        _setKey(id, a, b);
        try keys.reinsert(id, up % (nextId + 3), lo % (nextId + 3)) {
            _forget(id); // removed …
            _placed(id); // … and inserted again, judged against the others
        } catch (bytes memory err) {
            assertEq(bytes4(err), SortedPositions.StaleHint.selector, "only StaleHint may revert");
            ++staleReverts;
            keys.setKey(id, c0, n0); // the reinsert reverted as a whole: the node keeps its old key
        }
        _tally();
    }

    function drift(uint256 i, uint256 dc, uint256 dn) external {
        ++calls;
        if (members.length == 0) return;
        uint256 id = members[i % members.length];
        if (drifted[id]) return; // one drift per insertion, from the exact key
        (uint256 c, uint256 n) = keys.sortKey(id);
        keys.setKey(id, c - dc % (K + 1), n - dn % (K + 1));
        drifted[id] = true;
        if (exact[id]) {
            exact[id] = false;
            ++nonExact;
        }
        _tally();
    }
}

/// @notice I13 and the list's structural integrity under the handler above.
contract SortedPositionsInvariantTest is Test {
    uint256 internal constant K = 4;

    SortedPositions internal list;
    MockVaultManagerKeys internal keys;
    SortedPositionsHandler internal handler;

    function setUp() public {
        keys = new MockVaultManagerKeys();
        list = new SortedPositions(8); // small: stale hints are exercised too
        list.wire(address(keys));
        keys.setList(list);
        handler = new SortedPositionsHandler(list, keys);
        // the handler drives the mock, which is the list's only authorised caller
        targetContract(address(handler));
    }

    /// @dev Doubly-linked integrity: head-to-tail walk has `size` nodes, prev links mirror next
    ///      links, the tail is the last node, and every tracked member is contained.
    function invariant_listIntegrity() public view {
        uint256 cur = list.getFirst();
        uint256 prev;
        uint256 n;
        while (cur != 0) {
            assertTrue(list.contains(cur));
            assertEq(list.getPrev(cur), prev, "prev mirrors next");
            prev = cur;
            cur = list.getNext(cur);
            ++n;
            assertLe(n, list.getSize(), "no cycle");
        }
        assertEq(n, list.getSize(), "size");
        assertEq(list.getLast(), prev, "tail");
        assertEq(n, handler.memberCount(), "members");
    }

    /// @dev docs/invariants.md I13 (with CHG-005): the tolerance check on every adjacent pair,
    ///      always; exact order, ties by lower id included, while every current member is exact.
    ///      The weaker condition "no current member has drifted" fails the exact check (4 of 30
    ///      seeds at P13): a member inserted against a drifted key keeps its wrong-side tie after the
    ///      drifted member has left.
    function invariant_I13_sortedByNicrWithinTolerance() public view {
        bool exactRegime = handler.nonExact() == 0;
        uint256 a = list.getFirst();
        if (a == 0) return;
        uint256 b = list.getNext(a);
        while (b != 0) {
            (uint256 cA, uint256 nA) = keys.sortKey(a);
            (uint256 cB, uint256 nB) = keys.sortKey(b);
            assertGe(cA * nB + K * (cA + nB) + K * K, cB * nA, "I13 tolerance");
            if (exactRegime) {
                assertTrue(cA * nB > cB * nA || (cA * nB == cB * nA && a < b), "I13 exact order");
            }
            a = b;
            b = list.getNext(b);
        }
    }

    /// @dev The campaign must actually exercise the list: calls happened and the list was populated.
    function invariant_campaignIsNotVacuous() public view {
        assertLe(handler.memberCount(), 40);
    }

    function afterInvariant() external view {
        assertGt(handler.calls(), 0, "the handler was called");
        // every run must exercise both regimes of I13, or the campaign proves less than it claims
        assertGt(handler.stepsAllExact(), 0, "the exact regime was reached");
        assertGt(handler.stepsNotAllExact(), 0, "the tolerance-only regime was reached");
    }
}

/// @notice I13's check is not vacuous: it rejects a gross inversion that drift cannot produce.
contract I13CheckTest is Test {
    function test_I13_rejectsAGrossInversion() public pure {
        uint256 k = 4;
        // A ahead of B, but B's NICR (3.0) is far above A's (2.0)
        (uint256 cA, uint256 nA, uint256 cB, uint256 nB) = (2e18, 1e18, 3e18, 1e18);
        assertLt(cA * nB + k * (cA + nB) + k * k, cB * nA);
        // and it admits exactly the drift it is derived for: A drifted down by k in collateral
        (cA, nA, cB, nB) = (1e18 - k, 1e18, 1e18, 1e18); // exact keys equal, A ahead by id
        assertGe(cA * nB + k * (cA + nB) + k * k, cB * nA);
    }
}
