// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDeficitLedgerInterest, IDeficitLedgerViews} from "../interfaces/ISystemViews.sol";
import {Unauthorized} from "../lib/Errors.sol";

/// @title StandInDeficitLedger
/// @notice LOCAL ONLY. Occupies the DeficitLedger role until P21: no recovered collateral, no
///         auction debt, no deficit (§5.1.12), and the reserve share of interest recorded as §5.6
///         does (`reserve += amount`, the tokens having been minted to this address). Only the
///         VaultManager may notify it. Its constructor reverts outside chain 31337.
contract StandInDeficitLedger is IDeficitLedgerViews, IDeficitLedgerInterest {
    address public immutable vaultManager;
    uint256 public reserve;

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

    function recoveredColl() external pure returns (uint256) {
        return 0;
    }

    function auctionDebt() external pure returns (uint256) {
        return 0;
    }

    function deficit() external pure returns (uint256) {
        return 0;
    }
}
