"""StabilityPool in model/protocol/stability_pool.py (P19) against spec/vectors/product_sum.json:
the two unit vectors step by step with the full pool state, and the system vector end to end with
the vault model. Plus the rules of §5.3 and §6.6 the vectors do not pin. The contracts run the same
vectors in contracts/test/vectors/ProductSum{Vectors,SystemVector}.t.sol."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from model.protocol import errors as er
from model.protocol import stability_pool as sp
from model.protocol import vault as vm
from model.protocol.math import WAD

VECTORS = {
    v["name"]: v for v in json.loads(Path("spec/vectors/product_sum.json").read_text())["vectors"]
}


def _unit_pool() -> sp.StabilityPool:
    return sp.StabilityPool(sp.Tokens(), liquidation_penalty=5 * 10**16, min_deposit=WAD)


def _sums(d: dict[tuple[int, int], int]) -> dict[str, str]:
    return {f"{e}:{s}": str(x) for (e, s), x in d.items() if x != 0}


def _check_after(pool: sp.StabilityPool, after: dict) -> None:
    assert pool.total_deposits == int(after["totalDeposits"])
    assert pool.p == int(after["P"])
    assert pool.current_scale == int(after["currentScale"])
    assert pool.current_epoch == int(after["currentEpoch"])
    assert _sums(pool.s) == after["S"]
    assert _sums(pool.g) == after["G"]
    assert pool.last_coll_error == int(after["lastCollError"])
    assert pool.last_interest_error == int(after["lastInterestError"])
    assert pool.coll_gains_balance == int(after["collGainsBalance"])
    assert pool.interest_gains_balance == int(after["interestGainsBalance"])
    for name, want in after["depositors"].items():
        assert pool.compounded_deposit(name) == int(want["compounded"]), name
        assert pool.gains(name) == (int(want["collGain"]), int(want["interestGain"])), name
    bank = pool.bank
    # I1 (pool holder)
    assert bank.stable.get("pool", 0) >= pool.total_deposits + pool.interest_gains_balance
    assert bank.weth.get("pool", 0) == pool.coll_gains_balance


def _depositor_step(pool: sp.StabilityPool, step: dict) -> None:
    caller, amount = step["caller"], int(step["amount"])
    r = step.get("result")
    if r is not None:
        assert pool.compounded_deposit(caller) == int(r["compoundedBefore"])
    bank = pool.bank
    stable0, reserve0 = bank.stable.get(caller, 0), bank.ledger_reserve
    n0 = len(pool.events)
    if step["op"] == "deposit":
        pool.deposit(caller, amount)
        swept = 0
    else:
        swept = pool.withdraw(caller, amount)
    assert bank.ledger_reserve - reserve0 == swept
    paid = [e for e in pool.events[n0:] if e[0] == "GainsPaid"]
    assert len(paid) == 1 and paid[0][1] == caller
    if r is None:
        return
    _, _, coll_paid, interest_paid = paid[0]
    assert coll_paid == int(r["collGainPaid"])
    assert interest_paid == int(r["interestGainPaid"])
    assert pool.deposits.get(caller, sp.Deposit()).initial == int(r["deposit"])
    if step["op"] == "deposit":
        assert stable0 + interest_paid - bank.stable[caller] == amount
    else:
        assert bank.stable[caller] - stable0 == int(r["withdrawn"]) + interest_paid
        assert swept == int(r["dustSwept"])


@pytest.mark.parametrize("name", ["sequence", "dust_sweep"])
def test_unit_vector(name: str) -> None:
    v = VECTORS[name]
    pool = _unit_pool()
    params = v["inputs"].get("params")
    if params:
        assert int(params["P_PRECISION"]) == sp.P_PRECISION
        assert int(params["SCALE_FACTOR"]) == sp.SCALE_FACTOR
        assert int(params["DECIMAL_PRECISION"]) == sp.DECIMAL_PRECISION
        assert int(params["MIN_DEPOSIT"]) == pool.min_deposit
    for actor, bal in v["inputs"]["stablecoinBalances"].items():
        pool.bank._mint(actor, int(bal))
    for step in v["steps"]:
        op = step["op"]
        if op == "hook.offset":
            pool.hook_offset(int(step["debt"]), int(step["coll"]))
        elif op == "hook.onInterest":
            assert pool.hook_on_interest(int(step["amount"]))
        else:
            _depositor_step(pool, step)
        if "after" in step:
            _check_after(pool, step["after"])
    exp = v["expected"]
    assert pool.bank.ledger_reserve == int(exp["reserve"])
    assert pool.bank.stable.get("ledger", 0) == pool.bank.ledger_reserve
    if "totalDeposits" in exp:
        assert pool.total_deposits == int(exp["totalDeposits"])
    for e, n in exp.get("depositorCount", {}).items():
        assert pool.depositor_count.get(int(e), 0) == int(n)


def test_system_vector_deposit_after_idle_gets_no_back_interest() -> None:
    v = VECTORS["deposit_after_idle_gets_no_back_interest"]
    inputs = v["inputs"]
    p = {k: int(x) for k, x in inputs["params"].items()}
    t0 = int(inputs["t0"])
    price = [2_000 * WAD]
    vault = vm.Vault(
        p["MCR"],
        p["MIN_DEBT"],
        p["GAS_RESERVE"],
        p["MAX_HINT_STEPS"],
        lambda: (price[0], True),
        rate_per_second=p["RATE_PER_SECOND"],
        pool_share_bps=p["POOL_SHARE_BPS"],
        has_pool=True,
        now=t0,
        last_accrual=t0,
    )
    pool = sp.StabilityPool(vault, p["LIQUIDATION_PENALTY"], p["MIN_DEPOSIT"])
    vault.pool_hook = pool.on_interest
    weth0 = int(inputs["actorWeth"])
    for a in inputs["actors"]:
        vault.weth[a] = weth0
    for step in v["steps"]:
        assert int(step["t"]) == vault.now
        op = step["op"]
        if op == "warp":
            vault.now += int(step["dt"])
        elif op == "open":
            price[0] = int(step["price"])
            pid = vault.open_position(
                step["caller"],
                int(step["coll"]),
                int(step["debt"]),
                int(step["upperHint"]),
                int(step["lowerHint"]),
            )
            assert pid == int(step["result"]["id"])
        elif op == "deposit":
            r = step["result"]
            assert pool.compounded_deposit(step["caller"]) == int(r["compoundedBefore"])
            pool.deposit(step["caller"], int(step["amount"]))
            assert pool.deposits[step["caller"]].initial == int(r["deposit"])
        else:
            raise AssertionError(op)
    exp = v["expected"]
    assert vault.index == int(exp["vault"]["index"])
    assert vault.last_accrual == int(exp["vault"]["lastAccrual"])
    assert vault.ledger_reserve == int(exp["ledger"]["reserve"])
    tok = exp["token"]
    assert vault.total_supply == int(tok["totalSupply"])
    for who, want in tok["balances"].items():
        assert vault.stable.get(who, 0) == int(want), who
    for who, want in exp["weth"].items():
        if who == "vm":
            assert vault.weth.get("vault", 0) == int(want)
        else:
            assert vault.weth[who] - weth0 == int(want), who
    ep = exp["pool"]
    assert pool.total_deposits == int(ep["totalDeposits"])
    assert pool.p == int(ep["P"])
    assert _sums(pool.s) == ep["S"]
    assert _sums(pool.g) == ep["G"]
    assert pool.last_interest_error == int(ep["lastInterestError"])
    assert pool.interest_gains_balance == int(ep["interestGainsBalance"])
    assert pool.depositor_count == {int(e): int(n) for e, n in ep["depositorCount"].items()}
    for name, d in ep["deposits"].items():
        rec = pool.deposits[name]
        assert (
            rec.initial,
            rec.snap_p,
            rec.snap_s,
            rec.snap_g,
            rec.snap_epoch,
            rec.snap_scale,
        ) == (
            int(d["initial"]),
            int(d["snapP"]),
            int(d["snapS"]),
            int(d["snapG"]),
            int(d["snapEpoch"]),
            int(d["snapScale"]),
        )
        assert pool.compounded_deposit(name) == int(d["compounded"])
        assert pool.gains(name) == (int(d["collGain"]), int(d["interestGain"]))


# ---- rules the vectors do not pin ----


def test_errors_and_atomicity() -> None:
    pool = _unit_pool()
    pool.bank._mint("alice", 10 * WAD)
    with pytest.raises(er.ZeroAmount):
        pool.deposit("alice", 0)
    with pytest.raises(er.DepositTooSmall):
        pool.deposit("alice", WAD - 1)
    with pytest.raises(er.InsufficientBalance):
        pool.deposit("alice", 11 * WAD)
    with pytest.raises(er.NoDeposit):
        pool.withdraw("alice", 1)
    with pytest.raises(er.NoDeposit):
        pool.claim_gains("alice")
    pool.deposit("alice", 5 * WAD)
    with pytest.raises(er.ZeroAmount):
        pool.withdraw("alice", 0)
    snapshot = (pool.total_deposits, dict(pool.bank.stable), pool.bank.accrue_calls)
    with pytest.raises(er.DepositTooSmall):
        pool.withdraw("alice", 4 * WAD + 1)
    assert (pool.total_deposits, dict(pool.bank.stable), pool.bank.accrue_calls) == snapshot


def test_on_interest_declines_below_minimum_without_state_change() -> None:
    pool = _unit_pool()
    assert pool.on_interest(5 * WAD) is False
    assert pool.interest_gains_balance == 0 and pool.g == {} and pool.last_interest_error == 0


def test_on_liquidation_branches() -> None:
    pool = _unit_pool()
    pool.bank._mint("alice", 10**30)
    pool.deposit("alice", 1_000 * WAD)
    price = 2_000 * WAD
    pool.bank.weth["pool"] = 3 * WAD
    absorbed, returned = pool.on_liquidation(1, "owner", 4_000 * WAD, 3 * WAD, price)
    assert (absorbed, returned) == (1_000 * WAD, 21 * 10**17 - 525 * 10**15)
    assert pool.bank.weth["owner"] == 9 * 10**17
    assert pool.bank.weth["vault"] == returned
    assert pool.current_epoch == 1
    # empty pool: everything seized goes back
    pool.bank.weth["pool"] += 15 * 10**17
    absorbed, returned = pool.on_liquidation(2, "owner", 2_000 * WAD, 15 * 10**17, price)
    assert (absorbed, returned) == (0, 105 * 10**16)


def test_many_near_emptying_offsets_keep_p_in_range_and_cross_scales() -> None:
    pool = _unit_pool()
    pool.bank._mint("a", 10**30)
    pool.bank._mint("b", 40 * 10**30)
    pool.deposit("a", 10**30)
    for _ in range(30):
        t = pool.total_deposits
        pool.hook_offset(t - 1, t // 1000)  # leave 1 wei
        assert sp.P_MIN <= pool.p <= sp.P_PRECISION
        assert pool.compounded_deposit("a") + pool.compounded_deposit("b") <= pool.total_deposits
        pool.deposit("b", 10**30)
    assert pool.current_scale > 5
    assert pool.compounded_deposit("a") == 0
