"""Liquidation and redistribution in model/protocol/vault.py (P20) with the StabilityPool model as
the deployment-A strategy, against every vector of spec/vectors/liquidation_pool.json and
redistribution.json: each step's result and the full expected state. Plus CHG-012's defensive checks
and the rules of §6.4–6.5 the vectors do not pin. The contracts run the same vectors in
contracts/test/vectors/LiquidationVectors.t.sol."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from model.math import WAD
from model.protocol import deficit_ledger as dl
from model.protocol import stability_pool as sp
from model.protocol import vault as vm

FILES = {
    f: {v["name"]: v for v in json.loads(Path(f"spec/vectors/{f}.json").read_text())["vectors"]}
    for f in ("liquidation_pool", "redistribution")
}
SYSTEM = [(f, n) for f, vs in FILES.items() for n, v in vs.items() if v["level"] == "system"]
STATUS_NAMES = {
    "Active": vm.Status.ACTIVE,
    "ClosedByOwner": vm.Status.CLOSED_BY_OWNER,
    "ClosedByRedemption": vm.Status.CLOSED_BY_REDEMPTION,
    "ClosedByLiquidation": vm.Status.CLOSED_BY_LIQUIDATION,
    "ClosedByShutdown": vm.Status.CLOSED_BY_SHUTDOWN,
}
PATHS = {"NONE": vm.PATH_NONE, "REDISTRIBUTED": vm.PATH_REDISTRIBUTED, "DEFICIT": vm.PATH_DEFICIT}


class System:
    """Deployment A from a vector's inputs: the vault model, the pool model as strategy and hook."""

    def __init__(self, inputs: dict) -> None:
        p = {k: int(x) for k, x in inputs["params"].items()}
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
            has_pool=True,
            now=t0,
            last_accrual=t0,
        )
        self.pool = sp.StabilityPool(self.v, p["LIQUIDATION_PENALTY"], p["MIN_DEPOSIT"])
        self.v.pool_hook = self.pool.on_interest
        self.v.strategy = self.pool
        self.funds = int(inputs["actorWeth"])
        for a in inputs["actors"]:
            self.v.weth[a] = self.funds


def _step(sysm: System, step: dict) -> None:
    v, op = sysm.v, step["op"]
    assert int(step["t"]) == v.now
    if "price" in step:
        sysm.price = int(step["price"])
    if op == "open":
        pid = v.open_position(
            step["caller"],
            int(step["coll"]),
            int(step["debt"]),
            int(step["upperHint"]),
            int(step["lowerHint"]),
        )
        assert pid == int(step["result"]["id"])
    elif op == "deposit":
        sysm.pool.deposit(step["caller"], int(step["amount"]))
    elif op == "addCollateral":
        v.add_collateral(
            step["caller"],
            int(step["id"]),
            int(step["amount"]),
            int(step["upperHint"]),
            int(step["lowerHint"]),
        )
    elif op == "transfer":
        frm, to, amt = step["caller"], step["to"], int(step["amount"])
        assert v.stable.get(frm, 0) >= amt
        v.stable[frm] -= amt
        v.stable[to] = v.stable.get(to, 0) + amt
    elif op == "close":
        before = v.stable.get(step["caller"], 0)
        v.close(step["caller"], int(step["id"]))
        assert before - v.stable.get(step["caller"], 0) == int(step["result"]["debtBurned"])
    elif op == "liquidate":
        _liquidate(sysm, step)
    else:
        raise AssertionError(op)


def _liquidate(sysm: System, step: dict) -> None:
    v, pid = sysm.v, int(step["id"])
    _, eff_norm = v.effective(pid)
    n_events, p_events = len(v.events), len(sysm.pool.events)
    path = v.liquidate(step["caller"], pid)
    r = step["result"]
    (liq,) = [e for e in v.events[n_events:] if e[0] == "Liquidated"]
    _, _, _, _, debt, coll, absorbed, returned, norm_rest, epath, gas = liq
    assert (debt, coll, absorbed, returned, norm_rest) == (
        int(r["debt"]),
        int(r["coll"]),
        int(r["debtAbsorbed"]),
        int(r["collRemainder"]),
        int(r["normRemainder"]),
    )
    assert eff_norm - norm_rest == int(r["normAbsorbed"])
    assert epath == path == PATHS[r["remainderPath"]]
    assert gas == v.gas_reserve
    (pl,) = [e for e in sysm.pool.events[p_events:] if e[0] == "PoolLiquidation"]
    pr = r["pool"]
    assert pl[4:] == (
        int(pr["seized"]),
        int(pr["surplus"]),
        int(pr["debtOffset"]),
        int(pr["collToPool"]),
        int(pr["collReturned"]),
    )


def _holder(name: str) -> str:
    return "vault" if name == "vm" else name


@pytest.mark.parametrize(("file", "name"), SYSTEM, ids=[n for _, n in SYSTEM])
def test_system_vector(file: str, name: str) -> None:
    vec = FILES[file][name]
    sysm = System(vec["inputs"])
    for step in vec["steps"]:
        _step(sysm, step)
    v, pool, e = sysm.v, sysm.pool, vec["expected"]
    ev = e["vault"]
    assert (v.index, v.last_accrual, v.total_norm_debt, v.total_collateral, v.total_stakes) == (
        int(ev["index"]),
        int(ev["lastAccrual"]),
        int(ev["totalNormDebt"]),
        int(ev["totalCollateral"]),
        int(ev["totalStakes"]),
    )
    assert (v.total_stakes_snapshot, v.total_collateral_snapshot) == (
        int(ev["totalStakesSnapshot"]),
        int(ev["totalCollateralSnapshot"]),
    )
    assert (v.l_coll, v.l_debt, v.last_error_coll, v.last_error_debt) == (
        int(ev["LColl"]),
        int(ev["LDebt"]),
        int(ev["lastErrorColl"]),
        int(ev["lastErrorDebt"]),
    )
    assert (v.pending_coll, v.pending_norm_debt, v.active_count) == (
        int(ev["pendingColl"]),
        int(ev["pendingNormDebt"]),
        int(ev["activeCount"]),
    )
    assert v.sorted.order() == [int(x) for x in ev["sortedOrder"]]
    for sid, ep in e["positions"].items():
        pos = v.positions[int(sid)]
        assert pos.owner == ep["owner"]
        assert pos.status == STATUS_NAMES[ep["status"]]
        assert (pos.coll, pos.norm_debt, pos.stake, pos.snap_l_coll, pos.snap_l_debt) == (
            int(ep["coll"]),
            int(ep["normDebt"]),
            int(ep["stake"]),
            int(ep["snapLColl"]),
            int(ep["snapLDebt"]),
        )
        if "effColl" in ep:
            assert v.effective(int(sid)) == (int(ep["effColl"]), int(ep["effNorm"]))
            assert v.debt_of(int(sid)) == int(ep["debt"])
    el = e["ledger"]
    assert (v.ledger_reserve, v.ledger_deficit, v.ledger_recovered_coll) == (
        int(el["reserve"]),
        int(el["deficit"]),
        int(el["recoveredColl"]),
    )
    assert v.total_supply == int(e["token"]["totalSupply"])
    for who, want in e["token"]["balances"].items():
        assert v.stable.get(_holder(who), 0) == int(want), who
    for who, want in e["weth"].items():
        if who == "strategy":
            assert want == "0"  # the reference's pass-through account
        elif who in ("vm", "pool", "ledger"):
            assert v.weth.get(_holder(who), 0) == int(want), who
        else:
            assert v.weth.get(who, 0) - sysm.funds == int(want), who
    epool = e["pool"]
    assert (pool.total_deposits, pool.p, pool.current_scale, pool.current_epoch) == (
        int(epool["totalDeposits"]),
        int(epool["P"]),
        int(epool["currentScale"]),
        int(epool["currentEpoch"]),
    )
    assert (pool.last_coll_error, pool.coll_gains_balance) == (
        int(epool["lastCollError"]),
        int(epool["collGainsBalance"]),
    )
    sums = {f"{a}:{b}": str(x) for (a, b), x in pool.s.items() if x != 0}
    assert sums == epool["S"]
    for who, d in epool.get("deposits", {}).items():
        assert pool.compounded_deposit(who) == int(d["compounded"])
        assert pool.gains(who) == (int(d["collGain"]), int(d["interestGain"]))


def test_unit_vector_error_carry() -> None:
    vec = FILES["redistribution"]["error_carry"]
    v = vm.Vault(11 * 10**17, 2_000 * WAD, 1, 30, lambda: (2_000 * WAD, True))
    v.total_stakes = int(vec["inputs"]["totalStakes"])
    for step in vec["steps"]:
        v._redistribute(int(step["collR"]), int(step["normR"]))
        r = step["result"]
        assert (v.l_coll, v.l_debt, v.last_error_coll, v.last_error_debt) == (
            int(r["LColl"]),
            int(r["LDebt"]),
            int(r["lastErrorColl"]),
            int(r["lastErrorDebt"]),
        )


# ---- CHG-012: the strategy's answer is checked, and a violation rolls back everything ----


class _LyingStrategy:
    def __init__(self, vault: vm.Vault, extra_debt: int, extra_coll: int) -> None:
        self.vault, self.extra_debt, self.extra_coll = vault, extra_debt, extra_coll
        self.calls = 0

    def on_liquidation(self, pid, owner, debt, coll, price):  # noqa: ANN001, ANN201
        self.calls += 1
        self.vault._weth_move("pool", "vault", coll)
        return debt + self.extra_debt, coll + self.extra_coll


@pytest.mark.parametrize(
    ("extra_debt", "extra_coll", "error"),
    [(1, 0, vm.DebtAbsorbedExceedsDebt), (0, 1, vm.CollReturnedExceedsColl), (0, 0, None)],
)
def test_chg012_strategy_answer_bounds(extra_debt: int, extra_coll: int, error) -> None:  # noqa: ANN001
    price = [2_000 * WAD]
    v = vm.Vault(11 * 10**17, 2_000 * WAD, 375 * 10**14, 30, lambda: (price[0], True))
    for who in ("alice", "bob"):
        v.weth[who] = 10**24
    v.open_position("alice", 10 * WAD, 10_000 * WAD, 0, 0)
    v.open_position("bob", 2 * WAD, 3_000 * WAD, 1, 0)
    v.weth["vault"] += (
        extra_coll  # so the lying return is payable; the check, not WETH, must stop it
    )
    v.strategy = _LyingStrategy(v, extra_debt, extra_coll)
    price[0] = 1_500 * WAD
    before = (v.total_norm_debt, v.total_stakes, dict(v.weth), v.positions[2].status)
    if error is None:
        v.liquidate("liq", 2)
        return
    with pytest.raises(error):
        v.liquidate("liq", 2)
    assert (v.total_norm_debt, v.total_stakes, dict(v.weth), v.positions[2].status) == before


class _SilentStrategy:
    """Reports returning the whole collateral but sends nothing back (CHG-014)."""

    def on_liquidation(self, pid, owner, debt, coll, price):  # noqa: ANN001, ANN201
        return 0, coll


def test_chg014_collateral_not_received_reverts_and_rolls_back() -> None:
    price = [2_000 * WAD]
    v = vm.Vault(11 * 10**17, 2_000 * WAD, 375 * 10**14, 30, lambda: (price[0], True))
    for who in ("alice", "bob"):
        v.weth[who] = 10**24
    v.open_position("alice", 10 * WAD, 10_000 * WAD, 0, 0)
    v.open_position("bob", 2 * WAD, 3_000 * WAD, 1, 0)
    v.strategy = _SilentStrategy()
    price[0] = 1_500 * WAD
    before = (v.total_norm_debt, v.pending_coll, dict(v.weth), v.positions[2].status)
    with pytest.raises(vm.CollReturnedNotReceived):
        v.liquidate("liq", 2)
    assert (v.total_norm_debt, v.pending_coll, dict(v.weth), v.positions[2].status) == before


def test_no_stakes_deficit_lands_in_the_real_ledger_then_cover_and_settlement() -> None:
    """P21 (audit M3): the vault model's ledger is the DeficitLedger model. The no-stakes path
    books through its caller-checked `record_deficit`, `cover` burns from the system's supply,
    settlement hands the collateral on, and a settled ledger refuses the vault's next interest
    (§5.6) with the whole vault operation rolled back."""
    vec = FILES["liquidation_pool"]["no_stakes_deficit"]
    sysm = System(vec["inputs"])
    for step in vec["steps"]:
        _step(sysm, step)
    v = sysm.v
    led = v.ledger
    assert led.deficit > 0 and led.recovered_coll > 0
    assert ("DeficitRecorded", led.deficit, led.recovered_coll, 2) in led.events
    # one cross-contract order: the ledger's event sits in the vault's log before `Liquidated`
    names = [e[0] for e in v.events]
    assert names.index("DeficitRecorded") < len(names) - 1 - names[::-1].index("Liquidated")
    assert v.weth.get("ledger", 0) == led.recovered_coll  # I1's ledger row
    assert v.stable.get("ledger", 0) == led.reserve
    reserve, deficit, supply = led.reserve, led.deficit, v.total_supply
    c = led.cover()
    assert c == min(reserve, deficit)
    assert (led.reserve, led.deficit, v.total_supply) == (reserve - c, deficit - c, supply - c)
    # a fresh position, so interest accrues after settlement (the vector leaves none active)
    v.weth["carol"] = 10**24
    v.open_position("carol", 10 * WAD, 10_000 * WAD, 0, 0)
    assert v.active_count > 0
    coll = led.recovered_coll
    assert led.on_settlement("shutdown") == coll
    assert (v.weth.get("shutdown", 0), v.weth.get("ledger", 0), v.stable.get("ledger", 0)) == (
        coll,
        0,
        0,
    )
    with pytest.raises(vm.Unauthorized):
        led.record_deficit("alice", 1, 0)
    # a settled ledger refuses `onInterest`, so the vault's accrual reverts as a whole
    v.now += 365 * 86_400
    before = (v.index, v.last_accrual, v.total_supply, v.pool_interest)
    with pytest.raises(dl.SystemSettled):
        v.accrue()
    assert (v.index, v.last_accrual, v.total_supply, v.pool_interest) == before
