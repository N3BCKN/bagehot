"""`System`: deployment A wired whole, as `BagehotFactory` deploys it (P22; variant B is P34).

One object owns every contract model, the two tokens and the run's ordered event log:

- OracleAdapter (`oracle_adapter.py`) reading injected feeds (`Feeds`, the mock aggregators);
- VaultManager (`vault.py`) with its SortedPositions and DeficitLedger;
- StabilityPool (`stability_pool.py`) as strategy and interest hook;
- RedemptionModule (`redemption.py`) with the critical-TCR gate of the stand-in ShutdownModule;
- WETH and StableToken (`tokens.py`).

Every external entry point takes `now` (block.timestamp; it never goes back) and the caller, runs
as one transaction — on any exception every contract, token balance and event is as before — and
returns a `Receipt` with its value and the events it emitted, in order. `snapshot()` is the
canonical state: sorted keys, integers (booleans as 0/1, addresses as account names), zero balances
left out, as a chain read would show them.

Not modelled: wiring (the graph is built whole, so `NotWired` / `AlreadyWired` / `NotDeployer`
cannot arise — the differential test excludes those paths on purpose, P23), gas, allowances. The
ShutdownModule is the Solidity stand-in's behaviour: `belowCritical` for the redemption gate, and
`trigger_shutdown` / `settle` calling the hooks as the wired shutdown address does in the core
campaign (accrue, then `onShutdown`; `VaultManager.onSettlement`, then `DeficitLedger.onSettlement`,
P21-SEC L-2). The real module, its triggers and claims (I10) come with the ShutdownModule prompt.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass, field, fields

from model.protocol.events import Entry, Log
from model.protocol.oracle_adapter import FeedRound, OracleAdapter
from model.protocol.redemption import RedemptionModule, make_gate
from model.protocol.stability_pool import StabilityPool
from model.protocol.vault import Vault

SHUTDOWN = "shutdown"  # the wired ShutdownModule's account
CORE_ACCOUNTS = frozenset(("vault", "pool", "ledger", "redemption", "sorted", SHUTDOWN))


@dataclass(frozen=True, slots=True)
class Params:
    """§3.1 parameters of deployment A (defaults from the spec), plus the ShutdownModule's."""

    mcr: int = 11 * 10**17
    min_debt: int = 2_000 * 10**18
    gas_reserve: int = 375 * 10**14
    rate_per_second: int = 1_547_125_957_863_212_449
    pool_share_bps: int = 7_500
    pool_hook_gas: int = 200_000
    max_hint_steps: int = 30
    liquidation_penalty: int = 5 * 10**16
    min_deposit: int = 10**18
    redemption_fee_floor: int = 5 * 10**15
    beta: int = 2
    base_rate_decay: int = 999_983_955_055_097_432_543_272_791
    staleness: int = 3_600
    grace_period: int = 3_600
    min_price: int = 10 * 10**18
    max_price: int = 1_000_000 * 10**18
    oracle_gas: int = 100_000
    oracle_post_failure_gas: int = 3_175
    feed_decimals: int = 8
    oracle_failure_duration: int = 172_800
    critical_tcr: int = 105 * 10**16
    deficit_limit_bps: int = 500
    repayment_window: int = 604_800

    @classmethod
    def from_spec(cls, values: Mapping[str, object]) -> Params:
        """From spec names (`MCR`, `MIN_DEBT`, …), values as ints or decimal strings; names of
        deployment B (`BUFFER`, `CUT`, …) are ignored, missing names keep the default."""
        known = {f.name.upper(): f.name for f in fields(cls)}
        return cls(**{known[k]: int(v) for k, v in values.items() if k in known})  # type: ignore[arg-type]


@dataclass(slots=True)
class Feeds:
    """The two mock aggregators (`MockAggregator`, `MockSequencerFeed`). `None` is a failed call."""

    sequencer: FeedRound | None = FeedRound(0, 1, 1)  # up since t = 1
    price: FeedRound | None = None
    reads: int = 0  # calls to either feed: I9 / I12 ask whether an operation read the oracle

    def read_sequencer(self) -> FeedRound | None:
        self.reads += 1
        return self.sequencer

    def read_price(self) -> FeedRound | None:
        self.reads += 1
        return self.price


@dataclass(slots=True)
class Receipt:
    value: object
    events: list[Entry]


@dataclass(slots=True)
class Step:
    """The last operation, kept when `record=True` for the per-operation invariants."""

    op: str
    caller: str
    args: tuple
    now: int
    price: int  # the price the oracle would answer at `now` (its peek), usable or not
    usable: bool
    pre: dict
    post: dict
    events: list[Entry] = field(default_factory=list)
    error: Exception | None = None
    oracle_reads: int = 0


class System:
    def __init__(self, params: Params | None = None, *, t0: int = 1_000_000, record: bool = False):
        p = self.params = params or Params()
        self.record = record
        self.now = t0
        self.log = Log(now=t0)
        # tokens sent to a core contract by plain ERC-20 transfers (I1's D_w, D_t), and the WETH the
        # stand-in shutdown address received at settlement (I1's claimColl; no claims yet)
        self.donated: dict[str, dict[str, int]] = {"weth": {}, "token": {}}
        self.claim_coll = 0
        self.feeds = Feeds()
        self.oracle = OracleAdapter.deploy(
            price_feed=1,
            sequencer_feed=2,
            staleness=p.staleness,
            grace_period=p.grace_period,
            min_price=p.min_price,
            max_price=p.max_price,
            oracle_gas=p.oracle_gas,
            oracle_post_failure_gas=p.oracle_post_failure_gas,
            feed_decimals=p.feed_decimals,
        )
        self.oracle.log = self.log
        self.vault = Vault(
            p.mcr,
            p.min_debt,
            p.gas_reserve,
            p.max_hint_steps,
            self._fetch_price,
            shutdown_module=SHUTDOWN,
            rate_per_second=p.rate_per_second,
            pool_share_bps=p.pool_share_bps,
            pool_hook_gas=p.pool_hook_gas,
            has_pool=True,
            now=t0,
            last_accrual=t0,
            log=self.log,
        )
        self.pool = StabilityPool(self.vault, p.liquidation_penalty, p.min_deposit)
        self.vault.pool_hook = self.pool.on_interest
        self.vault.strategy = self.pool
        self.redemption = RedemptionModule(
            self.vault,
            p.redemption_fee_floor,
            p.beta,
            p.base_rate_decay,
            make_gate(self.vault, p.critical_tcr),
        )
        self.last: Step | None = None
        self.ghost = None
        if record:
            from model.invariants import Ghost  # noqa: PLC0415 — the checks import this module

            self.ghost = Ghost(self)

    # ---- shortcuts ----
    @property
    def ledger(self):  # noqa: ANN201 — DeficitLedger
        return self.vault.ledger

    @property
    def sorted(self):  # noqa: ANN201 — SortedList
        return self.vault.sorted

    @property
    def weth(self):  # noqa: ANN201 — Token
        return self.vault.weth_token

    @property
    def token(self):  # noqa: ANN201 — Token
        return self.vault.stable_token

    # ---- the environment (no protocol state) ----
    def set_price(self, price: int, now: int) -> None:
        """`feed.setRound(1, price / 10^(18 − decimals), now)`, as the Foundry harness does
        (integer division: a price finer than the feed's precision is truncated)."""
        answer = price // 10 ** (18 - self.params.feed_decimals)
        self.feeds.price = FeedRound(answer, now, now)

    def set_feed(self, round_: FeedRound | None) -> None:
        self.feeds.price = round_

    def set_sequencer(self, round_: FeedRound | None) -> None:
        self.feeds.sequencer = round_

    def peek_price(self) -> tuple[int, bool]:
        price, usable, _ = self.oracle.peek(
            self.now, self.feeds.read_sequencer, self.feeds.read_price
        )
        return price, usable

    def _fetch_price(self) -> tuple[int, bool]:
        return self.oracle.fetch_price(self.now, self.feeds.read_sequencer, self.feeds.read_price)

    # ---- the transaction ----
    def _tx(self, op: str, caller: str, args: tuple, now: int, fn: Callable[[], object]) -> Receipt:
        if now < self.now:
            raise ValueError(f"time goes back: {now} < {self.now}")
        self.now = self.vault.now = self.log.now = now
        if self.record:
            self.ghost.observe(self)  # setup entries (mints) since the last operation
            pre = self.snapshot()
            price, usable = self.peek_price()
        mark, reads = self.log.mark(), self.feeds.reads
        o, r = self.oracle, self.redemption
        saved = (o.last_good_price, o.failure_start, r.base_rate, r.last_fee_operation_time)
        try:
            value = fn()
        except Exception as e:
            o.last_good_price, o.failure_start, r.base_rate, r.last_fee_operation_time = saved
            self.log.truncate(mark)
            if self.record:
                self.last = Step(
                    op, caller, args, now, price, usable, pre, pre, [], e, self.feeds.reads - reads
                )
            raise
        events = self.log.since(mark)
        if self.record:
            self.ghost.observe(self)
            self.last = Step(
                op,
                caller,
                args,
                now,
                price,
                usable,
                pre,
                self.snapshot(),
                events,
                None,
                self.feeds.reads - reads,
            )
        return Receipt(value, events)

    # ---- invariants ----
    def check_invariants(self, *, with_unwind: bool = False) -> list[str]:
        """Every invariant of docs/invariants.md that applies to deployment A and this phase
        (`model.invariants`); the violated clauses, empty when all hold. Needs `record=True`."""
        from model.invariants import check_invariants  # noqa: PLC0415

        if self.ghost is not None:
            self.ghost.observe(self)
        return check_invariants(self, with_unwind=with_unwind)

    def copy(self) -> System:
        """An independent deep copy (I8's unwind runs on one). The redemption gate is a closure
        over the vault, so it is rebuilt against the copy's vault."""
        import copy as _copy  # noqa: PLC0415

        other = _copy.deepcopy(self)
        other.redemption.below_critical = make_gate(other.vault, other.params.critical_tcr)
        return other

    # ---- setup and ERC-20 (not protocol operations) ----
    def fund(self, actor: str, amount: int) -> None:
        """`LocalWETH.mint(actor, amount)`: emits `Transfer(0x0, actor, amount)`."""
        self.weth.mint(actor, amount)

    def transfer(self, caller: str, to: str, amount: int, *, now: int) -> Receipt:
        """`StableToken.transfer(to, amount)`; to a core contract it is a donation (I1)."""
        return self._tx(
            "transfer", caller, (to, amount), now, lambda: self._erc20("token", caller, to, amount)
        )

    def transfer_weth(self, caller: str, to: str, amount: int, *, now: int) -> Receipt:
        return self._tx(
            "transferWeth",
            caller,
            (to, amount),
            now,
            lambda: self._erc20("weth", caller, to, amount),
        )

    def _erc20(self, token: str, caller: str, to: str, amount: int) -> None:
        (self.weth if token == "weth" else self.token).transfer(caller, to, amount)
        if to in CORE_ACCOUNTS:
            d = self.donated[token]
            d[to] = d.get(to, 0) + amount

    # ---- VaultManager (§5.1) ----
    def open_position(
        self, caller: str, coll: int, debt: int, upper: int = 0, lower: int = 0, *, now: int
    ) -> Receipt:
        v = self.vault
        return self._tx(
            "open",
            caller,
            (coll, debt, upper, lower),
            now,
            lambda: v.open_position(caller, coll, debt, upper, lower),
        )

    def add_collateral(
        self, caller: str, pid: int, amount: int, upper: int = 0, lower: int = 0, *, now: int
    ) -> Receipt:
        v = self.vault
        return self._tx(
            "addCollateral",
            caller,
            (pid, amount, upper, lower),
            now,
            lambda: v.add_collateral(caller, pid, amount, upper, lower),
        )

    def withdraw_collateral(
        self, caller: str, pid: int, amount: int, upper: int = 0, lower: int = 0, *, now: int
    ) -> Receipt:
        v = self.vault
        return self._tx(
            "withdrawCollateral",
            caller,
            (pid, amount, upper, lower),
            now,
            lambda: v.withdraw_collateral(caller, pid, amount, upper, lower),
        )

    def borrow(
        self, caller: str, pid: int, amount: int, upper: int = 0, lower: int = 0, *, now: int
    ) -> Receipt:
        v = self.vault
        return self._tx(
            "borrow",
            caller,
            (pid, amount, upper, lower),
            now,
            lambda: v.borrow(caller, pid, amount, upper, lower),
        )

    def repay(
        self, caller: str, pid: int, amount: int, upper: int = 0, lower: int = 0, *, now: int
    ) -> Receipt:
        v = self.vault
        return self._tx(
            "repay",
            caller,
            (pid, amount, upper, lower),
            now,
            lambda: v.repay(caller, pid, amount, upper, lower),
        )

    def close(self, caller: str, pid: int, *, now: int) -> Receipt:
        return self._tx("close", caller, (pid,), now, lambda: self.vault.close(caller, pid))

    def liquidate(self, caller: str, pid: int, *, now: int) -> Receipt:
        return self._tx("liquidate", caller, (pid,), now, lambda: self.vault.liquidate(caller, pid))

    def accrue(self, caller: str, *, now: int) -> Receipt:
        return self._tx("accrue", caller, (), now, self.vault.accrue)

    def reclaim_gas_reserve(self, caller: str, pid: int, *, now: int) -> Receipt:
        return self._tx(
            "reclaimGasReserve",
            caller,
            (pid,),
            now,
            lambda: self.vault.reclaim_gas_reserve(caller, pid),
        )

    # ---- RedemptionModule (§5.5) ----
    def redeem(
        self,
        caller: str,
        amount: int,
        max_iterations: int,
        max_fee_rate: int,
        upper: int = 0,
        lower: int = 0,
        *,
        now: int,
    ) -> Receipt:
        r = self.redemption
        return self._tx(
            "redeem",
            caller,
            (amount, max_iterations, max_fee_rate, upper, lower),
            now,
            lambda: r.redeem(caller, amount, max_iterations, max_fee_rate, upper, lower),
        )

    # ---- StabilityPool (§5.3) ----
    def deposit(self, caller: str, amount: int, *, now: int) -> Receipt:
        return self._tx(
            "deposit", caller, (amount,), now, lambda: self.pool.deposit(caller, amount)
        )

    def withdraw(self, caller: str, amount: int, *, now: int) -> Receipt:
        return self._tx(
            "withdraw", caller, (amount,), now, lambda: self.pool.withdraw(caller, amount)
        )

    def claim_gains(self, caller: str, *, now: int) -> Receipt:
        return self._tx("claimGains", caller, (), now, lambda: self.pool.claim_gains(caller))

    # ---- DeficitLedger (§5.6) ----
    def cover(self, caller: str, *, now: int) -> Receipt:
        return self._tx("cover", caller, (), now, self.ledger.cover)

    # ---- the stand-in ShutdownModule's hook calls ----
    def trigger_shutdown(self, *, now: int) -> Receipt:
        """Accrue, then `onShutdown` (§5.1.1: the module accrues immediately before)."""

        def run() -> None:
            self.vault.accrue()
            self.vault.on_shutdown(SHUTDOWN)

        return self._tx("triggerShutdown", SHUTDOWN, (), now, lambda: self.vault._atomic(run))

    def settle(self, *, now: int) -> Receipt:
        """`VaultManager.onSettlement`, then `DeficitLedger.onSettlement` (P21-SEC L-2)."""

        def run() -> int:
            coll = self.vault.on_settlement(SHUTDOWN)
            return coll + self.ledger.on_settlement(SHUTDOWN)

        receipt = self._tx("settle", SHUTDOWN, (), now, lambda: self.vault._atomic(run))
        self.claim_coll = receipt.value  # the claim pool's WETH (§6.11.3), fixed from now on
        return receipt

    # ---- canonical state ----
    def snapshot(self) -> dict:
        v, pool, led, srt, o, r = (
            self.vault,
            self.pool,
            self.ledger,
            self.sorted,
            self.oracle,
            self.redemption,
        )
        return _canon(
            {
                "now": self.now,
                "vault": {
                    "index": v.index,
                    "lastAccrual": v.last_accrual,
                    "nextId": v.next_id,
                    "activeCount": v.active_count,
                    "totalNormDebt": v.total_norm_debt,
                    "totalCollateral": v.total_collateral,
                    "totalStakes": v.total_stakes,
                    "totalStakesSnapshot": v.total_stakes_snapshot,
                    "totalCollateralSnapshot": v.total_collateral_snapshot,
                    "LColl": v.l_coll,
                    "LDebt": v.l_debt,
                    "lastErrorColl": v.last_error_coll,
                    "lastErrorDebt": v.last_error_debt,
                    "pendingColl": v.pending_coll,
                    "pendingNormDebt": v.pending_norm_debt,
                    "shutdown": v.shutdown,
                    "settled": v.settled,
                    "positions": {
                        pid: {
                            "owner": q.owner,
                            "coll": q.coll,
                            "normDebt": q.norm_debt,
                            "stake": q.stake,
                            "snapLColl": q.snap_l_coll,
                            "snapLDebt": q.snap_l_debt,
                            "status": int(q.status),
                        }
                        for pid, q in v.positions.items()
                    },
                },
                "sorted": {
                    "head": srt.head,
                    "tail": srt.tail,
                    "size": srt.size,
                    "nodes": {i: {"prev": n[0], "next": n[1]} for i, n in srt.nodes.items()},
                },
                "pool": {
                    "totalDeposits": pool.total_deposits,
                    "P": pool.p,
                    "currentScale": pool.current_scale,
                    "currentEpoch": pool.current_epoch,
                    "epochToScaleToS": _nested(pool.s),
                    "epochToScaleToG": _nested(pool.g),
                    "lastCollError": pool.last_coll_error,
                    "lastInterestError": pool.last_interest_error,
                    "collGainsBalance": pool.coll_gains_balance,
                    "interestGainsBalance": pool.interest_gains_balance,
                    "deposits": {
                        a: {
                            "initial": d.initial,
                            "snapP": d.snap_p,
                            "snapS": d.snap_s,
                            "snapG": d.snap_g,
                            "snapEpoch": d.snap_epoch,
                            "snapScale": d.snap_scale,
                        }
                        for a, d in pool.deposits.items()
                        if d.initial > 0
                    },
                    "depositorCount": {e: c for e, c in pool.depositor_count.items() if c},
                },
                "redemption": {
                    "baseRate": r.base_rate,
                    "lastFeeOperationTime": r.last_fee_operation_time,
                },
                "ledger": {
                    "reserve": led.reserve,
                    "auctionDebt": led.auction_debt,
                    "deficit": led.deficit,
                    "recoveredColl": led.recovered_coll,
                    "settled": led.settled,
                },
                "oracle": {"lastGoodPrice": o.last_good_price, "failureStart": o.failure_start},
                "weth": _token(self.weth),
                "token": _token(self.token),
            }
        )


def _token(t) -> dict:  # noqa: ANN001 — Token
    return {
        "totalSupply": t.total_supply,
        "balances": {a: b for a, b in t.balances.items() if b},
    }


def _nested(acc: dict[tuple[int, int], int]) -> dict[int, dict[int, int]]:
    out: dict[int, dict[int, int]] = {}
    for (e, s), x in acc.items():
        if x:
            out.setdefault(e, {})[s] = x
    return out


def _canon(x: object) -> object:
    """Sorted keys all the way down; booleans as 0/1."""
    if isinstance(x, dict):
        return {k: _canon(x[k]) for k in sorted(x)}
    if isinstance(x, bool):
        return int(x)
    return x
