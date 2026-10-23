// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Chainlink's AggregatorV3Interface, written out to avoid a dependency on the Chainlink
///         package (docs/dependencies.md). Same selectors and return layout: `latestRoundData` and
///         `getRoundData` return 5 words (160 bytes), the size spec §6.10.1 requires of a feed read.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
