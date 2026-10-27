"""VaultManager parts I–III (P14–P16), bit-for-bit with `contracts/src/core/VaultManager.sol`.

Spec §4.2, §5.1.1–5.1.12, §6.2, §6.5.3–6.5.4, §6.7.3. Integers only. Covers positions, interest
accrual and its routing (P15), the redemption loop (P16), liquidation and redistribution (P20), the
shutdown hooks and the views. Time is `now`, set by the caller (block.timestamp). The ledger is the
real DeficitLedger model (`self.ledger`, P21) banked in this vault; `ledger_reserve`, … are its
views. The pool's `onInterest` is a callable `pool_hook` (ADR-0033: returns whether it booked;
raising stands for a failed guarded call) recorded in `pool_interest`, the strategy an object
(`strategy`), and the auction house's lot a plain field (`house_total_lot`). The P22 model extends
this module rather than replacing it.

Each operation is atomic like a transaction: on any exception the state is restored, so a failed
call leaves nothing behind. Exceptions carry the spec's error names (§11.2); a failed WETH transfer
is `WethTransferFailed` (§2.5). The price comes from a callable returning `(price, usable)`, called
only where the spec fetches a price — so a test can assert that the rescue paths never read it (I9).
"""

from __future__ import annotations

import copy
from collections.abc import Callable
from dataclasses import dataclass, field, fields
from enum import IntEnum

from model.protocol import redistribution as rd
from model.protocol.errors import (
    AlreadySettled,
    CollateralTooLarge,
    CollReturnedExceedsColl,
    CollReturnedNotReceived,
    DebtAbsorbedExceedsDebt,
    DebtBelowMinimum,
    IcrBelowMcr,
    InsufficientBalance,
    InsufficientCollateral,
    InvalidParameter,
    NotLiquidatable,
    NotOwner,
    NotSettled,
    NotTriggered,
    PositionNotActive,
    PriceUnusable,
    RepayExceedsMaximum,
    SystemSettled,
    SystemShutdown,
    Unauthorized,
    ZeroAmount,
)
from model.protocol.events import Log
from model.protocol.math import RAY, WAD, mul_div_down, mul_div_up, rpow
from model.protocol.math import checked as _c
from model.protocol.sorted_list import SortedList
from model.protocol.tokens import Token, stable_token, weth_token

BPS = 10_000
COLL_CAP = 2**128 - 1
SUPPLY_CAP = 2**128 - 1
DECIMAL_PRECISION = 10**18
NICR_PRECISION = 10**20
OP_OPEN, OP_ADD_COLLATERAL, OP_WITHDRAW_COLLATERAL, OP_BORROW, OP_REPAY, OP_CLOSE = 1, 2, 3, 4, 5, 6
MAX_MCR = 2 * WAD
MIN_MIN_DEBT = 10**18
MAX_RATE_PER_SECOND = 21_979_553_151_239_153_028
MIN_POOL_HOOK_GAS = 175_000  # CHG-013
MAX_POOL_HOOK_GAS = 1_000_000
OP_REDEEM = 7
OP_LIQUIDATE = 8
PATH_NONE, PATH_REDISTRIBUTED, PATH_DEFICIT = 0, 1, 2
# fields `_atomic` saves through their own `_save`, or never (callables, the shared log)
_NOT_COPIED = frozenset(
    (
        "price_source",
        "sorted",
        "pool_hook",
        "strategy",
        "ledger",
        "log",
        "weth_token",
        "stable_token",
    )
)


class Status(IntEnum):
    NONE = 0
    ACTIVE = 1
    CLOSED_BY_OWNER = 2
    CLOSED_BY_REDEMPTION = 3
    CLOSED_BY_LIQUIDATION = 4
    CLOSED_BY_SHUTDOWN = 5


@dataclass
class Position:
    owner: str
    coll: int
    norm_debt: int
    stake: int
    snap_l_coll: int
    snap_l_debt: int
    status: Status


@dataclass
class Vault:
    mcr: int
    min_debt: int
    gas_reserve: int
    max_hint_steps: int
    price_source: Callable[[], tuple[int, bool]]
    shutdown_module: str = "shutdown"
    redemption_module: str = "redemption"
    rate_per_second: int = 0
    pool_share_bps: int = 0
    has_pool: bool = True  # deployment A; B has no stability pool
    # §3.1 / ADR-0033: range-checked immutable; the model has no gas, so it is never used
    pool_hook_gas: int = 200_000
    # §6.2 / ADR-0033: the pool's `onInterest(offered) -> booked`. None is a pool that always
    # declines (no deposits). An exception stands for a failed guarded call (revert, out of gas,
    # malformed return); gas is not modelled, so `InsufficientGasForPoolHook` never arises here.
    pool_hook: Callable[[int], bool] | None = None
    # §6.4.1: the liquidation strategy, an object with `on_liquidation(id, owner, debt, coll,
    # price) -> (debt_absorbed, coll_returned)` moving WETH in this vault's `weth` balances at the
    # account `strategy_account` (A: the StabilityPool model, "pool"). Rolled back with the vault.
    strategy: object | None = None
    strategy_account: str = "pool"
    now: int = 0
    last_accrual: int = 0
    pool_interest: int = 0
    house_total_lot: int = 0
    positions: dict[int, Position] = field(default_factory=dict)
    next_id: int = 1
    active_count: int = 0
    index: int = RAY
    total_norm_debt: int = 0
    total_collateral: int = 0
    total_stakes: int = 0
    total_stakes_snapshot: int = 0
    total_collateral_snapshot: int = 0
    l_coll: int = 0
    l_debt: int = 0
    pending_coll: int = 0
    pending_norm_debt: int = 0
    last_error_coll: int = 0  # §6.5.2 carries (R9)
    last_error_debt: int = 0
    shutdown: bool = False
    settled: bool = False
    # the run's ordered event log (`events.py`), shared with the list, the ledger, the tokens and,
    # through the bank, the pool and the redemption module
    log: Log = field(default_factory=Log)
    # WETH and StableToken (`tokens.py`): per-holder balances; "vault" is the VaultManager
    weth_token: Token = field(init=False)
    stable_token: Token = field(init=False)
    sorted: SortedList = field(init=False)
    # §4.7 (P21): the real DeficitLedger model, banked here (account "ledger"); saved and restored
    # with the vault by `_atomic`, never deep-copied with it (its `bank` is this vault)
    ledger: object = field(init=False)

    def __post_init__(self) -> None:
        # §3.4 constructor, in argument order (0–2 are addresses the model does not carry)
        if not WAD < self.mcr <= MAX_MCR:
            raise InvalidParameter(3)
        if self.min_debt < MIN_MIN_DEBT:
            raise InvalidParameter(4)
        if self.gas_reserve == 0:
            raise InvalidParameter(5)
        if self.rate_per_second > MAX_RATE_PER_SECOND:
            raise InvalidParameter(6)
        if self.pool_share_bps > BPS:
            raise InvalidParameter(7)
        if not MIN_POOL_HOOK_GAS <= self.pool_hook_gas <= MAX_POOL_HOOK_GAS:
            raise InvalidParameter(8)
        # §3.4 wire, argument 2: no stability pool ⇒ POOL_SHARE_BPS == 0
        if not self.has_pool and self.pool_share_bps != 0:
            raise InvalidParameter(2)
        from model.protocol.deficit import (
            DeficitLedger,  # noqa: PLC0415 (it imports this module)
        )

        self.weth_token = weth_token(self.log)
        self.stable_token = stable_token(self.log)
        self.sorted = SortedList(self.max_hint_steps, self.sort_key, log=self.log)
        self.ledger = DeficitLedger(bank=self, variant_b=not self.has_pool)

    # ---- the ledger's views, as the VaultManager reads them (§5.1.12) ----
    @property
    def ledger_reserve(self) -> int:
        return self.ledger.reserve

    @property
    def ledger_deficit(self) -> int:
        return self.ledger.deficit

    @property
    def ledger_recovered_coll(self) -> int:
        return self.ledger.recovered_coll

    @property
    def ledger_auction_debt(self) -> int:
        return self.ledger.auction_debt

    # ---- events and balances, as views ----
    def _emit(self, event: tuple) -> None:
        self.log.emit("vault", event)

    @property
    def events(self) -> list[tuple]:
        return self.log.of("vault")

    @property
    def weth(self) -> dict[str, int]:
        return self.weth_token.balances

    @property
    def stable(self) -> dict[str, int]:
        return self.stable_token.balances

    @property
    def total_supply(self) -> int:
        return self.stable_token.total_supply

    # ---- transaction wrapper ----
    def _atomic(self, fn: Callable[[], object]) -> object:
        # exactly the declared state fields — not the price source, the components saved below or
        # any attribute a caller attached
        saved = {
            f.name: copy.deepcopy(getattr(self, f.name))
            for f in fields(self)
            if f.name not in _NOT_COPIED
        }
        mark = self.log.mark()
        tokens = self.weth_token._save(), self.stable_token._save()
        ledger_saved = self.ledger._save()
        sorted_saved = self.sorted._save()
        strategy_saved = self.strategy._save() if hasattr(self.strategy, "_save") else None
        try:
            return fn()
        except Exception:
            if strategy_saved is not None:
                self.strategy._restore(strategy_saved)
            self.__dict__.update(saved)
            self.ledger._restore(ledger_saved)
            self.sorted._restore(sorted_saved)
            self.weth_token._restore(tokens[0])
            self.stable_token._restore(tokens[1])
            self.log.truncate(mark)
            raise

    # ---- token helpers (WETH via SafeERC20, StableToken) ----
    def _weth_move(self, frm: str, to: str, amount: int) -> None:
        self.weth_token.transfer(frm, to, amount)

    def _mint(self, to: str, amount: int) -> None:
        self.stable_token.mint(to, amount)

    def _burn(self, frm: str, amount: int) -> None:
        self.stable_token.burn(frm, amount)

    def _stable_move(self, frm: str, to: str, amount: int) -> None:
        self.stable_token.transfer(frm, to, amount)

    # ---- internals ----
    def _fetch_required_price(self) -> int:
        price, usable = self.price_source()
        if not usable:
            raise PriceUnusable()
        return price

    def _accrue(self) -> None:
        """§6.2: index R4 (up), interest R6 (up), pool share R7 (down); the index grows even with
        no debt; frozen after shutdown; state written before the mints."""
        if self.shutdown:
            return
        dt = self.now - self.last_accrual
        if dt == 0:
            return
        old = self.index
        new = mul_div_up(old, rpow(RAY + self.rate_per_second, dt), RAY)
        interest = mul_div_up(self.total_norm_debt, new - old, RAY)
        self.index, self.last_accrual = new, self.now
        to_pool = 0
        if self.has_pool:
            offered = mul_div_down(interest, self.pool_share_bps, BPS)
            if offered > 0:
                try:
                    answer = self.pool_hook(offered) if self.pool_hook else False
                    # the contract decodes only a word of 0 or 1; anything else is a failed call
                    ok, booked = isinstance(answer, bool), answer is True
                except Exception:  # a failed guarded call: the pool's state is rolled back
                    ok, booked = False, False
                if ok and booked:
                    to_pool = offered
                elif not ok:
                    self._emit(("PoolInterestRedirected", offered))
        to_reserve = interest - to_pool
        if to_pool > 0:  # after the pool booked it
            self._mint("pool", to_pool)
            self.pool_interest += to_pool
        if to_reserve > 0:
            self._mint("ledger", to_reserve)
            self.ledger.on_interest("vault", to_reserve)
        self._emit(("InterestAccrued", new, interest, to_pool, to_reserve, self.now))

    # ---- the pool's view of the ledger (§5.3.1 `leave`, §5.6): the pool is the caller ----
    def on_pool_dust(self, amount: int) -> None:
        self.ledger.on_pool_dust("pool", amount)

    def is_ledger_settled(self) -> bool:
        return self.ledger.settled

    def accrue(self) -> None:
        """§5.1.8: anyone; any mode (no-op once shut down)."""
        self._atomic(self._accrue)

    def _debt_of(self, n: int) -> int:
        return mul_div_up(n, self.index, RAY)

    # ---- redistribution internals (§6.5), in `redistribution.py` ----
    def _pending(self, p: Position) -> tuple[int, int]:
        return rd.pending(self, p)

    def _apply_pending(self, pid: int) -> None:
        rd.apply_pending(self, pid)

    def _compute_stake(self, coll: int) -> int:
        return rd.compute_stake(self, coll)

    def _update_stake(self, pid: int) -> None:
        rd.update_stake(self, pid)

    def _active(self, pid: int) -> Position:
        p = self.positions.get(pid)
        if p is None or p.status != Status.ACTIVE:
            raise PositionNotActive()
        return p

    def _updated(self, pid: int, op: int) -> None:
        p = self.positions[pid]
        self._emit(
            (
                "PositionUpdated",
                pid,
                p.coll,
                p.norm_debt,
                p.stake,
                p.snap_l_coll,
                p.snap_l_debt,
                int(p.status),
                op,
            )
        )

    # ---- §5.1.1–5.1.6 ----
    def open_position(self, caller: str, coll: int, debt: int, upper: int, lower: int) -> int:
        def run() -> int:
            if self.shutdown:
                raise SystemShutdown()
            if debt < self.min_debt:
                raise DebtBelowMinimum()
            if coll > COLL_CAP:
                raise CollateralTooLarge()
            price = self._fetch_required_price()
            self._accrue()
            n = mul_div_up(debt, RAY, self.index)
            if _c(coll * price) < _c(self.mcr * self._debt_of(n)):
                raise IcrBelowMcr()
            pid = self.next_id
            self.next_id += 1
            stake = self._compute_stake(coll)
            self.positions[pid] = Position(
                caller, coll, n, stake, self.l_coll, self.l_debt, Status.ACTIVE
            )
            self.total_stakes = _c(self.total_stakes + stake)
            self.total_collateral = _c(self.total_collateral + coll)
            self.total_norm_debt = _c(self.total_norm_debt + n)
            self.active_count += 1
            self.sorted.insert(pid, upper, lower)
            self._weth_move(caller, "vault", _c(coll + self.gas_reserve))
            self._mint(caller, debt)
            self._emit(("PositionOpened", pid, caller, debt))
            self._updated(pid, OP_OPEN)
            return pid

        return self._atomic(run)

    def add_collateral(self, caller: str, pid: int, amount: int, upper: int, lower: int) -> None:
        def run() -> None:
            if self.settled:
                raise SystemSettled()
            if amount == 0:
                raise ZeroAmount()
            p = self._active(pid)
            self._accrue()
            self._apply_pending(pid)
            if _c(p.coll + amount) > COLL_CAP:
                raise CollateralTooLarge()
            p.coll += amount
            self.total_collateral = _c(self.total_collateral + amount)
            self._update_stake(pid)
            self.sorted.reinsert(pid, upper, lower)
            self._weth_move(caller, "vault", amount)
            self._emit(("CollateralAdded", pid, caller, amount))
            self._updated(pid, OP_ADD_COLLATERAL)

        self._atomic(run)

    def withdraw_collateral(
        self, caller: str, pid: int, amount: int, upper: int, lower: int
    ) -> None:
        def run() -> None:
            if self.shutdown:
                raise SystemShutdown()
            if amount == 0:
                raise ZeroAmount()
            p = self._active(pid)
            if caller != p.owner:
                raise NotOwner()
            price = self._fetch_required_price()
            self._accrue()
            self._apply_pending(pid)
            if amount > p.coll:
                raise InsufficientCollateral()
            if _c((p.coll - amount) * price) < _c(self.mcr * self._debt_of(p.norm_debt)):
                raise IcrBelowMcr()
            p.coll -= amount
            self.total_collateral -= amount
            self._update_stake(pid)
            self.sorted.reinsert(pid, upper, lower)
            self._weth_move("vault", p.owner, amount)
            self._emit(("CollateralWithdrawn", pid, amount))
            self._updated(pid, OP_WITHDRAW_COLLATERAL)

        self._atomic(run)

    def borrow(self, caller: str, pid: int, amount: int, upper: int, lower: int) -> None:
        def run() -> None:
            if self.shutdown:
                raise SystemShutdown()
            if amount == 0:
                raise ZeroAmount()
            p = self._active(pid)
            if caller != p.owner:
                raise NotOwner()
            price = self._fetch_required_price()
            self._accrue()
            self._apply_pending(pid)
            dn = mul_div_up(amount, RAY, self.index)
            if _c(p.coll * price) < _c(self.mcr * self._debt_of(_c(p.norm_debt + dn))):
                raise IcrBelowMcr()
            p.norm_debt += dn
            self.total_norm_debt = _c(self.total_norm_debt + dn)
            self._update_stake(pid)
            self.sorted.reinsert(pid, upper, lower)
            self._mint(p.owner, amount)
            self._emit(("Borrowed", pid, amount, dn))
            self._updated(pid, OP_BORROW)

        self._atomic(run)

    def repay(self, caller: str, pid: int, amount: int, upper: int, lower: int) -> None:
        def run() -> None:
            if self.settled:
                raise SystemSettled()
            if amount == 0:
                raise ZeroAmount()
            p = self._active(pid)
            self._accrue()
            self._apply_pending(pid)
            if amount > self._debt_of(p.norm_debt) - self.min_debt:
                raise RepayExceedsMaximum()
            if self.stable.get(caller, 0) < amount:
                raise InsufficientBalance()
            dn = mul_div_down(amount, RAY, self.index)
            p.norm_debt -= dn
            self.total_norm_debt -= dn
            self._update_stake(pid)
            self.sorted.reinsert(pid, upper, lower)
            self._burn(caller, amount)
            self._emit(("Repaid", pid, caller, amount, dn))
            self._updated(pid, OP_REPAY)

        self._atomic(run)

    def close(self, caller: str, pid: int) -> None:
        def run() -> None:
            if self.settled:
                raise SystemSettled()
            p = self._active(pid)
            if caller != p.owner:
                raise NotOwner()
            self._accrue()
            self._apply_pending(pid)
            debt = self._debt_of(p.norm_debt)
            if self.stable.get(caller, 0) < debt:
                raise InsufficientBalance()
            self.sorted.remove(pid)
            self.total_stakes -= p.stake
            self.total_collateral -= p.coll
            self.total_norm_debt -= p.norm_debt
            self.active_count -= 1
            coll = p.coll
            p.coll = p.norm_debt = p.stake = 0
            p.status = Status.CLOSED_BY_OWNER
            self._burn(caller, debt)
            self._weth_move("vault", caller, coll + self.gas_reserve)
            self._emit(("PositionClosed", pid, debt, coll, self.gas_reserve))
            self._updated(pid, OP_CLOSE)

        self._atomic(run)

    # ---- §5.1.7 / §6.4.1 ----
    def liquidate(self, caller: str, pid: int) -> int:
        """§6.4.1; returns the remainder path. Rounding R1, R34 (down), R27 (up)."""

        def run() -> int:
            if self.shutdown:
                raise SystemShutdown()
            p = self._active(pid)
            price = self._fetch_required_price()
            self._accrue()
            self._apply_pending(pid)
            debt = self._debt_of(p.norm_debt)
            if p.coll * price >= self.mcr * debt:
                raise NotLiquidatable()
            self.sorted.remove(pid)
            self.total_stakes -= p.stake
            self.total_collateral -= p.coll
            self.active_count -= 1
            n, coll, owner = p.norm_debt, p.coll, p.owner
            p.coll = p.norm_debt = p.stake = 0
            p.status = Status.CLOSED_BY_LIQUIDATION
            self._weth_move("vault", caller, self.gas_reserve)
            self._weth_move("vault", self.strategy_account, coll)
            weth_before = self.weth.get("vault", 0)
            absorbed, returned = self.strategy.on_liquidation(pid, owner, debt, coll, price)
            if absorbed > debt:  # CHG-012
                raise DebtAbsorbedExceedsDebt()
            if returned > coll:
                raise CollReturnedExceedsColl()
            if self.weth.get("vault", 0) != weth_before + returned:  # CHG-014
                raise CollReturnedNotReceived()
            norm_absorbed = n if absorbed == debt else mul_div_down(absorbed, RAY, self.index)
            norm_rest = n - norm_absorbed
            self.total_norm_debt -= norm_absorbed
            path = PATH_NONE
            if returned > 0 or norm_rest > 0:
                if self.total_stakes > 0:
                    self._redistribute(returned, norm_rest)
                    path = PATH_REDISTRIBUTED
                else:
                    debt_rest = self._debt_of(norm_rest)  # R27
                    self.total_norm_debt -= norm_rest
                    self._weth_move("vault", "ledger", returned)
                    self.ledger.record_deficit("vault", debt_rest, returned)
                    path = PATH_DEFICIT
            self._update_system_snapshots()
            self._emit(
                (
                    "Liquidated",
                    pid,
                    owner,
                    caller,
                    debt,
                    coll,
                    absorbed,
                    returned,
                    norm_rest,
                    path,
                    self.gas_reserve,
                )
            )
            self._updated(pid, OP_LIQUIDATE)
            return path

        return self._atomic(run)

    def _redistribute(self, coll_r: int, norm_r: int) -> None:
        rd.redistribute(self, coll_r, norm_r)

    def _update_system_snapshots(self) -> None:
        rd.update_system_snapshots(self)

    # ---- §5.1.9 / §6.7.3 ----
    def redeem_collateral(
        self,
        caller: str,
        redeemer: str,
        amount: int,
        fee_rate: int,
        price: int,
        max_iterations: int,
        upper: int,
        lower: int,
    ) -> tuple[int, int, int]:
        """§6.7.3: RedemptionModule only; no price fetch, no accrual (the module did both). Returns
        (redeemed, coll_sent, iterations). Collateral to the redeemer R18 (down), normalised debt
        removed by the partial R3 (down). A partial at exactly MIN_DEBT, below MCR after rounding
        (CHG-002) or with stale hints is cancelled with no state change and ends the loop."""

        def run() -> tuple[int, int, int]:
            if caller != self.redemption_module:
                raise Unauthorized()
            remaining, burned, coll_out, it = amount, 0, 0, 0
            cur = self.sorted.tail
            while remaining > 0 and cur != 0 and it < max_iterations:
                it += 1
                prev_id = self.sorted.nodes[cur][0]
                c, n = self.effective(cur)
                debt = self._debt_of(n)
                if _c(c * price) < _c(self.mcr * debt):  # below MCR: liquidate, don't redeem
                    cur = prev_id
                    continue
                if remaining >= debt:
                    out = self._redeem_full(cur, debt, fee_rate, price)
                    burned, coll_out, remaining = burned + debt, coll_out + out, remaining - debt
                    cur = prev_id
                    continue
                d = min(remaining, debt - self.min_debt)
                if d == 0:  # position at exactly MIN_DEBT
                    break
                dn = mul_div_down(d, RAY, self.index)
                out = mul_div_down(d, WAD - fee_rate, price)
                if _c((c - out) * price) < _c(self.mcr * self._debt_of(n - dn)):  # CHG-002
                    break
                found, prv, nxt, _ = self.sorted.find((c - out, n - dn), cur, cur, upper, lower)
                if not found:  # stale hint
                    break
                self._apply_pending(cur)
                p = self.positions[cur]
                p.coll -= out
                p.norm_debt -= dn
                self.total_collateral -= out
                self.total_norm_debt -= dn
                self._update_stake(cur)
                self.sorted.reinsert(cur, prv, nxt)
                burned, coll_out = burned + d, coll_out + out
                self._emit(("PositionRedeemed", cur, d, out, 0, False))
                self._updated(cur, OP_REDEEM)
                break  # a partial is always the last step
            self._burn(redeemer, burned)
            self._weth_move("vault", redeemer, coll_out)
            return burned, coll_out, it

        return self._atomic(run)  # type: ignore[return-value]

    def _redeem_full(self, pid: int, debt: int, fee_rate: int, price: int) -> int:
        self._apply_pending(pid)
        p = self.positions[pid]
        out = mul_div_down(debt, WAD - fee_rate, price)
        surplus = p.coll - out
        self.sorted.remove(pid)
        self.total_stakes -= p.stake
        self.total_collateral -= p.coll
        self.total_norm_debt -= p.norm_debt
        self.active_count -= 1
        p.coll = p.norm_debt = p.stake = 0
        p.status = Status.CLOSED_BY_REDEMPTION
        self._weth_move("vault", p.owner, surplus + self.gas_reserve)
        self._emit(("PositionRedeemed", pid, debt, out, surplus, True))
        self._updated(pid, OP_REDEEM)
        return out

    # ---- §5.1.10–5.1.11 ----
    def reclaim_gas_reserve(self, caller: str, pid: int) -> None:
        def run() -> None:
            if not self.settled:
                raise NotSettled()
            p = self._active(pid)
            if caller != p.owner:
                raise NotOwner()
            p.status = Status.CLOSED_BY_SHUTDOWN
            self.active_count -= 1
            self._weth_move("vault", p.owner, self.gas_reserve)
            self._emit(("GasReserveReclaimed", pid, p.owner, self.gas_reserve))
            self._updated(pid, OP_CLOSE)

        self._atomic(run)

    def on_shutdown(self, caller: str) -> None:
        def run() -> None:
            if caller != self.shutdown_module:
                raise Unauthorized()
            if self.shutdown:
                raise SystemShutdown()
            self.shutdown = True
            self._emit(("VaultShutdown", self.index))

        self._atomic(run)

    def on_settlement(self, caller: str) -> int:
        def run() -> int:
            if caller != self.shutdown_module:
                raise Unauthorized()
            if not self.shutdown:
                raise NotTriggered()
            if self.settled:
                raise AlreadySettled()
            coll = self.total_collateral + self.pending_coll
            self.total_collateral = 0
            self.pending_coll = 0
            self.settled = True
            self._weth_move("vault", self.shutdown_module, coll)
            self._emit(("VaultSettled", coll, self.active_count))
            return coll

        return self._atomic(run)

    # ---- §5.1.12 views ----
    def effective(self, pid: int) -> tuple[int, int]:
        p = self.positions.get(pid)
        if p is None:
            return 0, 0
        pc, pn = self._pending(p)
        return p.coll + pc, p.norm_debt + pn

    def sort_key(self, pid: int) -> tuple[int, int]:
        return self.effective(pid)

    def current_index(self) -> int:
        if self.shutdown:
            return self.index
        return mul_div_up(
            self.index, rpow(RAY + self.rate_per_second, self.now - self.last_accrual), RAY
        )

    def debt_of(self, pid: int) -> int:
        return mul_div_up(self.effective(pid)[1], self.current_index(), RAY)

    def icr(self, pid: int, price: int) -> int:
        debt = self.debt_of(pid)
        return 2**256 - 1 if debt == 0 else mul_div_down(self.effective(pid)[0], price, debt)

    def nicr(self, pid: int) -> int:
        c, n = self.effective(pid)
        return mul_div_down(c, NICR_PRECISION, n)

    def system_coll(self) -> int:
        """§5.1.12: collateral that would join the claim pool; B adds the auction house's lots."""
        c = self.total_collateral + self.pending_coll + self.ledger_recovered_coll
        return c if self.has_pool else c + self.house_total_lot

    def system_debt(self) -> int:
        """§5.1.12, R28 (up)."""
        return (
            mul_div_up(self.total_norm_debt, self.current_index(), RAY)
            + self.ledger_auction_debt
            + self.ledger_deficit
        )

    def is_liquidatable(self, pid: int, price: int) -> bool:
        p = self.positions.get(pid)
        if p is None or p.status != Status.ACTIVE:
            return False
        return self.effective(pid)[0] * price < self.mcr * self.debt_of(pid)
