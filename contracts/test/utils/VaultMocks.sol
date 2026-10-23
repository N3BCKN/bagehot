// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain WETH stand-in for tests: an ERC-20 anyone can mint.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether (test)", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The DeficitLedger views the VaultManager reads (§5.1.12), settable.
contract MockLedgerViews {
    uint256 public recoveredColl;
    uint256 public auctionDebt;
    uint256 public deficit;

    function set(uint256 recoveredColl_, uint256 auctionDebt_, uint256 deficit_) external {
        recoveredColl = recoveredColl_;
        auctionDebt = auctionDebt_;
        deficit = deficit_;
    }
}

/// @notice The DutchAuctionHouse view the VaultManager reads in deployment B, settable.
contract MockHouseViews {
    uint256 public totalLot;

    function set(uint256 totalLot_) external {
        totalLot = totalLot_;
    }
}
