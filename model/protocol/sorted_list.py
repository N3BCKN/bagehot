"""SortedPositions, bit-for-bit with `contracts/src/core/SortedPositions.sol`.

Spec §4.3, §5.2, §6.3. Integers only. The list stores ids; keys `(effColl, effNorm)` come from a
callable standing in for `VaultManager.sortKey(id)`, read at the moment of comparison. Order: NICR
descending by exact cross-multiplication, ties by lower id first (§6.3.1). Walks are bounded by
`max_hint_steps`; `insert` raises `StaleHint` where `find` returns `found = False` (§6.3.2).
`find` also reports the number of steps taken, which the vectors' traces record.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from model.protocol.errors import InvalidParameter, NodeExists, NodeNotFound, StaleHint
from model.protocol.events import Log

__all__ = ["NodeExists", "NodeNotFound", "SortedList", "StaleHint", "precedes"]

Key = tuple[int, int]
MAX_MAX_HINT_STEPS = 1_000


def precedes(ka: Key, ida: int, kb: Key, idb: int) -> bool:
    """§6.3.1: cA·nB > cB·nA, or equal and idA < idB."""
    left, right = ka[0] * kb[1], kb[0] * ka[1]
    return left > right or (left == right and ida < idb)


@dataclass
class SortedList:
    max_hint_steps: int
    key_of: Callable[[int], Key]
    nodes: dict[int, list[int]] = field(default_factory=dict)  # id -> [prev, next]
    head: int = 0
    tail: int = 0
    log: Log = field(default_factory=Log)

    def __post_init__(self) -> None:
        if not 1 <= self.max_hint_steps <= MAX_MAX_HINT_STEPS:  # §3.4, argument 0
            raise InvalidParameter(0)

    def _emit(self, event: tuple) -> None:
        self.log.emit("sorted", event)

    @property
    def events(self) -> list[tuple]:
        return self.log.of("sorted")

    def _save(self) -> tuple[dict[int, list[int]], int, int]:
        return {k: v[:] for k, v in self.nodes.items()}, self.head, self.tail

    def _restore(self, saved: tuple[dict[int, list[int]], int, int]) -> None:
        self.nodes, self.head, self.tail = saved

    @property
    def size(self) -> int:
        return len(self.nodes)

    def contains(self, x: int) -> bool:
        return x in self.nodes

    def order(self) -> list[int]:
        out, cur = [], self.head
        while cur:
            out.append(cur)
            cur = self.nodes[cur][1]
        return out

    # ---- the list seen with `ex` unlinked (§6.3.2) ----
    def _contains_ex(self, x: int, ex: int) -> bool:
        return x != 0 and x != ex and x in self.nodes

    def _next_ex(self, x: int, ex: int) -> int:
        n = self.nodes[x][1]
        return self.nodes[ex][1] if n != 0 and n == ex else n

    def _prev_ex(self, x: int, ex: int) -> int:
        p = self.nodes[x][0]
        return self.nodes[ex][0] if p != 0 and p == ex else p

    def find(
        self, key: Key, node_id: int, exclude: int, upper: int, lower: int
    ) -> tuple[bool, int, int, int]:
        """§6.3.2. Returns (found, prev, next, steps)."""
        if upper and (
            not self._contains_ex(upper, exclude)
            or not precedes(self.key_of(upper), upper, key, node_id)
        ):
            upper = 0
        if lower and (
            not self._contains_ex(lower, exclude)
            or not precedes(key, node_id, self.key_of(lower), lower)
        ):
            lower = 0
        if upper and lower and self._next_ex(upper, exclude) == lower:
            return True, upper, lower, 0
        if upper:
            return self._walk_down(key, node_id, exclude, upper)
        if lower:
            return self._walk_up(key, node_id, exclude, lower)
        head = self.head
        if head and head == exclude:
            head = self.nodes[exclude][1]
        if head == 0:
            return True, 0, 0, 0
        if precedes(key, node_id, self.key_of(head), head):
            return True, 0, head, 0
        return self._walk_down(key, node_id, exclude, head)

    def _walk_down(self, key: Key, node_id: int, ex: int, start: int) -> tuple[bool, int, int, int]:
        cur = start
        for step in range(1, self.max_hint_steps + 1):
            nxt = self._next_ex(cur, ex)
            if nxt == 0 or precedes(key, node_id, self.key_of(nxt), nxt):
                return True, cur, nxt, step
            cur = nxt
        return False, 0, 0, self.max_hint_steps

    def _walk_up(self, key: Key, node_id: int, ex: int, start: int) -> tuple[bool, int, int, int]:
        cur = start
        for step in range(1, self.max_hint_steps + 1):
            prv = self._prev_ex(cur, ex)
            if prv == 0 or precedes(self.key_of(prv), prv, key, node_id):
                return True, prv, cur, step
            cur = prv
        return False, 0, 0, self.max_hint_steps

    # ---- mutators ----
    def insert(self, node_id: int, upper: int, lower: int) -> None:
        if node_id == 0 or node_id in self.nodes:
            raise NodeExists()
        found, prev, nxt, _ = self.find(self.key_of(node_id), node_id, 0, upper, lower)
        if not found:
            raise StaleHint()
        self.nodes[node_id] = [prev, nxt]
        if prev == 0:
            self.head = node_id
        else:
            self.nodes[prev][1] = node_id
        if nxt == 0:
            self.tail = node_id
        else:
            self.nodes[nxt][0] = node_id
        self._emit(("NodeInserted", node_id, prev, nxt))

    def remove(self, node_id: int) -> None:
        if node_id not in self.nodes:
            raise NodeNotFound()
        prev, nxt = self.nodes.pop(node_id)
        if prev == 0:
            self.head = nxt
        else:
            self.nodes[prev][1] = nxt
        if nxt == 0:
            self.tail = prev
        else:
            self.nodes[nxt][0] = prev
        self._emit(("NodeRemoved", node_id))

    def reinsert(self, node_id: int, upper: int, lower: int) -> None:
        """remove, then insert with the fresh key; a StaleHint undoes both, as the revert does."""
        if node_id not in self.nodes:
            raise NodeNotFound()
        saved, mark = self._save(), self.log.mark()
        self.remove(node_id)
        try:
            self.insert(node_id, upper, lower)
        except StaleHint:
            self._restore(saved)
            self.log.truncate(mark)
            raise
