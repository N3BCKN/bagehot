"""Events (§11.1): the schema, and the one ordered log every contract model writes to.

An event is a plain tuple `("Name", *fields)` with the fields in the spec's order and types mapped
to Python ints, bools and account names (addresses). The log records `(emitter, event)` in emission
order across contracts, so a run has one cross-contract order, as the chain does (I14, and the
differential test's event comparison). `emitter` is the contract's account name: "vault", "sorted",
"pool", "redemption", "ledger", "oracle", "token" (StableToken) or "weth".

Rollback is truncation: a transaction records `log.mark()` and, on an exception, calls
`log.truncate(mark)`, so a failed call leaves no event behind, as a revert drops its logs.

Not emitted by the model: `Wired` (deployment, not an operation; `System` builds the wired graph
whole) and `Approval` (actors grant WETH allowances once, outside the protocol; OZ v5's
`transferFrom` spends an allowance without an event).
"""

from __future__ import annotations

from dataclasses import dataclass, field

ZERO = "0x0"  # address(0): the `from` of a mint and the `to` of a burn

# name -> field names, in the spec's order (§11.1). A-, B- and shutdown-side events alike, so one
# table serves the model now and P34 / the ShutdownModule prompt later.
EVENTS: dict[str, tuple[str, ...]] = {
    # VaultManager
    "PositionOpened": ("id", "owner", "debtMinted"),
    "PositionUpdated": (
        "id",
        "coll",
        "normDebt",
        "stake",
        "snapLColl",
        "snapLDebt",
        "status",
        "op",
    ),
    "RewardsApplied": ("id", "collReward", "normReward"),
    "CollateralAdded": ("id", "from", "amount"),
    "CollateralWithdrawn": ("id", "amount"),
    "Borrowed": ("id", "amount", "normDelta"),
    "Repaid": ("id", "from", "amount", "normDelta"),
    "PositionClosed": ("id", "debtBurned", "collReturned", "gasReserveReturned"),
    "Liquidated": (
        "id",
        "owner",
        "liquidator",
        "debt",
        "coll",
        "debtAbsorbed",
        "collRemainder",
        "normRemainder",
        "remainderPath",
        "gasCompensation",
    ),
    "Redistributed": (
        "coll",
        "normDebt",
        "LColl",
        "LDebt",
        "errorColl",
        "errorDebt",
        "totalStakes",
    ),
    "SystemSnapshotsUpdated": ("totalStakesSnapshot", "totalCollateralSnapshot"),
    "InterestAccrued": ("index", "interest", "toPool", "toReserve", "timestamp"),
    "PoolInterestRedirected": ("amount",),
    "PositionRedeemed": ("id", "debtRedeemed", "collToRedeemer", "surplusToOwner", "closed"),
    "GasReserveReclaimed": ("id", "owner", "amount"),
    "VaultShutdown": ("index",),
    "VaultSettled": ("collToClaimPool", "activePositions"),
    # SortedPositions
    "NodeInserted": ("id", "prev", "next"),
    "NodeRemoved": ("id",),
    # StabilityPool
    "DepositUpdated": ("depositor", "deposit", "P", "epoch", "scale", "snapS", "snapG"),
    "GainsPaid": ("depositor", "collGain", "interestGain"),
    "PoolOffset": (
        "debt",
        "coll",
        "perUnitGain",
        "lastCollError",
        "P",
        "epoch",
        "scale",
        "totalDeposits",
    ),
    "PoolLiquidation": (
        "positionId",
        "debt",
        "coll",
        "seized",
        "surplus",
        "debtOffset",
        "collToPool",
        "collReturned",
    ),
    "PoolInterest": ("amount", "perUnitGain", "lastInterestError"),
    "PoolDustSwept": ("amount",),
    # DutchAuctionHouse (B, P34)
    "AuctionStarted": ("auctionId", "positionId", "owner", "debt", "tab", "lot", "top", "tic"),
    "AuctionBought": (
        "auctionId",
        "sender",
        "who",
        "slice",
        "owe",
        "price",
        "burned",
        "toReserve",
        "tab",
        "lot",
        "debtRemaining",
    ),
    "AuctionReset": ("auctionId", "top", "tic", "tip", "caller"),
    "AuctionFinished": ("auctionId", "reason", "amount"),
    "HouseSettled": ("lot", "activeAuctions"),
    # RedemptionModule
    "Redeemed": (
        "redeemer",
        "requested",
        "redeemed",
        "collSent",
        "feeRate",
        "iterations",
        "baseRate",
    ),
    # DeficitLedger
    "ReserveIncreased": ("amount", "source"),
    "ReserveDecreased": ("amount", "reason"),
    "AuctionDebtChanged": ("delta", "auctionDebt"),
    "DeficitRecorded": ("amount", "coll", "source"),
    "DeficitCovered": ("amount", "reserve", "deficit"),
    "LedgerSettled": ("reserveBurned", "deficit", "recoveredColl"),
    # OracleAdapter
    "LastGoodPriceUpdated": ("price",),
    "OracleFailure": ("reason", "timestamp"),
    "OracleRecovered": ("timestamp",),
    # ShutdownModule (its prompt)
    "ShutdownChecked": ("usable", "price"),
    "ShutdownTriggered": (
        "reason",
        "timestamp",
        "price",
        "usable",
        "systemColl",
        "systemDebt",
        "deficit",
        "totalSupply",
    ),
    "Settled": ("claimColl", "claimSupply", "timestamp"),
    "Claimed": ("holder", "amount", "collOut"),
    # ERC-20 (StableToken, WETH)
    "Transfer": ("from", "to", "value"),
}

Entry = tuple[str, tuple]


@dataclass(slots=True)
class Log:
    """The run's ordered event log: `(emitter, event)` pairs."""

    entries: list[Entry] = field(default_factory=list)

    def emit(self, emitter: str, event: tuple) -> None:
        self.entries.append((emitter, event))

    def mark(self) -> int:
        return len(self.entries)

    def truncate(self, mark: int) -> None:
        del self.entries[mark:]

    def since(self, mark: int) -> list[Entry]:
        return self.entries[mark:]

    def of(self, emitter: str) -> list[tuple]:
        """One contract's events in order — what that contract's own logs would show."""
        return [e for src, e in self.entries if src == emitter]


def well_formed(event: tuple) -> bool:
    """The event's name is in §11.1 and its field count matches."""
    names = EVENTS.get(event[0]) if event else None
    return names is not None and len(event) == 1 + len(names)
