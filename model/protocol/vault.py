"""VaultManager parts I–III (P14–P16), bit-for-bit with `contracts/src/core/VaultManager.sol`.

Spec §4.2, §5.1.1–5.1.12, §6.2, §6.5.3–6.5.4, §6.7.3. Integers only. Covers positions, interest
accrual and its routing (P15), the redemption loop (P16), the shutdown hooks and the views;
redistribution (P20) has not happened, so the accumulators are 0. Time is `now`, set by the caller
(block.timestamp). The pool and the ledger are stand-ins: balances "pool" / "ledger" in `stable`,
the pool's `acceptsInterest` as a callable, the hooks' effects recorded in `pool_interest` /
`ledger_reserve`, and the ledger and auction-house views that `systemColl` / `systemDebt` read as
plain fields (`ledger_recovered_coll`, …). The P22 model extends this module rather than replacing
it.

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

from model.math import RAY, UINT256_MAX, WAD, Overflow, mul_div_down, mul_div_up, rpow
from model.protocol.sorted_list import SortedList

BPS = 10_000
COLL_CAP = 2**128 - 1
SUPPLY_CAP = 2**128 - 1
DECIMAL_PRECISION = 10**18
NICR_PRECISION = 10**20
OP_OPEN, OP_ADD_COLLATERAL, OP_WITHDRAW_COLLATERAL, OP_BORROW, OP_REPAY, OP_CLOSE = 1, 2, 3, 4, 5, 6
OP_REDEEM = 7


class Status(IntEnum):
    NONE = 0
    ACTIVE = 1
    CLOSED_BY_OWNER = 2
    CLOSED_BY_REDEMPTION = 3
    CLOSED_BY_LIQUIDATION = 4
    CLOSED_BY_SHUTDOWN = 5


def _c(x: int) -> int:
    """Solidity's checked arithmetic: a result above 2^256 − 1 panics (0x11) — `Overflow` here
    (spec §2.2), so the model never reports a spec error where the contract panics."""
    if x > UINT256_MAX:
        raise Overflow()
    return x


class VaultError(Exception):
    """Base of the spec's errors; the class name is the error name (§11.2)."""


def _error(name: str) -> type[VaultError]:
    return type(name, (VaultError,), {})


SystemShutdown = _error("SystemShutdown")
SystemSettled = _error("SystemSettled")
NotSettled = _error("NotSettled")
ZeroAmount = _error("ZeroAmount")
PositionNotActive = _error("PositionNotActive")
NotOwner = _error("NotOwner")
DebtBelowMinimum = _error("DebtBelowMinimum")
CollateralTooLarge = _error("CollateralTooLarge")
PriceUnusable = _error("PriceUnusable")
IcrBelowMcr = _error("IcrBelowMcr")
InsufficientCollateral = _error("InsufficientCollateral")
RepayExceedsMaximum = _error("RepayExceedsMaximum")
InsufficientBalance = _error("InsufficientBalance")
Unauthorized = _error("Unauthorized")
NotTriggered = _error("NotTriggered")
AlreadySettled = _error("AlreadySettled")
SupplyCapExceeded = _error("SupplyCapExceeded")
WethTransferFailed = _error("WethTransferFailed")
ERC20InsufficientBalance = _error("ERC20InsufficientBalance")


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
    accepts_interest: Callable[[], bool] = lambda: False
    # the pool's §6.6.5 booking, called after its share is minted (deployment A with a pool model)
    pool_on_interest: Callable[[int], object] | None = None
    now: int = 0
    last_accrual: int = 0
    pool_interest: int = 0
    ledger_reserve: int = 0
    settled_ledger: bool = False  # the stand-in ledger never settles before P21
    ledger_recovered_coll: int = 0
    ledger_auction_debt: int = 0
    ledger_deficit: int = 0
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
    shutdown: bool = False
    settled: bool = False
    weth: dict[str, int] = field(default_factory=dict)  # balances; "vault" is the VaultManager
    stable: dict[str, int] = field(default_factory=dict)
    total_supply: int = 0
    events: list[tuple] = field(default_factory=list)
    sorted: SortedList = field(init=False)

    def __post_init__(self) -> None:
        self.sorted = SortedList(self.max_hint_steps, self.sort_key)

    # ---- transaction wrapper ----
    def _atomic(self, fn: Callable[[], object]) -> object:
        # exactly the declared state fields — not the price source, the list (saved below) or any
        # attribute a caller attached
        saved = {
            f.name: copy.deepcopy(getattr(self, f.name))
            for f in fields(self)
            if f.name not in ("price_source", "sorted", "accepts_interest", "pool_on_interest")
        }
        saved_sorted = (
            copy.deepcopy(self.sorted.nodes),
            self.sorted.head,
            self.sorted.tail,
            list(self.sorted.events),
        )
        try:
            return fn()
        except Exception:
            self.__dict__.update(saved)
            self.sorted.nodes, self.sorted.head, self.sorted.tail, self.sorted.events = saved_sorted
            self.sorted.key_of = self.sort_key
            raise

    # ---- token helpers (WETH via SafeERC20, StableToken) ----
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
        self.stable[frm] = self.stable.get(frm, 0) - amount
        self.total_supply -= amount

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
        if self.has_pool and self.accepts_interest():
            to_pool = mul_div_down(interest, self.pool_share_bps, BPS)
        to_reserve = interest - to_pool
        if to_pool > 0:
            self._mint("pool", to_pool)
            self.pool_interest += to_pool
            if self.pool_on_interest is not None:
                self.pool_on_interest(to_pool)
        if to_reserve > 0:
            self._mint("ledger", to_reserve)
            self.ledger_reserve += to_reserve
        self.events.append(("InterestAccrued", new, interest, to_pool, to_reserve, self.now))

    # ---- the DeficitLedger stand-in's pool-dust hook (§5.3.1 `leave`, §5.6) ----
    def on_pool_dust(self, amount: int) -> None:
        self.ledger_reserve += amount

    def is_ledger_settled(self) -> bool:
        return self.settled_ledger

    def accrue(self) -> None:
        """§5.1.8: anyone; any mode (no-op once shut down)."""
        self._atomic(self._accrue)

    def _debt_of(self, n: int) -> int:
        return mul_div_up(n, self.index, RAY)

    def _pending(self, p: Position) -> tuple[int, int]:
        return (
            mul_div_down(p.stake, self.l_coll - p.snap_l_coll, DECIMAL_PRECISION),
            mul_div_down(p.stake, self.l_debt - p.snap_l_debt, DECIMAL_PRECISION),
        )

    def _apply_pending(self, pid: int) -> None:
        p = self.positions[pid]
        pc, pn = self._pending(p)
        if pc > 0 or pn > 0:
            p.coll += pc
            p.norm_debt += pn
            self.pending_coll -= pc
            self.pending_norm_debt -= pn
            self.total_collateral += pc
            self.events.append(("RewardsApplied", pid, pc, pn))
        p.snap_l_coll, p.snap_l_debt = self.l_coll, self.l_debt

    def _compute_stake(self, coll: int) -> int:
        if self.total_stakes_snapshot == 0 or self.total_collateral_snapshot == 0:
            return coll
        return mul_div_down(coll, self.total_stakes_snapshot, self.total_collateral_snapshot)

    def _update_stake(self, pid: int) -> None:
        p = self.positions[pid]
        new = self._compute_stake(p.coll)
        self.total_stakes = self.total_stakes - p.stake + new
        p.stake = new

    def _active(self, pid: int) -> Position:
        p = self.positions.get(pid)
        if p is None or p.status != Status.ACTIVE:
            raise PositionNotActive()
        return p

    def _updated(self, pid: int, op: int) -> None:
        p = self.positions[pid]
        self.events.append(
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
            self.events.append(("PositionOpened", pid, caller, debt))
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
            self.events.append(("CollateralAdded", pid, caller, amount))
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
            self.events.append(("CollateralWithdrawn", pid, amount))
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
            self.events.append(("Borrowed", pid, amount, dn))
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
            self.events.append(("Repaid", pid, caller, amount, dn))
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
            self.events.append(("PositionClosed", pid, debt, coll, self.gas_reserve))
            self._updated(pid, OP_CLOSE)

        self._atomic(run)

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
                self.events.append(("PositionRedeemed", cur, d, out, 0, False))
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
        self.events.append(("PositionRedeemed", pid, debt, out, surplus, True))
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
            self.events.append(("GasReserveReclaimed", pid, p.owner, self.gas_reserve))
            self._updated(pid, OP_CLOSE)

        self._atomic(run)

    def on_shutdown(self, caller: str) -> None:
        def run() -> None:
            if caller != self.shutdown_module:
                raise Unauthorized()
            if self.shutdown:
                raise SystemShutdown()
            self.shutdown = True
            self.events.append(("VaultShutdown", self.index))

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
            self.events.append(("VaultSettled", coll, self.active_count))
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
