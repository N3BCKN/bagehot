"""RedemptionModule (P16), bit-for-bit with `contracts/src/redemption/RedemptionModule.sol`.

Spec §4.6, §5.5, §6.7.1–6.7.2. Integers only. The loop itself is `Vault.redeem_collateral`
(§6.7.3). The ShutdownModule's gate and the auction house's `inPurchase` are callables; `make_gate`
builds the gate exactly as §5.8 writes `belowCritical`, the same rule the Solidity test gate uses.

`redeem` is atomic like a transaction: on any exception both this module's state and the vault's
(including the accrual it ran) are restored.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from model.math import RAY, WAD, mul_div_up, rpow
from model.protocol.vault import (
    InsufficientBalance,
    PriceUnusable,  # noqa: F401 — raised by Vault._fetch_required_price, re-exported for callers
    SystemShutdown,
    Vault,
    VaultError,
    ZeroAmount,
    _error,
)

ZeroIterations = _error("ZeroIterations")
FeeExceedsMaximum = _error("FeeExceedsMaximum")
NothingRedeemed = _error("NothingRedeemed")
TCRBelowCritical = _error("TCRBelowCritical")
AuctionCallbackActive = _error("AuctionCallbackActive")

__all__ = [
    "AuctionCallbackActive",
    "FeeExceedsMaximum",
    "NothingRedeemed",
    "RedemptionModule",
    "TCRBelowCritical",
    "VaultError",
    "ZeroIterations",
    "make_gate",
]


def make_gate(
    vault: Vault, critical_tcr: int, active_auctions: Callable[[], int] = lambda: 0
) -> Callable[[int], bool]:
    """§5.8 `belowCritical(price)`: live and D > 0 and C·price < CRITICAL_TCR·D, on
    `systemColl` / `systemDebt` (which read `currentIndex()`)."""

    def below_critical(price: int) -> bool:
        live = vault.active_count > 0 or (not vault.has_pool and active_auctions() > 0)
        c, d = vault.system_coll(), vault.system_debt()
        return live and d > 0 and c * price < critical_tcr * d

    return below_critical


@dataclass
class RedemptionModule:
    vault: Vault
    fee_floor: int
    beta: int
    base_rate_decay: int
    below_critical: Callable[[int], bool]
    in_purchase: Callable[[], bool] | None = (
        None  # B: the house's flag; A: None (auctionHouse == 0)
    )
    base_rate: int = 0
    last_fee_operation_time: int = 0
    events: list[tuple] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.fee_floor > WAD or not 1 <= self.beta <= 100 or not 0 < self.base_rate_decay < RAY:
            raise ValueError("InvalidParameter")
        self.last_fee_operation_time = self.vault.now  # the construction timestamp

    # ---- §6.7.1 ----
    def decayed_base_rate(self) -> int:
        """R19 (up); floors at 1 wei once positive."""
        dt = self.vault.now - self.last_fee_operation_time
        return mul_div_up(self.base_rate, rpow(self.base_rate_decay, dt), RAY)

    def _increment(self, x: int, s0: int) -> int:
        """R20 (up)."""
        return mul_div_up(x, WAD, s0 * self.beta)

    def redemption_fee_rate(self, amount: int) -> int:
        """§5.5: the current supply, without accruing."""
        inc = self._increment(amount, self.vault.total_supply)
        return min(self.fee_floor + min(self.decayed_base_rate() + inc, WAD), WAD)

    # ---- §6.7.2 ----
    def redeem(
        self,
        caller: str,
        amount: int,
        max_iterations: int,
        max_fee_rate: int,
        upper: int,
        lower: int,
    ) -> tuple[int, int, int]:
        """Returns (redeemed, coll_sent, iterations) — the values `Redeemed` carries."""
        v = self.vault
        saved = (self.base_rate, self.last_fee_operation_time, len(self.events))

        def run() -> tuple[int, int, int]:
            if v.shutdown:
                raise SystemShutdown()
            if amount == 0:
                raise ZeroAmount()
            if max_iterations == 0:
                raise ZeroIterations()
            price = v._fetch_required_price()
            v._accrue()
            if self.in_purchase is not None and self.in_purchase():
                raise AuctionCallbackActive()
            if self.below_critical(price):
                raise TCRBelowCritical()
            if v.stable.get(caller, 0) < amount:
                raise InsufficientBalance()
            s0 = v.total_supply
            decayed = self.decayed_base_rate()
            fee_rate = min(self.fee_floor + min(decayed + self._increment(amount, s0), WAD), WAD)
            if fee_rate > max_fee_rate:
                raise FeeExceedsMaximum()
            redeemed, coll_sent, iterations = v.redeem_collateral(
                v.redemption_module, caller, amount, fee_rate, price, max_iterations, upper, lower
            )
            if redeemed == 0:
                raise NothingRedeemed()
            new_base = min(decayed + self._increment(redeemed, s0), WAD)
            self.base_rate, self.last_fee_operation_time = new_base, v.now
            self.events.append(
                ("Redeemed", caller, amount, redeemed, coll_sent, fee_rate, iterations, new_base)
            )
            return redeemed, coll_sent, iterations

        try:
            return v._atomic(run)  # type: ignore[return-value]
        except Exception:
            self.base_rate, self.last_fee_operation_time = saved[0], saved[1]
            del self.events[saved[2] :]
            raise
