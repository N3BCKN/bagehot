"""StabilityPool (P19), bit-for-bit with `contracts/src/liquidation/StabilityPool.sol`.

Spec §4.4, §5.3, §6.6, ADR-0033 (`on_interest` returns whether it booked). Integers only. The pool's
tokens live in a *bank*: the `Vault` model in a system run (its `stable` / `weth` balances, its
`_accrue` as the pool's `vaultManager.accrue()`, its stand-in ledger reserve), or `Tokens` in a unit
run (the `product_sum.json` test VaultManager: accrual is a no-op). Accounts are named: "pool",
"ledger", "vault", and depositors by name.

Each depositor operation is atomic like a transaction: on any exception the pool and its bank are
restored. Exceptions carry the spec's error names (§11.2).
"""

from __future__ import annotations

import copy
from collections.abc import Callable
from dataclasses import dataclass, field, fields

from model.math import WAD, mul_div_down, mul_div_up
from model.protocol.vault import (
    ERC20InsufficientBalance,
    InsufficientBalance,
    SupplyCapExceeded,
    Unauthorized,  # noqa: F401 — the hooks' caller check lives in the contract; re-exported
    VaultError,
    WethTransferFailed,
    ZeroAmount,
    _c,
    _error,
)

DECIMAL_PRECISION = 10**18
P_PRECISION = 10**36
SCALE_FACTOR = 10**9
P_MIN = P_PRECISION // SCALE_FACTOR
SCALE_SPAN = 2
SUPPLY_CAP = 2**128 - 1

NoDeposit = _error("NoDeposit")
DepositTooSmall = _error("DepositTooSmall")

__all__ = [
    "DepositTooSmall",
    "NoDeposit",
    "StabilityPool",
    "Tokens",
    "VaultError",
]


@dataclass
class Tokens:
    """The unit-vector bank: WETH and stablecoin balances, the DeficitLedger stand-in's reserve and
    `settled` flag; accrual is a no-op (counted)."""

    weth: dict[str, int] = field(default_factory=dict)
    stable: dict[str, int] = field(default_factory=dict)
    total_supply: int = 0
    ledger_reserve: int = 0
    ledger_settled: bool = False
    accrue_calls: int = 0

    def _atomic(self, fn: Callable[[], object]) -> object:
        saved = {f.name: copy.deepcopy(getattr(self, f.name)) for f in fields(self)}
        try:
            return fn()
        except Exception:
            self.__dict__.update(saved)
            raise

    def _accrue(self) -> None:
        self.accrue_calls += 1

    def _weth_move(self, frm: str, to: str, amount: int) -> None:
        if self.weth.get(frm, 0) < amount:
            raise WethTransferFailed()
        self.weth[frm] -= amount
        self.weth[to] = self.weth.get(to, 0) + amount

    def _mint(self, to: str, amount: int) -> None:
        if amount > SUPPLY_CAP - self.total_supply:
            raise SupplyCapExceeded()
        self.stable[to] = self.stable.get(to, 0) + amount
        self.total_supply += amount

    def _burn(self, frm: str, amount: int) -> None:
        if self.stable.get(frm, 0) < amount:
            raise ERC20InsufficientBalance()
        self.stable[frm] -= amount
        self.total_supply -= amount

    def _stable_move(self, frm: str, to: str, amount: int) -> None:
        if self.stable.get(frm, 0) < amount:
            raise ERC20InsufficientBalance()
        self.stable[frm] -= amount
        self.stable[to] = self.stable.get(to, 0) + amount

    def on_pool_dust(self, amount: int) -> None:
        self.ledger_reserve += amount

    def is_ledger_settled(self) -> bool:
        return self.ledger_settled


@dataclass
class Deposit:
    initial: int = 0
    snap_p: int = 0
    snap_s: int = 0
    snap_g: int = 0
    snap_epoch: int = 0
    snap_scale: int = 0


@dataclass
class StabilityPool:
    bank: object  # Tokens, or the Vault model
    liquidation_penalty: int
    min_deposit: int
    total_deposits: int = 0
    p: int = P_PRECISION
    current_scale: int = 0
    current_epoch: int = 0
    s: dict[tuple[int, int], int] = field(default_factory=dict)
    g: dict[tuple[int, int], int] = field(default_factory=dict)
    last_coll_error: int = 0
    last_interest_error: int = 0
    coll_gains_balance: int = 0
    interest_gains_balance: int = 0
    deposits: dict[str, Deposit] = field(default_factory=dict)
    depositor_count: dict[int, int] = field(default_factory=dict)
    events: list[tuple] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.liquidation_penalty > WAD // 2 or self.min_deposit < 10**18:
            raise ValueError("InvalidParameter")

    # ---- transaction wrapper: the pool's own state, inside the bank's ----
    def _atomic(self, fn: Callable[[], object]) -> object:
        saved = {
            f.name: copy.deepcopy(getattr(self, f.name)) for f in fields(self) if f.name != "bank"
        }

        def run() -> object:
            try:
                return fn()
            except Exception:
                self.__dict__.update(saved)
                raise

        return self.bank._atomic(run)

    # ---- helpers ----
    def _stable_transfer(self, frm: str, to: str, amount: int) -> None:
        bank = self.bank
        if hasattr(bank, "_stable_move"):
            bank._stable_move(frm, to, amount)
            return
        if bank.stable.get(frm, 0) < amount:
            raise ERC20InsufficientBalance()
        bank.stable[frm] -= amount
        bank.stable[to] = bank.stable.get(to, 0) + amount

    def _rec(self, a: str) -> Deposit:
        return self.deposits.get(a, Deposit())

    def _leave(self, a: str, in_current_epoch: bool) -> int:
        """§5.3.1 `leave`."""
        self.deposits.pop(a, None)
        swept = 0
        if in_current_epoch:
            e = self.current_epoch
            self.depositor_count[e] = self.depositor_count.get(e, 0) - 1
            if self.depositor_count[e] < 0:
                raise AssertionError("Underflow")
            if (
                self.depositor_count[e] == 0
                and self.total_deposits > 0
                and not self.bank.is_ledger_settled()
            ):
                swept = self.total_deposits
                self.total_deposits = 0
                self._stable_transfer("pool", "ledger", swept)
                self.bank.on_pool_dust(swept)
        return swept

    def _emit_deposit(self, a: str) -> None:
        r = self.deposits.get(a)
        if r is None or r.initial == 0:
            self.events.append(
                ("DepositUpdated", a, 0, self.p, self.current_epoch, self.current_scale, 0, 0)
            )
        else:
            self.events.append(
                (
                    "DepositUpdated",
                    a,
                    r.initial,
                    r.snap_p,
                    r.snap_epoch,
                    r.snap_scale,
                    r.snap_s,
                    r.snap_g,
                )
            )

    def _snapshot(self, a: str, x: int) -> None:
        """§6.6.8 `snapshot(x)`."""
        key = (self.current_epoch, self.current_scale)
        self.deposits[a] = Deposit(x, self.p, self.s.get(key, 0), self.g.get(key, 0), *key)

    def _pay_gains(self, a: str, coll_gain: int, interest_gain: int) -> None:
        """§6.6.8 "pay gains"."""
        if coll_gain > 0:
            self.coll_gains_balance -= coll_gain
            self.bank._weth_move("pool", a, coll_gain)
        if interest_gain > 0:
            self.interest_gains_balance -= interest_gain
            self._stable_transfer("pool", a, interest_gain)

    # ---- §6.6.2 ----
    def _offset(self, d: int, c: int) -> None:
        t = self.total_deposits
        num = _c(c * DECIMAL_PRECISION + self.last_coll_error)
        per_unit = num // t  # R14: floor with carry
        self.last_coll_error = num - per_unit * t
        key = (self.current_epoch, self.current_scale)
        self.s[key] = _c(self.s.get(key, 0) + _c(per_unit * self.p))
        self.coll_gains_balance = _c(self.coll_gains_balance + c)
        self.bank._burn("pool", d)
        self.total_deposits = t - d
        if d == t:
            self.current_epoch += 1
            self.current_scale = 0
            self.p = P_PRECISION
        else:
            k = 0
            new_p = mul_div_down(self.p, t - d, t)  # R13
            while new_p < P_MIN:
                k += 1
                new_p = mul_div_down(_c(self.p * SCALE_FACTOR**k), t - d, t)  # R13
            self.p = new_p
            self.current_scale += k
        self.events.append(
            (
                "PoolOffset",
                d,
                c,
                per_unit,
                self.last_coll_error,
                self.p,
                self.current_epoch,
                self.current_scale,
                self.total_deposits,
            )
        )

    # ---- views (§6.6.6, §6.6.7) ----
    def accepts_interest(self) -> bool:
        return self.total_deposits >= self.min_deposit

    def compounded_deposit(self, a: str) -> int:
        r = self._rec(a)
        if r.initial == 0 or r.snap_epoch < self.current_epoch:
            return 0
        ds = self.current_scale - r.snap_scale
        if ds > 5:
            return 0
        q = mul_div_down(r.initial, self.p, r.snap_p)  # R16
        return q // SCALE_FACTOR**ds

    def _gain(self, r: Deposit, acc: dict[tuple[int, int], int], snap: int) -> int:
        total = acc.get((r.snap_epoch, r.snap_scale), 0) - snap
        if total < 0:
            raise AssertionError("Underflow")
        for j in range(1, SCALE_SPAN + 1):
            total = _c(total + acc.get((r.snap_epoch, r.snap_scale + j), 0) // SCALE_FACTOR**j)
        return mul_div_down(r.initial, total, _c(r.snap_p * DECIMAL_PRECISION))  # R17

    def gains(self, a: str) -> tuple[int, int]:
        r = self._rec(a)
        if r.initial == 0:
            return 0, 0
        return self._gain(r, self.s, r.snap_s), self._gain(r, self.g, r.snap_g)

    # ---- depositor functions (§5.3) ----
    def deposit(self, caller: str, amount: int) -> None:
        def run() -> None:
            if amount == 0:
                raise ZeroAmount()
            self.bank._accrue()
            rec = self._rec(caller)
            in_current_epoch = rec.initial > 0 and rec.snap_epoch == self.current_epoch
            coll_gain, interest_gain = self.gains(caller)
            compounded = self.compounded_deposit(caller)
            new_deposit = _c(compounded + amount)
            if new_deposit < self.min_deposit:
                raise DepositTooSmall()
            if self.bank.stable.get(caller, 0) < amount:
                raise InsufficientBalance()
            self._pay_gains(caller, coll_gain, interest_gain)
            self.total_deposits = _c(self.total_deposits + amount)
            self._snapshot(caller, new_deposit)
            if not in_current_epoch:
                e = self.current_epoch
                self.depositor_count[e] = self.depositor_count.get(e, 0) + 1
            self._stable_transfer(caller, "pool", amount)
            self._emit_deposit(caller)
            self.events.append(("GainsPaid", caller, coll_gain, interest_gain))

        self._atomic(run)

    def withdraw(self, caller: str, amount: int) -> int:
        """Returns the amount swept to the ledger (0 if none)."""

        def run() -> int:
            if amount == 0:
                raise ZeroAmount()
            self.bank._accrue()
            rec = self._rec(caller)
            if rec.initial == 0:
                raise NoDeposit()
            in_current_epoch = rec.snap_epoch == self.current_epoch
            coll_gain, interest_gain = self.gains(caller)
            compounded = self.compounded_deposit(caller)
            w = min(amount, compounded)
            new_deposit = compounded - w
            if new_deposit != 0 and new_deposit < self.min_deposit:
                raise DepositTooSmall()
            self._pay_gains(caller, coll_gain, interest_gain)
            self.total_deposits -= w
            swept = 0
            if new_deposit == 0:
                swept = self._leave(caller, in_current_epoch)
            else:
                self._snapshot(caller, new_deposit)
            self._stable_transfer("pool", caller, w)
            self._emit_deposit(caller)
            self.events.append(("GainsPaid", caller, coll_gain, interest_gain))
            if swept > 0:
                self.events.append(("PoolDustSwept", swept))
            return swept

        return self._atomic(run)

    def claim_gains(self, caller: str) -> int:
        def run() -> int:
            self.bank._accrue()
            rec = self._rec(caller)
            if rec.initial == 0:
                raise NoDeposit()
            in_current_epoch = rec.snap_epoch == self.current_epoch
            coll_gain, interest_gain = self.gains(caller)
            compounded = self.compounded_deposit(caller)
            self._pay_gains(caller, coll_gain, interest_gain)
            swept = 0
            if compounded == 0:
                swept = self._leave(caller, in_current_epoch)
            else:
                self._snapshot(caller, compounded)
            self._emit_deposit(caller)
            self.events.append(("GainsPaid", caller, coll_gain, interest_gain))
            if swept > 0:
                self.events.append(("PoolDustSwept", swept))
            return swept

        return self._atomic(run)

    # ---- hooks (§5.3.4) ----
    def on_liquidation(
        self, position_id: int, owner: str, debt: int, coll: int, price: int
    ) -> tuple[int, int]:
        """§6.6.4; `coll` WETH already received. Called by the VaultManager inside its own
        transaction, so not separately atomic."""
        seized = min(coll, mul_div_up(debt, WAD + self.liquidation_penalty, price))  # R11
        surplus = coll - seized
        d_p = min(debt, self.total_deposits)
        coll_p = seized if d_p == debt else mul_div_down(seized, d_p, debt)  # R12
        coll_returned = seized - coll_p
        if d_p > 0:
            self._offset(d_p, coll_p)
        if surplus > 0:
            self.bank._weth_move("pool", owner, surplus)
        if coll_returned > 0:
            self.bank._weth_move("pool", "vault", coll_returned)
        self.events.append(
            (
                "PoolLiquidation",
                position_id,
                debt,
                coll,
                seized,
                surplus,
                d_p,
                coll_p,
                coll_returned,
            )
        )
        return d_p, coll_returned

    def on_interest(self, amount: int) -> bool:
        """§6.6.5 / ADR-0033: declines below MIN_DEPOSIT without changing state; R15 with carry."""
        t = self.total_deposits
        if t < self.min_deposit:
            return False
        num = _c(amount * DECIMAL_PRECISION + self.last_interest_error)
        per_unit = num // t  # R15: floor with carry
        self.last_interest_error = num - per_unit * t
        key = (self.current_epoch, self.current_scale)
        self.g[key] = _c(self.g.get(key, 0) + _c(per_unit * self.p))
        self.interest_gains_balance = _c(self.interest_gains_balance + amount)
        self.events.append(("PoolInterest", amount, per_unit, self.last_interest_error))
        return True

    # ---- test-VaultManager hooks of the unit vectors ----
    def hook_offset(self, d: int, c: int) -> None:
        """`hook.offset(d, c)`: `c` WETH sent to the pool, then §6.6.2."""

        def run() -> None:
            self.bank.weth["pool"] = self.bank.weth.get("pool", 0) + c
            self._offset(d, c)

        self._atomic(run)

    def hook_on_interest(self, g: int) -> bool:
        """`hook.onInterest(g)`: `g` minted to the pool, then §6.6.5."""

        def run() -> bool:
            self.bank._mint("pool", g)
            return self.on_interest(g)

        return self._atomic(run)
