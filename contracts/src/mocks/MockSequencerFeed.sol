// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockAggregator} from "./MockAggregator.sol";

/// @title MockSequencerFeed
/// @notice TEST ONLY. Chainlink's L2 sequencer uptime feed: `answer` 0 = up, 1 = down, and
///         `startedAt` = when the status last changed (spec §6.10.1 rows 1–4). Inherits the
///         failure modes of MockAggregator, so a sequencer read can also revert, run out of gas
///         or return short data.
contract MockSequencerFeed is MockAggregator {
    constructor() MockAggregator(0) {}

    /// @notice Sets the status and the time it changed. Any `answer` is accepted, so a test can
    ///         also feed values other than 0 and 1 (§6.10.1 treats every non-zero as down).
    function setStatus(int256 answer_, uint256 startedAt_) external {
        roundId += 1;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = startedAt_;
    }
}
