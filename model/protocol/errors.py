"""The spec's custom errors (§11.2), one exception class per Solidity error, each defined once.

The class name is the error name, so a revert on either side compares by name (the differential
test's revert parity). Every class derives from `ProtocolError`. The EVM's arithmetic panics are not
custom errors: they are `Overflow` / `Underflow` / `DivisionByZero` from `model.protocol.math`
(`Panic(0x11)` / `Panic(0x12)`), re-exported here so callers have one import.

Token-level failures follow §2.5: a failed WETH transfer is `WethTransferFailed` (the differential
maps any revert raised inside WETH to that name), a stablecoin balance too small for a burn or move
is OZ's `ERC20InsufficientBalance`.

Errors the model declares but never raises, by design:
- `NotWired`, `AlreadyWired`, `NotDeployer` — `System` builds the wired graph whole, as the factory
  does, so no model call can meet an unwired contract (P22 decision; P23 excludes those paths);
- `InsufficientGasForOracle`, `InsufficientGasForPoolHook` — the model has no gas (§6.10.3, §6.2).
"""

from __future__ import annotations

from model.protocol.math import DivisionByZero, Overflow, Underflow


class ProtocolError(Exception):
    """Base of the spec's errors; the class name is the error name (§11.2)."""


# ---- lib/Errors.sol (shared) ----
class InvalidParameter(ProtocolError):
    """Constructor or `wire` argument out of range (§3.4); `index` is its 0-based position."""

    def __init__(self, index: int) -> None:
        super().__init__(index)
        self.index = index


class Unauthorized(ProtocolError):
    pass


class PriceUnusable(ProtocolError):
    pass


class SystemShutdown(ProtocolError):
    pass


class SystemSettled(ProtocolError):
    pass


class NotSettled(ProtocolError):
    pass


class ZeroAmount(ProtocolError):
    pass


class InsufficientBalance(ProtocolError):
    pass


class NotTriggered(ProtocolError):
    pass


class AlreadySettled(ProtocolError):
    pass


class AuctionCallbackActive(ProtocolError):
    pass


# ---- lib/Wired.sol (never raised by the model) ----
class NotWired(ProtocolError):
    pass


class AlreadyWired(ProtocolError):
    pass


class NotDeployer(ProtocolError):
    pass


# ---- VaultManager ----
class NotOwner(ProtocolError):
    pass


class PositionNotActive(ProtocolError):
    pass


class DebtBelowMinimum(ProtocolError):
    pass


class IcrBelowMcr(ProtocolError):
    pass


class InsufficientCollateral(ProtocolError):
    pass


class RepayExceedsMaximum(ProtocolError):
    pass


class CollateralTooLarge(ProtocolError):
    pass


class InsufficientGasForPoolHook(ProtocolError):  # never raised: no gas in the model
    pass


class NotLiquidatable(ProtocolError):
    pass


class DebtAbsorbedExceedsDebt(ProtocolError):
    pass


class CollReturnedExceedsColl(ProtocolError):
    pass


class CollReturnedNotReceived(ProtocolError):
    pass


# ---- SortedPositions ----
class NodeExists(ProtocolError):
    pass


class NodeNotFound(ProtocolError):
    pass


class StaleHint(ProtocolError):
    pass


# ---- StabilityPool ----
class NoDeposit(ProtocolError):
    pass


class DepositTooSmall(ProtocolError):
    pass


# ---- RedemptionModule ----
class ZeroIterations(ProtocolError):
    pass


class FeeExceedsMaximum(ProtocolError):
    pass


class NothingRedeemed(ProtocolError):
    pass


class TCRBelowCritical(ProtocolError):
    pass


# ---- OracleAdapter ----
class InvalidFeedDecimals(ProtocolError):
    """`priceFeed.decimals()` failed or exceeds 18."""


class InsufficientGasForOracle(ProtocolError):  # never raised: no gas in the model
    pass


# ---- StableToken ----
class SupplyCapExceeded(ProtocolError):
    pass


# ---- token-level failures (§2.5) ----
class WethTransferFailed(ProtocolError):
    pass


class ERC20InsufficientBalance(ProtocolError):
    pass


class ERC20InvalidReceiver(ProtocolError):
    """OZ v5: a transfer or mint to address(0)."""


class ERC20InvalidSender(ProtocolError):
    """OZ v5: a transfer from address(0)."""


__all__ = [
    "AlreadySettled",
    "AlreadyWired",
    "AuctionCallbackActive",
    "CollReturnedExceedsColl",
    "CollReturnedNotReceived",
    "CollateralTooLarge",
    "DebtAbsorbedExceedsDebt",
    "DebtBelowMinimum",
    "DepositTooSmall",
    "DivisionByZero",
    "ERC20InsufficientBalance",
    "ERC20InvalidReceiver",
    "ERC20InvalidSender",
    "FeeExceedsMaximum",
    "IcrBelowMcr",
    "InsufficientBalance",
    "InsufficientCollateral",
    "InsufficientGasForOracle",
    "InsufficientGasForPoolHook",
    "InvalidFeedDecimals",
    "InvalidParameter",
    "NoDeposit",
    "NodeExists",
    "NodeNotFound",
    "NotDeployer",
    "NotLiquidatable",
    "NotOwner",
    "NotSettled",
    "NotTriggered",
    "NotWired",
    "NothingRedeemed",
    "Overflow",
    "PositionNotActive",
    "PriceUnusable",
    "ProtocolError",
    "RepayExceedsMaximum",
    "StaleHint",
    "SupplyCapExceeded",
    "SystemSettled",
    "SystemShutdown",
    "TCRBelowCritical",
    "Unauthorized",
    "Underflow",
    "WethTransferFailed",
    "ZeroAmount",
    "ZeroIterations",
]
