// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    IAuctionHousePurchaseState,
    IAuctionHouseViews,
    IStabilityPoolInterest
} from "../interfaces/ISystemViews.sol";

/// @title StandInStrategy
/// @notice LOCAL ONLY. Occupies the strategy role (StabilityPool in A, DutchAuctionHouse in B) until
///         those contracts exist (P19, P33), answering exactly what the VaultManager, the
///         RedemptionModule and the shutdown gate read: an empty pool that takes no interest
///         (`acceptsInterest() == false`, §6.6.5, so accrual routes everything to the reserve), and
///         an auction house with no lot, no auction and no buyer callback. It holds no funds and
///         makes no calls. It has no `onLiquidation`: once P20 adds liquidation, liquidations in a
///         local deployment revert until P19/P33 replace it. Deploys on chain 31337 only.
contract StandInStrategy is IStabilityPoolInterest, IAuctionHousePurchaseState, IAuctionHouseViews {
    /// @notice `onInterest` reached, which accrual never does while `acceptsInterest()` is false.
    error StandInNoPool();

    /// @notice Deployed outside chain 31337.
    error StandInLocalOnly();

    constructor() {
        if (block.chainid != 31_337) revert StandInLocalOnly();
    }

    /// @notice An empty pool: below MIN_DEPOSIT, so it takes no interest share (§6.6.5).
    function acceptsInterest() external pure returns (bool) {
        return false;
    }

    /// @notice Never reached: accrual calls it only after `acceptsInterest()` returned true.
    function onInterest(uint256) external pure {
        revert StandInNoPool();
    }

    /// @notice No buyer callback ever runs (§6.8.4).
    function inPurchase() external pure returns (bool) {
        return false;
    }

    /// @notice No collateral is ever under auction (§4.5).
    function totalLot() external pure returns (uint256) {
        return 0;
    }

    /// @notice No auction is ever live (§5.8).
    function activeAuctions() external pure returns (uint256) {
        return 0;
    }
}
