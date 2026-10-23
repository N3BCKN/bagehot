// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISortKeySource} from "../interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../interfaces/ISortedPositions.sol";
import {InvalidParameter, Unauthorized} from "../lib/Errors.sol";
import {WiredBase} from "../lib/Wired.sol";

/// @title SortedPositions
/// @notice Doubly-linked list of active position ids, ordered by effective NICR **descending** from
///         head to tail, ties broken by **lower id first** (docs/spec.md §4.3, §5.2, §6.3). Keys are
///         read from `VaultManager.sortKey(id)` at the moment of comparison and compared by exact
///         cross-multiplication — no NICR is ever divided out. Every walk is bounded by the
///         immutable `MAX_HINT_STEPS`; a hint that would need more steps reverts `StaleHint()`
///         instead of traversing the list (a DoS bound).
/// @dev Mutators are callable by the wired VaultManager only. No reentrancy lock: the list holds no
///      tokens and its only external call is the `sortKey` view (§5.10). Id 0 is the null link and
///      cannot be a node: inserting it reverts `NodeExists` (unreachable through the VaultManager,
///      whose ids start at 1).
contract SortedPositions is ISortedPositions, WiredBase {
    struct Node {
        bool exists;
        uint256 prev; // towards the head (higher NICR)
        uint256 next; // towards the tail (lower NICR)
    }

    error NodeExists();
    error NodeNotFound();
    error StaleHint();

    event NodeInserted(uint256 indexed id, uint256 prev, uint256 next);
    event NodeRemoved(uint256 indexed id);

    /// @notice Ranges of spec §3.1 / §3.4 checked by the constructor.
    uint256 public constant MIN_HINT_STEPS = 1;
    uint256 public constant MAX_HINT_STEPS_CEILING = 1000;

    uint256 public immutable MAX_HINT_STEPS;

    ISortKeySource public vaultManager;
    mapping(uint256 => Node) internal _nodes;
    uint256 internal _head;
    uint256 internal _tail;
    uint256 internal _size;

    constructor(uint256 maxHintSteps) {
        if (maxHintSteps < MIN_HINT_STEPS || maxHintSteps > MAX_HINT_STEPS_CEILING) {
            revert InvalidParameter(0);
        }
        MAX_HINT_STEPS = maxHintSteps;
    }

    /// @notice One-shot wiring (§3.4): the VaultManager, sole caller of the mutators and key source.
    function wire(address vaultManager_) external onlyWiring {
        _requireNonZero(vaultManager_, 0);
        vaultManager = ISortKeySource(vaultManager_);
        address[] memory addresses = new address[](1);
        addresses[0] = vaultManager_;
        _markWired(addresses);
    }

    modifier onlyVault() {
        if (msg.sender != address(vaultManager)) revert Unauthorized();
        _;
    }

    // ------------------------------------------------------------------ mutators (VaultManager)

    /// @notice Links `id` at the position its current key belongs (§5.2). VaultManager only.
    function insert(uint256 id, uint256 upperHint, uint256 lowerHint) external whenWired onlyVault {
        _insert(id, upperHint, lowerHint);
    }

    /// @notice Unlinks `id` (§5.2). VaultManager only.
    function remove(uint256 id) external whenWired onlyVault {
        _remove(id);
    }

    /// @notice `remove(id)` then `insert` with the key read after the caller's state change (§5.2).
    ///         Emits NodeRemoved then NodeInserted. VaultManager only.
    function reinsert(uint256 id, uint256 upperHint, uint256 lowerHint) external whenWired onlyVault {
        _remove(id);
        _insert(id, upperHint, lowerHint);
    }

    // ------------------------------------------------------------------ views

    /// @notice Non-reverting probe (§5.2, §6.3.2): where a node with key `(keyColl, keyNorm)` and id
    ///         `id` would go, on the list with `excludeId` treated as absent (0 = none). `found` is
    ///         false where `insert` would revert `StaleHint`.
    function find(
        uint256 keyColl,
        uint256 keyNorm,
        uint256 id,
        uint256 excludeId,
        uint256 upperHint,
        uint256 lowerHint
    ) external view returns (bool found, uint256 prev, uint256 next) {
        return _findInsertPosition(keyColl, keyNorm, id, excludeId, upperHint, lowerHint);
    }

    function contains(uint256 id) external view returns (bool) {
        return _nodes[id].exists;
    }

    function getFirst() external view returns (uint256) {
        return _head;
    }

    function getLast() external view returns (uint256) {
        return _tail;
    }

    function getNext(uint256 id) external view returns (uint256) {
        return _nodes[id].next;
    }

    function getPrev(uint256 id) external view returns (uint256) {
        return _nodes[id].prev;
    }

    function getSize() external view returns (uint256) {
        return _size;
    }

    // ------------------------------------------------------------------ internal: linking

    function _insert(uint256 id, uint256 upperHint, uint256 lowerHint) internal {
        if (id == 0 || _nodes[id].exists) revert NodeExists();
        (uint256 c, uint256 n) = vaultManager.sortKey(id);
        (bool found, uint256 prev, uint256 next) = _findInsertPosition(c, n, id, 0, upperHint, lowerHint);
        if (!found) revert StaleHint();
        _nodes[id] = Node(true, prev, next);
        if (prev == 0) _head = id;
        else _nodes[prev].next = id;
        if (next == 0) _tail = id;
        else _nodes[next].prev = id;
        ++_size;
        emit NodeInserted(id, prev, next);
    }

    function _remove(uint256 id) internal {
        Node memory node = _nodes[id];
        if (!node.exists) revert NodeNotFound();
        if (node.prev == 0) _head = node.next;
        else _nodes[node.prev].next = node.next;
        if (node.next == 0) _tail = node.prev;
        else _nodes[node.next].prev = node.prev;
        delete _nodes[id];
        --_size;
        emit NodeRemoved(id);
    }

    // ------------------------------------------------------------------ internal: §6.3.2

    /// @dev The list seen with `ex` unlinked (§6.3.2): every quantity is evaluated as if `ex` were
    ///      removed. `ex` = 0 or a non-member changes nothing.
    function _containsEx(uint256 x, uint256 ex) internal view returns (bool) {
        return x != 0 && x != ex && _nodes[x].exists;
    }

    function _nextEx(uint256 x, uint256 ex) internal view returns (uint256 n) {
        n = _nodes[x].next;
        if (n != 0 && n == ex) n = _nodes[ex].next;
    }

    function _prevEx(uint256 x, uint256 ex) internal view returns (uint256 p) {
        p = _nodes[x].prev;
        if (p != 0 && p == ex) p = _nodes[ex].prev;
    }

    /// @dev `precedes(kA, kB)` of §6.3.1 with key A = node `a` read from the VaultManager and key B
    ///      given: `cA·nB > cB·nA`, or equal and `a < idB`.
    function _nodePrecedes(uint256 a, uint256 cB, uint256 nB, uint256 idB) internal view returns (bool) {
        (uint256 cA, uint256 nA) = vaultManager.sortKey(a);
        return _precedes(cA, nA, a, cB, nB, idB);
    }

    /// @dev `precedes(newKey, key(b))`.
    function _precedesNode(uint256 cA, uint256 nA, uint256 idA, uint256 b) internal view returns (bool) {
        (uint256 cB, uint256 nB) = vaultManager.sortKey(b);
        return _precedes(cA, nA, idA, cB, nB, b);
    }

    /// @dev Exact cross-multiplication; products fit in 256 bits under §6.3.1's bounds.
    function _precedes(uint256 cA, uint256 nA, uint256 idA, uint256 cB, uint256 nB, uint256 idB)
        internal
        pure
        returns (bool)
    {
        uint256 l = cA * nB;
        uint256 r = cB * nA;
        return l > r || (l == r && idA < idB);
    }

    function _findInsertPosition(uint256 c, uint256 n, uint256 id, uint256 ex, uint256 upper, uint256 lower)
        internal
        view
        returns (bool found, uint256 prev, uint256 next)
    {
        if (upper != 0 && (!_containsEx(upper, ex) || !_nodePrecedes(upper, c, n, id))) upper = 0;
        if (lower != 0 && (!_containsEx(lower, ex) || !_precedesNode(c, n, id, lower))) lower = 0;
        if (upper != 0 && lower != 0 && _nextEx(upper, ex) == lower) return (true, upper, lower);
        if (upper != 0) return _walkDown(c, n, id, ex, upper);
        if (lower != 0) return _walkUp(c, n, id, ex, lower);
        uint256 head = _head;
        if (head != 0 && head == ex) head = _nodes[ex].next;
        if (head == 0) return (true, 0, 0); // size == 0 on the reduced list
        if (_precedesNode(c, n, id, head)) return (true, 0, head);
        return _walkDown(c, n, id, ex, head);
    }

    /// @dev Precondition: precedes(key(start), newKey). Each node read is one step.
    function _walkDown(uint256 c, uint256 n, uint256 id, uint256 ex, uint256 start)
        internal
        view
        returns (bool, uint256, uint256)
    {
        uint256 cur = start;
        for (uint256 i = 0; i < MAX_HINT_STEPS; ++i) {
            uint256 nxt = _nextEx(cur, ex);
            if (nxt == 0 || _precedesNode(c, n, id, nxt)) return (true, cur, nxt);
            cur = nxt;
        }
        return (false, 0, 0);
    }

    /// @dev Precondition: precedes(newKey, key(start)).
    function _walkUp(uint256 c, uint256 n, uint256 id, uint256 ex, uint256 start)
        internal
        view
        returns (bool, uint256, uint256)
    {
        uint256 cur = start;
        for (uint256 i = 0; i < MAX_HINT_STEPS; ++i) {
            uint256 prv = _prevEx(cur, ex);
            if (prv == 0 || _nodePrecedes(prv, c, n, id)) return (true, prv, cur);
            cur = prv;
        }
        return (false, 0, 0);
    }
}
