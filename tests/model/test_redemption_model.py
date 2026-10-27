"""Redemption in model/protocol/{vault,redemption}.py (P16) against spec/vectors/redemption.json,
end to end with the full expected state, plus the rules of §6.7 the vectors do not pin. The
contracts run the same vectors in contracts/test/vectors/RedemptionVectors.t.sol."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from model.protocol import errors as er
from model.protocol import redemption as rd
from model.protocol import vault as vm
from model.protocol.errors import ProtocolError
from model.protocol.math import RAY, WAD, mul_div_down, mul_div_up

VECTORS = json.loads(Path("spec/vectors/redemption.json").read_text())["vectors"]
STATUS = {
    "Active": vm.Status.ACTIVE,
    "ClosedByRedemption": vm.Status.CLOSED_BY_REDEMPTION,
    "ClosedByOwner": vm.Status.CLOSED_BY_OWNER,
}


class Env:
    """One deployment-A system built from a vector's inputs: the vault, the module, the price."""

    def __init__(self, inputs: dict) -> None:
        p = {k: int(x) for k, x in inputs["params"].items()}
        self.p = p
        self.price = 2_000 * WAD
        t0 = int(inputs["t0"])
        self.v = vm.Vault(
            p["MCR"],
            p["MIN_DEBT"],
            p["GAS_RESERVE"],
            p["MAX_HINT_STEPS"],
            lambda: (self.price, True),
            rate_per_second=p["RATE_PER_SECOND"],
            pool_share_bps=p["POOL_SHARE_BPS"],
            has_pool=inputs["variant"] == "A",
            # no pool deposits in any redemption vector: the default pool hook declines
            now=t0,
            last_accrual=t0,
        )
        self.weth0 = int(inputs["actorWeth"])
        for a in inputs["actors"]:
            self.v.weth[a] = self.weth0
        self.rm = rd.RedemptionModule(
            self.v,
            p["REDEMPTION_FEE_FLOOR"],
            p["BETA"],
            p["BASE_RATE_DECAY"],
            rd.make_gate(self.v, p["CRITICAL_TCR"]),
        )

    @staticmethod
    def trace(events: list[tuple]) -> list[str]:
        """The vector's non-skip trace lines, rebuilt from the PositionRedeemed events."""
        out = []
        for e in events:
            if e[0] != "PositionRedeemed":
                continue
            _, pid, d, coll, surplus, closed = e
            if closed:
                out.append(
                    f"visit {pid}: full redemption d={d} collToRedeemer={coll} "
                    f"surplusToOwner={surplus}"
                )
            else:
                out.append(f"visit {pid}: partial redemption d={d} collToRedeemer={coll}")
        return out


def _run_step(env: Env, step: dict) -> None:
    v, op = env.v, step["op"]
    assert int(step["t"]) == v.now
    if op == "warp":
        v.now += int(step["dt"])
        return
    env.price = int(step["price"])
    if op == "open":
        pid = v.open_position(
            step["caller"],
            int(step["coll"]),
            int(step["debt"]),
            int(step["upperHint"]),
            int(step["lowerHint"]),
        )
        assert pid == int(step["result"]["id"])
        return
    assert op == "redeem"
    args = (
        step["caller"],
        int(step["amount"]),
        int(step["maxIterations"]),
        int(step["maxFeeRate"]),
        int(step["upperHint"]),
        int(step["lowerHint"]),
    )
    if "revert" in step:
        before = _snapshot(env)
        with pytest.raises(ProtocolError) as exc:
            env.rm.redeem(*args)
        assert type(exc.value).__name__ == step["revert"]
        assert _snapshot(env) == before, "a reverted redeem leaves no trace"
        return
    r = step["result"]
    assert env.rm.decayed_base_rate() == int(r["decayedBaseRate"])
    n_events = len(v.events)
    redeemed, coll_sent, iterations = env.rm.redeem(*args)
    rm_event = env.rm.events[-1]
    assert redeemed == int(r["redeemed"])
    assert coll_sent == int(r["collSent"])
    assert iterations == int(r["iterations"])
    assert rm_event[5] == int(r["feeRate"])
    assert rm_event[7] == int(r["baseRateAfter"]) == env.rm.base_rate
    assert v.total_supply + redeemed == int(r["S0"])
    assert min(int(r["feeRate"]) - env.p["REDEMPTION_FEE_FLOOR"], WAD) == int(r["baseRateForFee"])
    redeemed_lines = [t for t in r["trace"] if "skip" not in t]
    assert env.trace(v.events[n_events:]) == redeemed_lines
    assert len(r["trace"]) == iterations
    for line in r["trace"]:
        if "skip" in line:  # skipped nodes were below MCR at the redemption's price and index
            pid = int(line.split()[1].rstrip(":"))
            assert v.is_liquidatable(pid, env.price)


def _snapshot(env: Env) -> tuple:
    v = env.v
    return (
        repr(v.positions),
        v.sorted.order(),
        v.index,
        v.last_accrual,
        v.total_norm_debt,
        v.total_collateral,
        v.total_stakes,
        dict(v.stable),
        dict(v.weth),
        v.total_supply,
        env.rm.base_rate,
        env.rm.last_fee_operation_time,
    )


def _check_expected(env: Env, exp: dict) -> None:
    v = env.v
    ev = exp["vault"]
    for key, attr in (
        ("index", "index"),
        ("lastAccrual", "last_accrual"),
        ("totalNormDebt", "total_norm_debt"),
        ("totalCollateral", "total_collateral"),
        ("totalStakes", "total_stakes"),
        ("totalStakesSnapshot", "total_stakes_snapshot"),
        ("totalCollateralSnapshot", "total_collateral_snapshot"),
        ("LColl", "l_coll"),
        ("LDebt", "l_debt"),
        ("pendingColl", "pending_coll"),
        ("pendingNormDebt", "pending_norm_debt"),
        ("activeCount", "active_count"),
    ):
        assert getattr(v, attr) == int(ev[key]), key
    assert ev["lastErrorColl"] == ev["lastErrorDebt"] == "0"  # redistribution carries arrive at P20
    assert v.sorted.order() == [int(x) for x in ev["sortedOrder"]]
    for pid_s, ep in exp["positions"].items():
        pos = v.positions[int(pid_s)]
        assert pos.owner == ep["owner"]
        assert pos.status == STATUS[ep["status"]]
        assert (pos.coll, pos.norm_debt, pos.stake) == (
            int(ep["coll"]),
            int(ep["normDebt"]),
            int(ep["stake"]),
        )
        assert (pos.snap_l_coll, pos.snap_l_debt) == (int(ep["snapLColl"]), int(ep["snapLDebt"]))
        if "effColl" in ep:
            assert v.effective(int(pid_s)) == (int(ep["effColl"]), int(ep["effNorm"]))
            assert v.debt_of(int(pid_s)) == int(ep["debt"])
    led = exp["ledger"]
    assert v.ledger_reserve == int(led["reserve"])
    assert led["auctionDebt"] == led["deficit"] == led["recoveredColl"] == "0"
    assert env.rm.base_rate == int(exp["redemption"]["baseRate"])
    assert env.rm.last_fee_operation_time == int(exp["redemption"]["lastFeeOperationTime"])
    assert v.total_supply == int(exp["token"]["totalSupply"])
    for who, bal in exp["token"]["balances"].items():
        assert v.stable.get(who, 0) == int(bal), who
    assert sum(v.stable.values()) == v.total_supply
    for who, delta in exp["weth"].items():
        if who == "vm":
            assert v.weth.get("vault", 0) == int(delta)
        else:
            assert v.weth.get(who, 0) - env.weth0 == int(delta), who
    pool = exp["pool"]
    assert pool["totalDeposits"] == "0" and v.pool_interest == 0 and v.stable.get("pool", 0) == 0


@pytest.mark.parametrize("vec", VECTORS, ids=[v["name"] for v in VECTORS])
def test_vectors_redemption(vec: dict) -> None:
    env = Env(vec["inputs"])
    for step in vec["steps"]:
        _run_step(env, step)
    _check_expected(env, vec["expected"])


def test_vector_count() -> None:
    assert len(VECTORS) == 7


# ---- CHG-002 on the real branch (P04-2) ----


def _boundary_env() -> tuple[Env, dict]:
    vec = next(v for v in VECTORS if v["name"] == "partial_cancelled_below_mcr")
    env = Env(vec["inputs"])
    for step in vec["steps"]:
        if step["op"] == "redeem":
            break
        _run_step(env, step)
    return env, vec


def test_chg002_eleven_wei_takes_the_post_check_branch() -> None:
    """The 11-wei partial passes every earlier exit (not skipped, not at MIN_DEBT, a slot exists)
    and is cancelled by the CHG-002 inequality alone; without it the position ends below MCR."""
    env, _ = _boundary_env()
    v, price = env.v, env.price
    tail = v.sorted.tail
    c, n = v.effective(tail)
    debt = mul_div_up(n, v.index, RAY)
    assert c * price == v.mcr * debt  # exactly at MCR: not skipped
    assert debt - v.min_debt >= 11  # not at MIN_DEBT
    fee = env.rm.redemption_fee_rate(11)
    dn, out = mul_div_down(11, RAY, v.index), mul_div_down(11, WAD - fee, price)
    assert (dn, out) == (8, 1)
    found, *_ = v.sorted.find((c - out, n - dn), tail, tail, 0, 0)
    assert found  # the slot exists: the stale-hint exit is not what cancels it
    assert (c - out) * price < v.mcr * mul_div_up(n - dn, v.index, RAY)  # CHG-002 fires
    before = _snapshot(env)
    redeemed, coll, it = v.redeem_collateral("redemption", "erin", 11, fee, price, 5, 0, 0)
    assert (redeemed, coll, it) == (0, 0, 1)
    assert _snapshot(env) == before


# ---- rules the vectors do not pin ----


def _simple_env(n_positions: int = 3) -> Env:
    env = Env(VECTORS[0]["inputs"])
    v = env.v
    for i, who in enumerate(["alice", "bob", "carol", "dave", "erin", "frank"][:n_positions]):
        v.open_position(who, (3 + i) * WAD, 4_000 * WAD, 0, 0)
    return env


def test_redeem_collateral_unauthorized() -> None:
    env = _simple_env()
    with pytest.raises(er.Unauthorized):
        env.v.redeem_collateral("erin", "erin", 1, 0, 2_000 * WAD, 1, 0, 0)


@pytest.mark.parametrize(
    ("args", "err"),
    [
        ((0, 10, WAD, 0, 0), "ZeroAmount"),
        ((10, 0, WAD, 0, 0), "ZeroIterations"),
        ((10**30, 10, WAD, 0, 0), "InsufficientBalance"),
        ((1_000 * WAD, 10, 0, 0, 0), "FeeExceedsMaximum"),
    ],
)
def test_redeem_errors(args: tuple, err: str) -> None:
    env = _simple_env()
    with pytest.raises(ProtocolError) as exc:
        env.rm.redeem("alice", *args)
    assert type(exc.value).__name__ == err


def test_redeem_shutdown_and_unusable_price() -> None:
    env = _simple_env()
    env.v.shutdown = True
    with pytest.raises(er.SystemShutdown):
        env.rm.redeem("alice", WAD, 10, WAD, 0, 0)
    env.v.shutdown = False
    env.v.price_source = lambda: (0, False)
    with pytest.raises(er.PriceUnusable):
        env.rm.redeem("alice", WAD, 10, WAD, 0, 0)


def test_redeem_auction_callback_active() -> None:
    """P02-4, §6.7.2: checked after the price fetch and the accrual, before the gate; the revert
    takes the accrual with it."""
    env = _simple_env()
    env.v.now += 3_600  # so the call accrues before it reverts
    env.rm.in_purchase = lambda: True
    reads: list[int] = []
    price_source = env.v.price_source
    env.v.price_source = lambda: reads.append(1) or price_source()

    def gate(_price: int) -> bool:
        raise AssertionError("the gate runs after the callback check")

    env.rm.below_critical = gate
    before = _snapshot(env)
    with pytest.raises(er.AuctionCallbackActive):
        env.rm.redeem("alice", WAD, 10, WAD, 0, 0)
    assert reads == [1]  # the price was fetched first
    assert _snapshot(env) == before  # index and lastAccrual included


def test_gate_is_strict_at_critical_tcr() -> None:
    """TCR exactly at CRITICAL_TCR must not block (strict <), one wei of price lower must."""
    env = _simple_env(1)
    v = env.v
    c, d = v.system_coll(), v.system_debt()
    crit = env.p["CRITICAL_TCR"]
    p_eq = -(-crit * d // c)  # smallest price with C·p ≥ CRITICAL_TCR·D
    gate = rd.make_gate(v, crit)
    assert not gate(p_eq)
    assert gate(p_eq - 1)


def test_gate_not_live_never_blocks() -> None:
    env = _simple_env(0)
    env.v.ledger.record_deficit("vault", 10**21, 0)  # through the hook, not a bare write
    assert not rd.make_gate(env.v, env.p["CRITICAL_TCR"])(10 * WAD)


def test_decayed_base_rate_floors_at_one_wei() -> None:
    env = _simple_env()
    env.rm.base_rate = 1
    env.v.now += 10**7
    assert env.rm.decayed_base_rate() == 1
    env.rm.base_rate = 0
    assert env.rm.decayed_base_rate() == 0


def test_fee_rate_caps_at_wad() -> None:
    env = _simple_env()
    env.rm.base_rate = WAD
    assert env.rm.redemption_fee_rate(env.v.total_supply) == WAD


@settings(max_examples=200, deadline=None)
@given(
    amount=st.integers(1, 30_000 * WAD),
    max_it=st.integers(1, 6),
    price=st.integers(1_500 * WAD, 3_000 * WAD),
    dt=st.integers(0, 10**8),
)
def test_fuzz_redemption_leaves_healthy_positions(
    amount: int, max_it: int, price: int, dt: int
) -> None:
    """I5 in the model: every position redeemed from is closed or keeps ≥ MIN_DEBT and ICR ≥ MCR;
    the partial is the last visit; a reverted call changes nothing."""
    env = _simple_env(6)
    v = env.v
    v.stable["erin"] = v.stable.get("erin", 0) + sum(
        v.stable.get(w, 0) for w in ("alice", "bob", "carol", "dave", "frank")
    )
    v.now += dt
    env.price = price
    before = _snapshot(env)
    n0 = len(v.events)
    try:
        env.rm.redeem("erin", min(amount, v.stable["erin"]), max_it, WAD, 0, 0)
    except ProtocolError:
        assert _snapshot(env) == before
        return
    redeemed_events = [e for e in v.events[n0:] if e[0] == "PositionRedeemed"]
    assert sum(1 for e in redeemed_events if not e[5]) <= 1
    if any(not e[5] for e in redeemed_events):
        assert not redeemed_events[-1][5], "the partial is the last one"
    for e in redeemed_events:
        p = v.positions[e[1]]
        if p.status == vm.Status.CLOSED_BY_REDEMPTION:
            continue
        assert v.debt_of(e[1]) >= v.min_debt
        assert v.effective(e[1])[0] * price >= v.mcr * v.debt_of(e[1])
