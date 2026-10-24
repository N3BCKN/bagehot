// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISortKeySource} from "./ISortKeySource.sol";

/// @notice The VaultManager views HintHelpers reads to simulate a redemption (spec §5.1.12, §6.7.3).
interface IRedemptionViews is ISortKeySource {
    function MCR() external view returns (uint256);
    function MIN_DEBT() external view returns (uint256);
    function currentIndex() external view returns (uint256);
}
