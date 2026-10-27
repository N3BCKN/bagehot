"""WETH and StableToken balances (OZ ERC-20 v5 semantics), with their `Transfer` events.

Per-holder balances and the total supply are explicit state, part of `System.snapshot()`, because
I1 is an identity between token balances and internal claims. Every movement emits `Transfer` into
the run's log at the moment the contract would, mints from and burns to `ZERO`, zero amounts
included (OZ `_update` emits for any value). Roles (minter, burners, mover, §4.10) are the callers'
business: the contract models only call what their Solidity counterparts are allowed to call.

Failures follow §2.5: WETH raises `WethTransferFailed`, the stablecoin `ERC20InsufficientBalance`,
a mint past `2^128 − 1` `SupplyCapExceeded`. Allowances are not modelled (see `events.py`).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from model.protocol.errors import (
    ERC20InsufficientBalance,
    ProtocolError,
    SupplyCapExceeded,
    WethTransferFailed,
)
from model.protocol.events import ZERO, Log

SUPPLY_CAP = 2**128 - 1  # StableToken.SUPPLY_CAP


@dataclass(slots=True)
class Token:
    address: str  # the emitter name: "weth" or "token"
    log: Log
    insufficient: type[ProtocolError] = ERC20InsufficientBalance
    cap: int | None = None  # StableToken: SUPPLY_CAP; WETH: none
    balances: dict[str, int] = field(default_factory=dict)
    total_supply: int = 0

    def balance_of(self, a: str) -> int:
        return self.balances.get(a, 0)

    def transfer(self, frm: str, to: str, amount: int) -> None:
        b = self.balances.get(frm, 0)
        if b < amount:
            raise self.insufficient()
        self.balances[frm] = b - amount
        self.balances[to] = self.balances.get(to, 0) + amount
        self.log.emit(self.address, ("Transfer", frm, to, amount))

    def mint(self, to: str, amount: int) -> None:
        if self.cap is not None and amount > self.cap - self.total_supply:
            raise SupplyCapExceeded()
        self.balances[to] = self.balances.get(to, 0) + amount
        self.total_supply += amount
        self.log.emit(self.address, ("Transfer", ZERO, to, amount))

    def burn(self, frm: str, amount: int) -> None:
        b = self.balances.get(frm, 0)
        if b < amount:
            raise ERC20InsufficientBalance()
        self.balances[frm] = b - amount
        self.total_supply -= amount
        self.log.emit(self.address, ("Transfer", frm, ZERO, amount))

    # ---- rollback ----
    def _save(self) -> tuple[dict[str, int], int]:
        return dict(self.balances), self.total_supply

    def _restore(self, saved: tuple[dict[str, int], int]) -> None:
        # in place: callers hold `balances` (the `weth` / `stable` views)
        self.balances.clear()
        self.balances.update(saved[0])
        self.total_supply = saved[1]


def weth_token(log: Log) -> Token:
    return Token("weth", log, insufficient=WethTransferFailed)


def stable_token(log: Log) -> Token:
    return Token("token", log, cap=SUPPLY_CAP)
