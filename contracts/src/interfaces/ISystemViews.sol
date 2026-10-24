// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The DeficitLedger views the VaultManager's system aggregates read (spec §5.1.12, §4.7).
interface IDeficitLedgerViews {
    function recoveredColl() external view returns (uint256);
    function auctionDebt() external view returns (uint256);
    function deficit() external view returns (uint256);
}

/// @notice The DutchAuctionHouse view the VaultManager's system collateral reads in B (§4.5).
interface IAuctionHouseViews {
    function totalLot() external view returns (uint256);
}

/// @notice What accrual calls on the stability pool (deployment A): whether it takes its interest
///         share (`totalDeposits ≥ MIN_DEPOSIT`, §6.6.5) and the lock-free notification (§5.10).
interface IStabilityPoolInterest {
    function acceptsInterest() external view returns (bool);
    function onInterest(uint256 amount) external;
}

/// @notice What accrual calls on the DeficitLedger: the reserve share (§5.6).
interface IDeficitLedgerInterest {
    function onInterest(uint256 amount) external;
}
