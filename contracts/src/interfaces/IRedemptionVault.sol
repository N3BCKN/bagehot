// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What the RedemptionModule calls on the VaultManager (spec §5.1.8, §5.1.9, §6.7.2).
interface IRedemptionVault {
    function shutdown() external view returns (bool);
    function accrue() external;
    function redeemCollateral(
        address redeemer,
        uint256 amount,
        uint256 feeRate,
        uint256 price,
        uint256 maxIterations,
        uint256 upperHint,
        uint256 lowerHint
    ) external returns (uint256 redeemed, uint256 collSent, uint256 iterations);
}
