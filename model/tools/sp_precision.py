"""P19 precision study of the stability pool (spec §6.6, invariant I3's attribution bounds).

Replays long random sequences — deposits, partial and full withdrawals, claims, offsets (random,
exactly `T`, `T − 1`, near-emptying), interest — on the integer model
(`model/protocol/stability_pool.py`, bit-for-bit with the contract) alongside the exact pro-rata
reference of `model/invariants.py` (`fractions.Fraction`, reset at every snapshot as I3 defines it).
After every step it checks I3's integer inequalities, U4 and both attribution bounds, and records
the largest error per depositor:

- compounded deposit: exact share − compounded (never negative);
- collateral and interest gains: |exact − integer|, two-sided.

It writes the generated sequences with the integer model's state after every step to
`contracts/test/data/sp_precision/case_<n>.json`; `StabilityPoolPrecisionTest` replays them against
the contract and asserts bit equality. The summary goes to stdout (docs/fuzzing.md quotes it).

Run: uv run python -m model.tools.sp_precision [--cases N] [--steps N] [--seed S] [--no-write]
Floats appear only in the printed statistics, never in protocol state.
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path

from model.invariants import (
    Exact,
    check_I3,
    check_I3_attribution,
    check_I3_attribution_pre_chg010,
    check_U4,
)
from model.protocol.stability_pool import DECIMAL_PRECISION, StabilityPool, Tokens

OUT = Path("contracts/test/data/sp_precision")
ACTORS = ["a0", "a1", "a2", "a3", "a4"]
MIN_DEPOSIT = 10**18
PENALTY = 5 * 10**16


@dataclass
class Worst:
    """Largest observed error, with the T and step it occurred at."""

    compounded: Fraction = Fraction(0)
    coll: Fraction = Fraction(0)
    interest: Fraction = Fraction(0)
    coll_at_t: int = 0
    where: dict[str, str] = field(default_factory=dict)

    def update(self, pool: StabilityPool, exact: Exact, tag: str) -> None:
        for a, e in exact.depositors.items():
            comp = pool.compounded_deposit(a)
            cg, ig = pool.gains(a)
            if e.share - comp > self.compounded:
                self.compounded, self.where["compounded"] = e.share - comp, tag
            if abs(e.coll_gain - cg) > self.coll:
                self.coll, self.where["coll"] = abs(e.coll_gain - cg), tag
                self.coll_at_t = pool.total_deposits
            if abs(e.interest_gain - ig) > self.interest:
                self.interest, self.where["interest"] = abs(e.interest_gain - ig), tag


def _size(rng: random.Random, regime: str) -> int:
    if regime == "large":  # T ≈ 1e30, §6.6.7's adversarial regime
        return rng.randint(10**29, 10**30)
    if regime == "small":
        return rng.randint(MIN_DEPOSIT, 10**21)
    return rng.choice([rng.randint(MIN_DEPOSIT, 10**21), rng.randint(10**24, 10**30)])


def run_case(seed: int, steps: int, record: bool) -> tuple[Worst, list[str], list[dict]]:
    """One sequence. Returns the worst errors, any invariant violations, and the recorded steps."""
    rng = random.Random(seed)
    regime = ["mixed", "large", "small", "adversarial"][seed % 4]
    pool = StabilityPool(Tokens(), PENALTY, MIN_DEPOSIT)
    exact = Exact()
    worst = Worst()
    violations: list[str] = []
    pre: list[str] = []
    trace: list[dict] = []
    for a in ACTORS:
        pool.bank._mint(a, 10**33)

    def after(step: dict) -> None:
        tag = f"seed {seed} step {len(trace)}"
        violations.extend(f"{tag}: I3 {v}" for v in check_I3(pool, ACTORS))
        if not check_U4(pool, ACTORS):
            violations.append(f"{tag}: U4")
        violations.extend(f"{tag}: attribution {v}" for v in check_I3_attribution(pool, exact))
        pre.extend(f"{tag}: {v}" for v in check_I3_attribution_pre_chg010(pool, exact))
        worst.update(pool, exact, tag)
        if record:
            step["after"] = {
                "totalDeposits": str(pool.total_deposits),
                "P": str(pool.p),
                "currentScale": str(pool.current_scale),
                "currentEpoch": str(pool.current_epoch),
                "lastCollError": str(pool.last_coll_error),
                "lastInterestError": str(pool.last_interest_error),
                "collGainsBalance": str(pool.coll_gains_balance),
                "interestGainsBalance": str(pool.interest_gains_balance),
                "depositors": [
                    [str(pool.compounded_deposit(a)), *map(str, pool.gains(a))] for a in ACTORS
                ],
            }
        trace.append(step)

    for _ in range(steps):
        t = pool.total_deposits
        r = rng.random()
        if regime == "adversarial" and r < 0.15 and t > 0:
            # build a large carry, empty the pool, come back small (I3's worked case)
            d = t
            c = rng.randint(0, d * 3 // 4 + 1)
            exact.on_offset(t, d, c, pool)
            pool.hook_offset(d, c)
            after({"op": "offset", "d": str(d), "c": str(c)})
            continue
        if r < 0.30 or t == 0:
            a = rng.choice(ACTORS)
            amount = _size(
                rng, "small" if regime == "adversarial" and rng.random() < 0.5 else regime
            )
            try:
                pool.deposit(a, amount)
            except Exception as exc:  # DepositTooSmall cannot occur above MIN_DEPOSIT
                violations.append(f"seed {seed}: deposit reverted {type(exc).__name__}")
                continue
            exact.snapshot(pool, a)
            after({"op": "deposit", "who": ACTORS.index(a), "amount": str(amount)})
        elif r < 0.45:
            a = rng.choice(ACTORS)
            if pool.deposits.get(a) is None:
                continue
            comp = pool.compounded_deposit(a)
            x = 2**256 - 1 if rng.random() < 0.5 or comp <= MIN_DEPOSIT else rng.randint(1, comp)
            if 0 < comp - min(x, comp) < MIN_DEPOSIT:
                x = 2**256 - 1
            pool.withdraw(a, x)
            exact.snapshot(pool, a)
            after({"op": "withdraw", "who": ACTORS.index(a), "amount": str(x)})
        elif r < 0.52:
            a = rng.choice(ACTORS)
            if pool.deposits.get(a) is None:
                continue
            pool.claim_gains(a)
            exact.snapshot(pool, a)
            after({"op": "claim", "who": ACTORS.index(a)})
        elif r < 0.85:
            mode = rng.random()
            if mode < 0.10:
                d = t
            elif mode < 0.30:
                d = t - 1 if t > 1 else t
            elif mode < 0.45:
                d = t - t // 10**10 if t > 10**10 else t
            else:
                d = rng.randint(1, t)
            c = rng.randint(0, d * 3 // 4 + 1)  # §6.6.3
            exact.on_offset(t, d, c, pool)
            pool.hook_offset(d, c)
            after({"op": "offset", "d": str(d), "c": str(c)})
        else:
            g = rng.randint(0, 10**24)
            if t >= MIN_DEPOSIT:
                exact.on_interest(t, g, pool)
            pool.hook_on_interest(g)
            after({"op": "interest", "g": str(g)})
    violations.extend(f"pre-CHG-010 bound: {v}" for v in pre)
    return worst, violations, trace


OPS = {"deposit": 0, "withdraw": 1, "claim": 2, "offset": 3, "interest": 4}
STATE = [
    "totalDeposits",
    "P",
    "currentScale",
    "currentEpoch",
    "lastCollError",
    "lastInterestError",
    "collGainsBalance",
    "interestGainsBalance",
]


def _flat(seed: int, trace: list[dict]) -> dict:
    """The replay format: one array per field, so Foundry parses the file a handful of times, not
    once per value. Per step: `op` (OPS), `x` (who, or d), `y` (amount, c or g), and `state` — the
    eight STATE values, then (compounded, collGain, interestGain) for each actor, as decimal
    strings."""
    ops, x, y, state = [], [], [], []
    for step in trace:
        op = step["op"]
        ops.append(OPS[op])
        if op in ("deposit", "withdraw", "claim"):
            x.append(str(step["who"]))
            y.append(step.get("amount", "0"))
        elif op == "offset":
            x.append(step["d"])
            y.append(step["c"])
        else:
            x.append("0")
            y.append(step["g"])
        a = step["after"]
        state += [a[k] for k in STATE] + [v for row in a["depositors"] for v in row]
    return {
        "generator": "model/tools/sp_precision.py",
        "seed": seed,
        "MIN_DEPOSIT": str(MIN_DEPOSIT),
        "LIQUIDATION_PENALTY": str(PENALTY),
        "actors": len(ACTORS),
        "stateWidth": len(STATE) + 3 * len(ACTORS),
        "op": ops,
        "x": x,
        "y": y,
        "state": state,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cases", type=int, default=200)
    ap.add_argument("--steps", type=int, default=400)
    ap.add_argument("--seed", type=int, default=19)
    ap.add_argument("--write", type=int, default=8, help="cases written for the Foundry replay")
    ap.add_argument("--no-write", action="store_true")
    args = ap.parse_args()
    total = Worst()
    violations: list[str] = []
    rel_comp = Fraction(0)
    for n in range(args.cases):
        seed = args.seed * 10_000 + n
        record = not args.no_write and n < args.write
        worst, bad, trace = run_case(seed, args.steps, record)
        violations += bad
        for k in ("compounded", "coll", "interest"):
            if getattr(worst, k) > getattr(total, k):
                setattr(total, k, getattr(worst, k))
                total.where[k] = worst.where.get(k, "")
                if k == "coll":
                    total.coll_at_t = worst.coll_at_t
        if record:
            OUT.mkdir(parents=True, exist_ok=True)
            (OUT / f"case_{n}.json").write_text(
                json.dumps(_flat(seed, trace), separators=(",", ":")) + "\n"
            )
    print(f"cases {args.cases} × steps {args.steps}, seed {args.seed}")
    current = [v for v in violations if not v.startswith("pre-CHG-010")]
    pre = [v for v in violations if v.startswith("pre-CHG-010")]
    print(f"violations of I3 (with CHG-010): {len(current)}")
    print(f"violations of I3's gain bounds as written before CHG-010: {len(pre)}")
    for v in current[:20]:
        print("  ", v)
    print(
        f"max compounded error (exact − integer): {float(total.compounded):.6g} wei"
        f"  [{total.where.get('compounded')}]"
    )
    print(
        f"max collateral-gain error |exact − integer|: {float(total.coll):.6g} wei"
        f"  [{total.where.get('coll')}]"
    )
    print(
        f"max interest-gain error |exact − integer|: {float(total.interest):.6g} wei"
        f"  [{total.where.get('interest')}]"
    )
    print(f"(for scale: T / DECIMAL_PRECISION at T = 1e30 is {10**30 // DECIMAL_PRECISION} wei)")
    _ = rel_comp


if __name__ == "__main__":
    main()
