// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The VaultManager views §5.8's `belowCritical` reads.
interface IStandInGateVault {
    function activeCount() external view returns (uint256);
    function systemColl() external view returns (uint256);
    function systemDebt() external view returns (uint256);
}

/// @notice The auction-house view the gate reads in deployment B.
interface IStandInGateHouse {
    function activeAuctions() external view returns (uint256);
}

/// @title StandInShutdownModule
/// @notice LOCAL ONLY. Occupies the ShutdownModule role until its prompt. It provides §5.8's
///         `belowCritical` exactly — `live and D > 0 and C · price < CRITICAL_TCR · D`, with
///         `live = activeCount > 0 or (auctionHouse != 0 and activeAuctions > 0)` — so the
///         redemption gate works, and nothing else: it can never trigger a shutdown or settle. Its
/// constructor reverts outside chain 31337.
contract StandInShutdownModule {
    /// @notice Deployed outside chain 31337, or with CRITICAL_TCR below WAD (the real constructor's
    ///         check, §3.4 index 4).
    error StandInInvalid();

    IStandInGateVault public immutable vaultManager;
    address public immutable auctionHouse;
    uint256 public immutable CRITICAL_TCR;

    constructor(address vaultManager_, address auctionHouse_, uint256 criticalTcr) {
        if (block.chainid != 31_337 || criticalTcr < 1e18) revert StandInInvalid();
        vaultManager = IStandInGateVault(vaultManager_);
        auctionHouse = auctionHouse_;
        CRITICAL_TCR = criticalTcr;
    }

    /// @notice §5.8. View; the price is the caller's.
    function belowCritical(uint256 price) external view returns (bool) {
        bool live = vaultManager.activeCount() > 0
            || (auctionHouse != address(0) && IStandInGateHouse(auctionHouse).activeAuctions() > 0);
        uint256 c = vaultManager.systemColl();
        uint256 d = vaultManager.systemDebt();
        return live && d > 0 && c * price < CRITICAL_TCR * d;
    }
}
