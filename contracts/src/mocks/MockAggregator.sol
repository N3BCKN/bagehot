// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title MockAggregator
/// @notice TEST ONLY. A Chainlink-shaped price feed whose every field is set directly, with modes
///         that make a read revert or run out of the gas the caller forwarded (spec §6.10.1).
///         Non-ABI output — fewer than 160 bytes, junk in the `uint80` words, huge return or
///         revert data — comes from `RawFeed`, which needs no assembly (ADR-0029).
/// @dev Excluded from coverage, static analysis and invariants. Setters are permissionless.
contract MockAggregator is AggregatorV3Interface {
    enum Mode {
        Normal, // return the stored round
        Revert, // every read (including `decimals`) reverts MockFeedReverted()
        BurnGas // burn `gasToBurn` before returning; more than the forwarded gas = out of gas
    }

    uint8 internal immutable _decimals;

    Mode public mode;
    uint256 public gasToBurn;

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    error MockFeedReverted();

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    /// @notice Sets the round returned by every read; `startedAt = updatedAt`.
    function setRound(uint80 roundId_, int256 answer_, uint256 updatedAt_) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
    }

    /// @notice Sets the answer at the current timestamp and advances the round id.
    function setAnswer(int256 answer_) external {
        roundId += 1;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setGasToBurn(uint256 gasToBurn_) external {
        gasToBurn = gasToBurn_;
    }

    function decimals() external view override returns (uint8) {
        if (mode == Mode.Revert) revert MockFeedReverted();
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockAggregator (test only)";
    }

    function version() external pure override returns (uint256) {
        return 0;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return _read();
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return _read();
    }

    function _read() internal view returns (uint80, int256, uint256, uint256, uint80) {
        Mode m = mode;
        if (m == Mode.Revert) revert MockFeedReverted();
        if (m == Mode.BurnGas) {
            // one gasleft() read: two reads could straddle gasToBurn and underflow (a Panic would
            // turn this "honest but expensive" feed into a fast-reverting one)
            uint256 g = gasleft();
            uint256 stop = g > gasToBurn ? g - gasToBurn : 0;
            while (gasleft() > stop) {}
        }
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}
