// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";

/// @notice VaultManager with a test-only setter for the redistribution state that P20 will write, so
///         P14 can exercise `_applyPending` (§6.5.3) and `_computeStake` with non-zero snapshots
///         (§6.5.4) before the writers exist. Never deployed outside tests.
contract VaultManagerHarness is VaultManager {
    constructor(
        address weth_,
        address token_,
        address oracle_,
        uint256 mcr,
        uint256 minDebt,
        uint256 gasReserve,
        uint256 ratePerSecond,
        uint256 poolShareBps
    ) VaultManager(weth_, token_, oracle_, mcr, minDebt, gasReserve, ratePerSecond, poolShareBps) {}

    /// @dev The accrual state an `interest.json` vector starts from (§6.2). `totalNormDebt` set
    ///      without supply: I2 is not meaningful after this.
    function setAccrualState(uint256 index_, uint256 lastAccrual_, uint256 totalNormDebt_) external {
        index = index_;
        lastAccrual = lastAccrual_;
        totalNormDebt = totalNormDebt_;
    }

    /// @dev A non-round index, so rounding directions R1 / R2 / R3 become observable (P15 makes the
    ///      index move for real; supply is not adjusted here, so I2 is not meaningful after this).
    function setIndex(uint256 index_) external {
        index = index_;
    }

    function setRedistribution(
        uint256 lColl,
        uint256 lDebt,
        uint256 pendColl,
        uint256 pendNorm,
        uint256 stakesSnapshot,
        uint256 collSnapshot
    ) external {
        LColl = lColl;
        LDebt = lDebt;
        pendingColl = pendColl;
        pendingNormDebt = pendNorm;
        totalNormDebt += pendNorm; // pending debt is part of totalNormDebt (I1 supporting identity)
        totalStakesSnapshot = stakesSnapshot;
        totalCollateralSnapshot = collSnapshot;
    }
}
