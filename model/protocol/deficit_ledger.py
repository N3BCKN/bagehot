"""DeficitLedger (P21), bit-for-bit with `contracts/src/safety/DeficitLedger.sol`.

Spec §4.7, §5.6, §6.9, §6.11.3. Integers only. Tokens live in a *bank* with `stable` / `weth`
balances and `_burn` (the Vault model, or `stability_pool.Tokens`); the ledger's account is
"ledger". Callers are named strings ("vault", "pool", "house", "shutdown"). Every hook checks the
caller, then `not settled` (§5.6); each call is atomic. The Vault model still carries its own
stand-in ledger fields; the P22 model wires this class in.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field, fields

from model.protocol.vault import Unauthorized, VaultError, _error

SystemSettled = _error("SystemSettled")
AlreadySettled = _error("AlreadySettled")

__all__ = ["AlreadySettled", "DeficitLedger", "SystemSettled", "Unauthorized", "VaultError"]


@dataclass
class DeficitLedger:
    bank: object
    variant_b: bool = False
    reserve: int = 0
    auction_debt: int = 0
    deficit: int = 0
    recovered_coll: int = 0
    settled: bool = False
    events: list[tuple] = field(default_factory=list)

    def _atomic(self, fn):  # noqa: ANN001, ANN202
        saved = {
            f.name: copy.deepcopy(getattr(self, f.name)) for f in fields(self) if f.name != "bank"
        }

        def run():  # noqa: ANN202
            try:
                return fn()
            except Exception:
                self.__dict__.update(saved)
                raise

        return self.bank._atomic(run)

    def _hook(self, caller: str, allowed: str | None) -> None:
        if allowed is None or caller != allowed:
            raise Unauthorized()
        if self.settled:
            raise SystemSettled()

    @property
    def _house(self) -> str | None:
        return "house" if self.variant_b else None

    @property
    def _pool(self) -> str | None:
        return None if self.variant_b else "pool"

    # ---- §5.6 ----
    def on_interest(self, caller: str, amount: int) -> None:
        def run() -> None:
            self._hook(caller, "vault")
            self.reserve += amount
            self.events.append(("ReserveIncreased", amount, 1))

        self._atomic(run)

    def on_pool_dust(self, caller: str, amount: int) -> None:
        def run() -> None:
            self._hook(caller, self._pool)
            self.reserve += amount
            self.events.append(("ReserveIncreased", amount, 3))

        self._atomic(run)

    def record_deficit(self, caller: str, d: int, coll: int) -> None:
        def run() -> None:
            self._hook(caller, "vault")
            self.deficit += d
            self.recovered_coll += coll
            self.events.append(("DeficitRecorded", d, coll, 2))

        self._atomic(run)

    def add_auction_debt(self, caller: str, d: int) -> None:
        def run() -> None:
            self._hook(caller, self._house)
            self.auction_debt += d
            self.events.append(("AuctionDebtChanged", d, self.auction_debt))

        self._atomic(run)

    def on_auction_payment(self, caller: str, burned: int, to_reserve: int) -> None:
        def run() -> None:
            self._hook(caller, self._house)
            if burned > self.auction_debt:
                raise ArithmeticError("Underflow")
            self.auction_debt -= burned
            self.reserve += to_reserve
            self.events.append(("AuctionDebtChanged", -burned, self.auction_debt))
            if to_reserve > 0:
                self.events.append(("ReserveIncreased", to_reserve, 2))

        self._atomic(run)

    def on_auction_shortfall(self, caller: str, d: int) -> None:
        def run() -> None:
            self._hook(caller, self._house)
            if d > self.auction_debt:
                raise ArithmeticError("Underflow")
            self.auction_debt -= d
            self.deficit += d
            self.events.append(("AuctionDebtChanged", -d, self.auction_debt))
            self.events.append(("DeficitRecorded", d, 0, 1))

        self._atomic(run)

    def pay_tip(self, caller: str, to: str, amount: int) -> None:
        def run() -> None:
            self._hook(caller, self._house)
            if amount > self.reserve:
                raise ArithmeticError("Underflow")
            self.reserve -= amount
            stable = self.bank.stable
            stable["ledger"] = stable.get("ledger", 0) - amount
            stable[to] = stable.get(to, 0) + amount
            self.events.append(("ReserveDecreased", amount, 1))

        self._atomic(run)

    # ---- §6.9.2 ----
    def cover(self) -> int:
        def run() -> int:
            if self.settled:
                raise SystemSettled()
            c = min(self.reserve, self.deficit)
            if c > 0:
                self.reserve -= c
                self.deficit -= c
                self.bank._burn("ledger", c)
            self.events.append(("DeficitCovered", c, self.reserve, self.deficit))
            return c

        return self._atomic(run)

    # ---- §6.11.3 ----
    def on_settlement(self, caller: str) -> int:
        def run() -> int:
            if caller != "shutdown":
                raise Unauthorized()
            if self.settled:
                raise AlreadySettled()
            burned = self.reserve
            self.reserve = 0
            self.deficit += self.auction_debt
            self.auction_debt = 0
            coll, self.recovered_coll = self.recovered_coll, 0
            self.settled = True
            if burned > 0:
                self.bank._burn("ledger", burned)
            if coll > 0:
                self.bank._weth_move("ledger", "shutdown", coll)
            self.events.append(("LedgerSettled", burned, self.deficit, coll))
            return coll

        return self._atomic(run)
