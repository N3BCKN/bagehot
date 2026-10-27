"""Every deployment-A system vector of spec/vectors/ replayed in full through `System` (P22).

Each step runs as the Foundry vector harness runs it: the price feed set to `price / 1e10` at the
step's time when the step names a price, the caller's transaction at `t`. Each step's result, revert
and drift record is compared, `check_invariants()` must hold after every step, and the final state
is compared against `expected` field by field — every expected key is consumed, so a field the
replay does not understand fails rather than passes silently.

`test_every_vector_case_is_replayed_or_deferred` accounts for all of spec/vectors/: each case is run
by a named test, or listed in docs/progress.md's carry-forward table with the prompt that will run
it — the same list as every other re-validation obligation.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from model.protocol.errors import ProtocolError
from model.protocol.math import RAY, WAD
from model.protocol.system import Params, System

ROOT = Path(__file__).resolve().parents[2]
VECTORS = {
    p.stem: {v["name"]: v for v in json.loads(p.read_text())["vectors"]}
    for p in sorted((ROOT / "spec" / "vectors").glob("*.json"))
}
SYSTEM_A = [
    (f, n)
    for f, vs in VECTORS.items()
    for n, v in vs.items()
    if v["level"] == "system" and v["inputs"].get("variant") == "A"
]
STATUS = {
    "Active": 1,
    "ClosedByOwner": 2,
    "ClosedByRedemption": 3,
    "ClosedByLiquidation": 4,
    "ClosedByShutdown": 5,
}
PATHS = {"NONE": 0, "REDISTRIBUTED": 1, "DEFICIT": 2}
HOLDER = {"vm": "vault"}


class Run:
    def __init__(self, vec: dict) -> None:
        inputs = vec["inputs"]
        self.s = System(Params.from_spec(inputs["params"]), t0=int(inputs["t0"]), record=True)
        self.now = int(inputs["t0"])
        self.weth0 = int(inputs["actorWeth"])
        for a in inputs["actors"]:
            self.s.fund(a, self.weth0)

    def step(self, st: dict) -> None:
        s, op = self.s, st["op"]
        assert int(st["t"]) == self.now
        if op == "warp":
            self.now += int(st["dt"])
            return
        if "price" in st:
            s.set_price(int(st["price"]), self.now)
        before = s.snapshot()
        expect = _Expect(st, s)
        try:
            receipt = _call(s, st, self.now)
        except ProtocolError as e:
            assert "revert" in st, f"{op} reverted {type(e).__name__}"
            assert type(e).__name__ == st["revert"]
            assert {k: v for k, v in s.snapshot().items() if k != "now"} == {
                k: v for k, v in before.items() if k != "now"
            }, "a reverted call leaves no trace"
        else:
            assert "revert" not in st, f"{op} should revert {st.get('revert')}"
            expect.check(receipt)
        if "drift" in st:
            _check_drift(s, st["drift"])
        assert s.check_invariants() == [], f"invariants after {op} at t={self.now}"


def _call(s: System, st: dict, now: int):  # noqa: ANN202 — Receipt
    op, who = st["op"], st.get("caller")
    hints = (int(st.get("upperHint", 0)), int(st.get("lowerHint", 0)))
    if op == "open":
        return s.open_position(who, int(st["coll"]), int(st["debt"]), *hints, now=now)
    if op in ("addCollateral", "borrow", "repay"):
        fn = {"addCollateral": s.add_collateral, "borrow": s.borrow, "repay": s.repay}[op]
        return fn(who, int(st["id"]), int(st["amount"]), *hints, now=now)
    if op == "close":
        return s.close(who, int(st["id"]), now=now)
    if op == "liquidate":
        return s.liquidate(who, int(st["id"]), now=now)
    if op == "deposit":
        return s.deposit(who, int(st["amount"]), now=now)
    if op == "transfer":
        return s.transfer(who, st["to"], int(st["amount"]), now=now)
    if op == "redeem":
        return s.redeem(
            who,
            int(st["amount"]),
            int(st["maxIterations"]),
            int(st["maxFeeRate"]),
            *hints,
            now=now,
        )
    raise AssertionError(f"no replay rule for {op}")


class _Expect:
    """The step's `result`, with what must be read before the call taken now."""

    def __init__(self, st: dict, s: System) -> None:
        self.st, self.s = st, s
        r = st.get("result", {})
        op = st["op"]
        if op == "deposit":
            assert s.pool.compounded_deposit(st["caller"]) == int(r["compoundedBefore"])
        elif op == "redeem" and "decayedBaseRate" in r:
            assert s.redemption.decayed_base_rate() == int(r["decayedBaseRate"])
        elif op == "liquidate":
            self.eff_norm = s.vault.effective(int(st["id"]))[1]
        elif op == "close":
            self.stable = s.token.balance_of(st["caller"])

    def check(self, receipt) -> None:  # noqa: ANN001, C901 — Receipt
        st, s, op = self.st, self.s, self.st["op"]
        r = st.get("result", {})
        events = [e for _, e in receipt.events]
        if op == "open":
            assert receipt.value == int(r["id"])
        elif op == "deposit":
            assert s.pool.deposits[st["caller"]].initial == int(r["deposit"])
            (paid,) = [e for e in events if e[0] == "GainsPaid"]
            assert (paid[2], paid[3]) == (int(r["collGainPaid"]), int(r["interestGainPaid"]))
        elif op == "close":
            (pc,) = [e for e in events if e[0] == "PositionClosed"]
            assert pc[2] == self.stable - s.token.balance_of(st["caller"]) == int(r["debtBurned"])
        elif op == "liquidate":
            (liq,) = [e for e in events if e[0] == "Liquidated"]
            _, _, _, _, debt, coll, absorbed, returned, norm_rest, path, gas = liq
            assert (debt, coll, absorbed, returned, norm_rest) == (
                int(r["debt"]),
                int(r["coll"]),
                int(r["debtAbsorbed"]),
                int(r["collRemainder"]),
                int(r["normRemainder"]),
            )
            assert self.eff_norm - norm_rest == int(r["normAbsorbed"])
            assert path == receipt.value == PATHS[r["remainderPath"]]
            assert gas == s.params.gas_reserve
            (pl,) = [e for e in events if e[0] == "PoolLiquidation"]
            pr = r["pool"]
            assert pl[4:] == tuple(
                int(pr[k])
                for k in ("seized", "surplus", "debtOffset", "collToPool", "collReturned")
            )
        elif op == "redeem":
            redeemed, coll_sent, iterations = receipt.value
            (red,) = [e for e in events if e[0] == "Redeemed"]
            assert (redeemed, coll_sent, iterations) == (
                int(r["redeemed"]),
                int(r["collSent"]),
                int(r["iterations"]),
            )
            assert red[5] == int(r["feeRate"])
            assert red[7] == int(r["baseRateAfter"]) == s.redemption.base_rate
            assert s.token.total_supply + redeemed == int(r["S0"])
            floor = s.params.redemption_fee_floor
            assert min(int(r["feeRate"]) - floor, WAD) == int(r["baseRateForFee"])
            lines = [t for t in r["trace"] if "skip" not in t]
            assert _trace(events) == lines
            assert len(r["trace"]) == iterations
        else:
            assert not r, f"unchecked result for {op}"


def _trace(events: list[tuple]) -> list[str]:
    out = []
    for e in events:
        if e[0] != "PositionRedeemed":
            continue
        _, pid, d, coll, surplus, closed = e
        if closed:
            out.append(
                f"visit {pid}: full redemption d={d} collToRedeemer={coll} surplusToOwner={surplus}"
            )
        else:
            out.append(f"visit {pid}: partial redemption d={d} collToRedeemer={coll}")
    return out


def _check_drift(s: System, d: dict) -> None:
    v, led, c = s.vault, s.ledger, s.ghost.counters
    supply = s.token.total_supply
    e = v.total_norm_debt * v.index - (supply - led.auction_debt - led.deficit) * RAY
    got = {
        "N": c.n,
        "X": c.x,
        "Y": c.y,
        "index": v.index,
        "totalNormDebt": v.total_norm_debt,
        "totalSupply": supply,
        "auctionDebt": led.auction_debt,
        "deficit": led.deficit,
        "E": e,
        "lowerBound": -c.n * RAY,
        "upperBound": c.x * v.index + c.y * RAY,
    }
    assert {k: str(x) for k, x in got.items()} == d


def _check_expected(run: Run, exp: dict) -> None:  # noqa: C901
    s = run.s
    snap = s.snapshot()
    seen = set()
    ev = exp["vault"]
    for k, want in ev.items():
        if k == "sortedOrder":
            assert s.sorted.order() == [int(x) for x in want]
        else:
            assert snap["vault"][k] == int(want), k
    seen.add("vault")
    for sid, ep in exp["positions"].items():
        pid, pos = int(sid), snap["vault"]["positions"][int(sid)]
        for k, want in ep.items():
            if k == "status":
                assert pos["status"] == STATUS[want], (pid, k)
            elif k == "owner":
                assert pos["owner"] == want
            elif k in ("effColl", "effNorm"):
                assert s.vault.effective(pid)[k == "effNorm"] == int(want), (pid, k)
            elif k == "debt":
                assert s.vault.debt_of(pid) == int(want), (pid, k)
            else:
                assert pos[k] == int(want), (pid, k)
    seen.add("positions")
    for k, want in exp["ledger"].items():
        assert snap["ledger"][k] == int(want), k
    for k, want in exp["redemption"].items():
        assert snap["redemption"][k] == int(want), k
    seen |= {"ledger", "redemption"}
    assert s.token.total_supply == int(exp["token"]["totalSupply"])
    for who, want in exp["token"]["balances"].items():
        assert s.token.balance_of(HOLDER.get(who, who)) == int(want), who
    assert set(exp["token"]) == {"totalSupply", "balances"}
    for who, want in exp["weth"].items():
        if who == "strategy":
            assert want == "0"  # the reference's pass-through account
        elif who in ("vm", "pool", "ledger"):
            assert s.weth.balance_of(HOLDER.get(who, who)) == int(want), who
        else:
            assert s.weth.balance_of(who) - run.weth0 == int(want), who
    seen |= {"token", "weth"}
    if "pool" in exp:
        _check_pool(s, snap["pool"], exp["pool"])
        seen.add("pool")
    assert set(exp) == seen, f"unchecked expected sections {set(exp) - seen}"


def _check_pool(s: System, sp: dict, ep: dict) -> None:
    for k, want in ep.items():
        if k in ("S", "G"):
            acc = s.pool.s if k == "S" else s.pool.g
            assert {f"{a}:{b}": str(x) for (a, b), x in acc.items() if x} == want, k
        elif k == "depositorCount":
            assert {e: c for e, c in s.pool.depositor_count.items() if c} == {
                int(e): int(n) for e, n in want.items() if int(n)
            }
        elif k == "deposits":
            for who, d in want.items():
                for f, x in d.items():
                    if f == "compounded":
                        assert s.pool.compounded_deposit(who) == int(x), (who, f)
                    elif f in ("collGain", "interestGain"):
                        assert s.pool.gains(who)[f == "interestGain"] == int(x), (who, f)
                    else:
                        assert sp["deposits"][who][f] == int(x), (who, f)
        else:
            assert sp[k] == int(want), k


@pytest.mark.parametrize(("file", "name"), SYSTEM_A, ids=[f"{f}#{n}" for f, n in SYSTEM_A])
def test_system_vector_replays_through_the_system(file: str, name: str) -> None:
    vec = VECTORS[file][name]
    run = Run(vec)
    for st in vec["steps"]:
        run.step(st)
    _check_expected(run, vec["expected"])
    assert run.s.check_invariants(with_unwind=True) == []


def test_the_replay_covers_every_variant_a_system_vector() -> None:
    assert len(SYSTEM_A) == 18
    assert ("drift", "sequence_A") in SYSTEM_A and ("drift", "no_stakes_deficit_A") in SYSTEM_A


# ---- accounting for every case of spec/vectors/ ----
# file -> the test module that runs each of its cases not replayed above
UNIT_RUNNERS = {
    "math": "test_math.py",
    "oracle": "test_oracle_model.py",
    "sorted_list": "test_sorted_list_model.py",
    "interest": "test_vault_interest_model.py",
    "product_sum": "test_stability_pool_model.py",
    "redistribution": "test_liquidation_model.py",
}


def _deferred() -> set[tuple[str, str]]:
    """`file.json#case` tokens in docs/progress.md's carry-forward table."""
    text = (ROOT / "docs" / "progress.md").read_text()
    section = text.split("## Carry-forward", 1)[1].split("\n## ", 1)[0]
    return {(f, c) for f, c in re.findall(r"`(\w+)\.json#(\w+)`", section)}


def test_every_vector_case_is_replayed_or_deferred() -> None:
    every = {(f, n) for f, vs in VECTORS.items() for n in vs}
    replayed = set(SYSTEM_A)
    unit = {
        (f, n)
        for f, vs in VECTORS.items()
        for n, v in vs.items()
        if v["level"] == "unit" and f in UNIT_RUNNERS
    }
    for f, module in UNIT_RUNNERS.items():  # the named runner really loads that file
        text = (Path(__file__).parent / module).read_text()
        assert f"{f}.json" in text or f'"{f}"' in text, (f, module)
    deferred = _deferred()
    assert not deferred & (replayed | unit), "a deferred case is also run: drop it from the table"
    assert deferred <= every, f"the carry-forward table names unknown cases {deferred - every}"
    missing = every - replayed - unit - deferred
    assert missing == set(), f"cases neither run nor deferred: {sorted(missing)}"
