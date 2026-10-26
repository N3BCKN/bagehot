// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolVault} from "../interfaces/IPoolVault.sol";
import {
    IDeficitLedgerDeficit,
    IDeficitLedgerInterest,
    IDeficitLedgerPoolDust,
    IDeficitLedgerViews
} from "../interfaces/ISystemViews.sol";
import {Unauthorized} from "../lib/Errors.sol";

/// @title StandInDeficitLedger
/// @notice LOCAL ONLY. Occupies the DeficitLedger role until P21: no auction debt (§5.1.12), and the
///         reserve share of interest recorded as §5.6
///         does (`reserve += amount`, the tokens having been minted to this address). Only the
///         VaultManager may notify it. In deployment A it also takes the stability pool's swept dust
///         (§5.3.1 `leave`): never settled, and `onPoolDust` records `reserve += amount` for the pool
///         the VaultManager was wired with (the stand-in reads it there instead of taking its own
///         `wire`). Its constructor reverts outside chain 31337.
///         Since P20 it also records a liquidation's no-stakes deficit (§5.6 `recordDeficit`:
///         `deficit += d; recoveredColl += coll`, the WETH transferred first), so `systemColl`,
///         `systemDebt` and I1's ledger row stay correct; `cover`, settlement and the DEFICIT shutdown
///         trigger belong to P21 (human decision 2026-10-26; carry-forward P20-SD).
contract StandInDeficitLedger is
    IDeficitLedgerViews,
    IDeficitLedgerInterest,
    IDeficitLedgerPoolDust,
    IDeficitLedgerDeficit
{
    address public immutable vaultManager;
    uint256 public reserve;
    uint256 public deficit;
    uint256 public recoveredColl;

    event DeficitRecorded(uint256 amount, uint256 coll, uint8 source);

    /// @notice Deployed outside chain 31337.
    error StandInLocalOnly();

    constructor(address vaultManager_) {
        if (block.chainid != 31_337) revert StandInLocalOnly();
        vaultManager = vaultManager_;
    }

    /// @notice §5.6: the reserve share of accrued interest. VaultManager only.
    function onInterest(uint256 amount) external {
        if (msg.sender != vaultManager) revert Unauthorized();
        reserve += amount;
    }

    /// @notice §5.6: the pool's swept residual, the tokens having been transferred to this address.
    ///         Only the VaultManager's stability pool (deployment A).
    function onPoolDust(uint256 amount) external {
        address pool = IPoolVault(vaultManager).stabilityPool();
        if (pool == address(0) || msg.sender != pool) revert Unauthorized();
        reserve += amount;
    }

    /// @notice Settlement does not exist before P21's ShutdownModule (§4.7).
    function settled() external pure returns (bool) {
        return false;
    }

    function auctionDebt() external pure returns (uint256) {
        return 0;
    }

    /// @notice §5.6: a liquidation remainder with no stake left to take it (§6.4.4). VaultManager only.
    function recordDeficit(uint256 d, uint256 coll) external {
        if (msg.sender != vaultManager) revert Unauthorized();
        deficit += d;
        recoveredColl += coll;
        emit DeficitRecorded(d, coll, 2); // SOURCE_NO_STAKES
    }
}
