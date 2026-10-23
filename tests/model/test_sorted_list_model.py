"""model/protocol/sorted_list.py against spec/vectors/sorted_list.json and a sorted reference.

The Solidity list is checked against the same vectors in
contracts/test/vectors/SortedListVectors.t.sol, so passing both suites means the two sides agree.
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from model.protocol import sorted_list as s

DATA = json.loads(Path("spec/vectors/sorted_list.json").read_text())["vectors"]
ORDER, FIND = DATA[0], DATA[1]
KEYS = {int(i): (int(k["coll"]), int(k["norm"])) for i, k in ORDER["inputs"]["keys"].items()}


def build(max_steps: int, exact_hints: bool, ids: list[int] | None = None) -> s.SortedList:
    keys = dict(KEYS)
    lst = s.SortedList(max_steps, lambda i: keys[i])
    if ids is not None:
        for i in ids:
            lst.insert(i, 0, 0)
        return lst
    for st_ in ORDER["steps"]:
        r = st_["result"]
        up, lo = (r["prev"], r["next"]) if exact_hints else (st_["upperHint"], st_["lowerHint"])
        lst.insert(int(st_["id"]), int(up), int(lo))
        assert lst.nodes[int(st_["id"])] == [int(r["prev"]), int(r["next"])]
    return lst


def steps_in(trace: list[str]) -> int | None:
    for t in trace:
        m = re.search(r"found after (\d+) step", t)
        if m:
            return int(m.group(1))
    return None


def test_order_with_ties() -> None:
    lst = build(int(ORDER["inputs"]["MAX_HINT_STEPS"]), exact_hints=False)
    exp = ORDER["expected"]
    assert lst.order() == [int(x) for x in exp["order"]]
    assert (lst.head, lst.tail) == (int(exp["head"]), int(exp["tail"]))


def test_order_with_ties_step_counts_match_the_traces() -> None:
    keys = dict(KEYS)
    lst = s.SortedList(30, lambda i: keys[i])
    for st_ in ORDER["steps"]:
        i = int(st_["id"])
        found, prev, nxt, steps = lst.find(keys[i], i, 0, 0, 0)
        assert found
        expected = steps_in(st_["result"]["trace"])
        if expected is not None:
            assert steps == expected
        lst.insert(i, 0, 0)


@pytest.mark.parametrize("case", FIND["steps"], ids=[c["case"] for c in FIND["steps"]])
def test_find_cases(case: dict) -> None:
    ids = [int(x) for x in case["list"]] if "list" in case else None
    lst = build(int(case["MAX_HINT_STEPS"]), exact_hints=True, ids=ids)
    key = (int(case["keyColl"]), int(case["keyNorm"]))
    found, prev, nxt, steps = lst.find(
        key, int(case["id"]), int(case["excludeId"]), int(case["upperHint"]), int(case["lowerHint"])
    )
    r = case["result"]
    assert found is r["found"]
    if found:
        assert (prev, nxt) == (int(r["prev"]), int(r["next"]))
        expected = steps_in(r["trace"])
        if expected is not None:
            assert steps == expected
    else:
        assert r["revert"] == "StaleHint"


def test_errors() -> None:
    keys = {1: (300, 100), 2: (200, 100)}
    lst = s.SortedList(1, lambda i: keys[i])
    lst.insert(1, 0, 0)
    with pytest.raises(s.NodeExists):
        lst.insert(1, 0, 0)
    with pytest.raises(s.NodeExists):
        lst.insert(0, 0, 0)
    with pytest.raises(s.NodeNotFound):
        lst.remove(2)
    with pytest.raises(s.NodeNotFound):
        lst.reinsert(2, 0, 0)


def test_failed_reinsert_leaves_the_list_unchanged() -> None:
    keys = {i: (1000 - 100 * i, 100) for i in range(1, 6)}
    lst = s.SortedList(1, lambda i: keys[i])
    for i in range(1, 6):
        lst.insert(i, i - 1, 0)
    before = (lst.order(), list(lst.events))
    keys[1] = (1, 100)  # 1 now belongs at the bottom: 4 steps from the new head, MAX 1
    with pytest.raises(s.StaleHint):
        lst.reinsert(1, 0, 0)
    assert (lst.order(), lst.events) == before


@settings(max_examples=300, deadline=None)
@given(
    st.lists(
        st.tuples(st.integers(0, 2), st.integers(1, 12), st.integers(1, 4), st.integers(0, 99)),
        max_size=60,
    )
)
def test_random_sequences_match_a_sorted_reference(ops: list[tuple[int, int, int, int]]) -> None:
    keys: dict[int, tuple[int, int]] = {}
    lst = s.SortedList(1_000, lambda i: keys[i])
    next_id = 1
    for kind, c, n, pick in ops:
        members = lst.order()
        if kind == 0 or not members:
            keys[next_id] = (c, n)
            hint = members[pick % len(members)] if members else 0
            lst.insert(next_id, hint, hint)
            next_id += 1
        elif kind == 1:
            lst.remove(members[pick % len(members)])
        else:
            i = members[pick % len(members)]
            keys[i] = (c, n)
            lst.reinsert(i, 0, 0)
        # the reference: sort the members by the precedes relation itself (§6.3.1), no walk
        ref = sorted(
            lst.nodes,
            key=functools.cmp_to_key(lambda a, b: -1 if s.precedes(keys[a], a, keys[b], b) else 1),
        )
        assert lst.order() == ref
        assert lst.size == len(ref)


def test_chg005_tie_reversed_through_a_drifted_neighbour_that_has_since_left() -> None:
    """Permanent regression for CHG-005, the same five operations as the Foundry test."""
    k = 2 * 10**18
    keys = {12: (k, 10**18), 5: (k + 3, 10**18), 19: (k, 10**18)}
    lst = s.SortedList(30, lambda i: keys[i])
    lst.insert(12, 0, 0)  # B
    lst.insert(5, 0, 0)  # D, just above B
    keys[5] = (k + 3 - 4, 10**18)  # D drifts below B's key without a reinsert
    lst.insert(19, 0, 0)  # A, B's key, higher id: placed ahead of D
    assert lst.order() == [19, 5, 12]
    lst.remove(5)  # no remaining member has drifted
    assert lst.order() == [19, 12]  # equal keys, higher id first: not exactly ordered
    ca, na = keys[19]
    cb, nb = keys[12]
    assert ca * nb == cb * na
    assert ca * nb + 4 * (ca + nb) + 16 >= cb * na  # I13's tolerance holds
    lst.reinsert(19, 0, 0)  # reinserted while the list is exact: order restored
    assert lst.order() == [12, 19]
