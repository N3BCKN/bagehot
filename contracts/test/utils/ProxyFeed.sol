// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice The shape of Chainlink's EACAggregatorProxy: a high-level call into the aggregator,
///         which forwards all but 1/64 of the gas and bubbles a revert up. When the inner call
///         starves, the proxy hands back the 1/64 it kept — the effect behind CHG-004.
contract ProxyFeed {
    AggregatorV3Interface public immutable aggregator;

    constructor(AggregatorV3Interface aggregator_) {
        aggregator = aggregator_;
    }

    function decimals() external view returns (uint8) {
        return aggregator.decimals();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return aggregator.latestRoundData();
    }
}
