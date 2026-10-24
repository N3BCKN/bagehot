// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The VaultManager views §5.8's `belowCritical` reads.
interface IGateVaultViews {
    function activeCount() external view returns (uint256);
    function systemColl() external view returns (uint256);
    function systemDebt() external view returns (uint256);
}

/// @notice The auction-house views the gate and the redemption guard read (deployment B).
interface IGateHouseViews {
    function activeAuctions() external view returns (uint256);
}

/// @notice ShutdownModule's `belowCritical` exactly as spec §5.8 writes it, for tests until the
///         ShutdownModule prompt: `live and D > 0 and C · price < CRITICAL_TCR · D`, with
///         `live = activeCount > 0 or (auctionHouse != 0 and activeAuctions > 0)`.
contract MockShutdownGate {
    IGateVaultViews public immutable vaultManager;
    address public immutable auctionHouse;
    uint256 public immutable CRITICAL_TCR;

    constructor(address vaultManager_, address auctionHouse_, uint256 criticalTcr) {
        vaultManager = IGateVaultViews(vaultManager_);
        auctionHouse = auctionHouse_;
        CRITICAL_TCR = criticalTcr;
    }

    function belowCritical(uint256 price) external view returns (bool) {
        bool live = vaultManager.activeCount() > 0
            || (auctionHouse != address(0) && IGateHouseViews(auctionHouse).activeAuctions() > 0);
        uint256 c = vaultManager.systemColl();
        uint256 d = vaultManager.systemDebt();
        return live && d > 0 && c * price < CRITICAL_TCR * d;
    }
}

/// @notice A deployment-B auction house as far as the VaultManager (`totalLot`), the gate
///         (`activeAuctions`) and the redemption guard (`inPurchase`) can see it; settable.
contract MockPurchaseHouse {
    uint256 public totalLot;
    uint256 public activeAuctions;
    bool public inPurchase;

    function set(uint256 totalLot_, uint256 activeAuctions_) external {
        totalLot = totalLot_;
        activeAuctions = activeAuctions_;
    }

    function setInPurchase(bool v) external {
        inPurchase = v;
    }

    /// @dev Mimics §6.8.4: raise `inPurchase`, call the buyer, lower it.
    function buyWithCallback(address who, bytes calldata data) external returns (bool ok, bytes memory ret) {
        inPurchase = true;
        (ok, ret) = who.call(data);
        inPurchase = false;
    }
}
