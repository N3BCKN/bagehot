"""Benchmark the deployment-A `System` (P22): 1,000 positions, then 10,000 mixed operations.

    uv run python -m model.tools.bench                 # ops/second
    uv run python -m model.tools.bench --profile       # plus the cProfile top 25 (cumulative)

Deterministic (seeded). Only the protocol calls are timed; exact hints are computed outside the
timer by walking the list, as an off-chain client would. Reverts count as operations (a simulation
pays for them too) and are reported separately. `record=False`: no invariant bookkeeping, which is
how the simulator runs the model.
"""

from __future__ import annotations

import argparse
import cProfile
import pstats
import random
import time
from collections import Counter

from model.protocol.errors import ProtocolError
from model.protocol.math import RAY, WAD, mul_div_down, mul_div_up
from model.protocol.sorted_list import precedes
from model.protocol.system import System

ACTORS = [f"a{i}" for i in range(50)]


class Bench:
    def __init__(self, seed: int) -> None:
        self.rng = random.Random(seed)
        self.s = System()
        self.now = self.s.now
        self.price = 2_000 * WAD
        self.s.set_price(self.price, self.now)
        for a in ACTORS:
            self.s.fund(a, 10**27)
        self.elapsed = 0.0
        self.ops: Counter[str] = Counter()
        self.reverts: Counter[str] = Counter()

    # ---- the client side: exact hints for a key (untimed) ----
    def hints(self, key: tuple[int, int], pid: int) -> tuple[int, int]:
        srt = self.s.sorted
        prev, cur = 0, srt.head
        while cur:
            if cur != pid:
                if precedes(key, pid, srt.key_of(cur), cur):
                    return prev, cur
                prev = cur
            cur = srt.nodes[cur][1]
        return prev, 0

    def _index(self) -> int:
        return self.s.vault.current_index()

    # ---- timing ----
    def call(self, name: str, fn, *args, **kw) -> None:  # noqa: ANN001
        t = time.perf_counter()
        try:
            fn(*args, now=self.now, **kw)
        except ProtocolError:
            self.reverts[name] += 1
        self.elapsed += time.perf_counter() - t
        self.ops[name] += 1

    # ---- operations ----
    def open(self) -> None:
        rng, s = self.rng, self.s
        debt = rng.randint(2_000, 20_000) * WAD
        coll = debt * rng.randint(120, 300) // (100 * self.price) * WAD + WAD
        n = mul_div_up(debt, RAY, self._index())
        h = self.hints((coll, n), s.vault.next_id)
        self.call("open", s.open_position, rng.choice(ACTORS), coll, debt, *h)

    def _active(self) -> int | None:
        nodes = self.s.sorted.nodes
        return self.rng.choice(list(nodes)) if nodes else None

    def adjust(self) -> None:
        pid = self._active()
        if pid is None:
            return
        rng, s, v = self.rng, self.s, self.s.vault
        owner = v.positions[pid].owner
        c, n = v.effective(pid)
        kind = rng.choice(["add", "withdraw", "borrow", "repay"])
        if kind == "add":
            x = rng.randint(1, 5) * WAD
            self.call(
                "addCollateral", s.add_collateral, owner, pid, x, *self.hints((c + x, n), pid)
            )
        elif kind == "withdraw":
            x = c // rng.randint(5, 50)
            h = self.hints((c - x, n), pid)
            self.call("withdrawCollateral", s.withdraw_collateral, owner, pid, x, *h)
        elif kind == "borrow":
            x = rng.randint(1, 2_000) * WAD
            h = self.hints((c, n + mul_div_up(x, RAY, self._index())), pid)
            self.call("borrow", s.borrow, owner, pid, x, *h)
        else:
            x = max(1, (v.debt_of(pid) - 2_000 * WAD) // rng.randint(2, 10))
            h = self.hints((c, n - mul_div_down(x, RAY, self._index())), pid)
            self.call("repay", s.repay, owner, pid, x, *h)

    def close(self) -> None:
        pid = self._active()
        if pid is not None:
            self.call("close", self.s.close, self.s.vault.positions[pid].owner, pid)

    def liquidate(self) -> None:
        tail = self.s.sorted.tail
        if tail:
            self.call("liquidate", self.s.liquidate, self.rng.choice(ACTORS), tail)

    def redeem(self) -> None:
        who = max(self.rng.sample(ACTORS, 5), key=self.s.token.balance_of)
        x = self.s.token.balance_of(who) // self.rng.randint(2, 20)
        self.call("redeem", self.s.redeem, who, max(x, 1), 10, WAD)

    def pool(self) -> None:
        rng, s = self.rng, self.s
        who = rng.choice(ACTORS)
        kind = rng.choice(["deposit", "deposit", "withdraw", "claim"])
        if kind == "deposit":
            self.call("deposit", s.deposit, who, max(s.token.balance_of(who) // 3, 1))
        elif kind == "withdraw":
            self.call("withdraw", s.withdraw, who, 2**256 - 1)
        else:
            self.call("claimGains", s.claim_gains, who)

    def market(self) -> None:
        """Time and price move; the feed posts a fresh round."""
        self.now += self.rng.randint(1, 3_600)
        self.price = max(self.price * self.rng.randint(95, 105) // 100, 500 * WAD)
        self.s.set_price(self.price, self.now)

    def run(self, positions: int, operations: int) -> None:
        while self.s.vault.active_count < positions:
            self.open()
        self.ops.clear()
        self.reverts.clear()
        self.elapsed = 0.0
        mix = [
            (self.open, 15),
            (self.adjust, 30),
            (self.close, 10),
            (self.liquidate, 5),
            (self.redeem, 5),
            (self.pool, 15),
            (lambda: self.call("accrue", self.s.accrue, "keeper"), 5),
            (lambda: self.call("cover", self.s.cover, "keeper"), 5),
            (self.market, 10),
        ]
        fns, weights = zip(*mix, strict=True)
        done = 0
        while done < operations:
            self.rng.choices(fns, weights)[0]()
            done = sum(self.ops.values())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--positions", type=int, default=1_000)
    ap.add_argument("--operations", type=int, default=10_000)
    ap.add_argument("--seed", type=int, default=22)
    ap.add_argument("--profile", action="store_true")
    args = ap.parse_args()
    b = Bench(args.seed)
    if args.profile:
        prof = cProfile.Profile()
        prof.enable()
    b.run(args.positions, args.operations)
    if args.profile:
        prof.disable()
        pstats.Stats(prof).sort_stats("cumulative").print_stats(25)
    n = sum(b.ops.values())
    print(f"positions at the start: {args.positions}; active at the end: {b.s.vault.active_count}")
    print(f"operations: {n} ({sum(b.reverts.values())} reverted), protocol time {b.elapsed:.2f} s")
    print(f"ops/second: {n / b.elapsed:,.0f}")
    print("by operation:", dict(sorted(b.ops.items())))
    print("reverts:", dict(sorted(b.reverts.items())))


if __name__ == "__main__":
    main()
