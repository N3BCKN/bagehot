// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Exposes `_readFeed` with memory already in use, to check ADR-0029's memory-safety
///         property without assembly in the test: data allocated before the read must be intact
///         after it, and memory allocated after it must behave normally.
contract OracleAdapterHarness is OracleAdapter {
    constructor(address priceFeed_, address sequencerFeed_)
        OracleAdapter(priceFeed_, sequencerFeed_, 3600, 3600, 10e18, 1_000_000e18, 100_000, 1588)
    {}

    function readFeedKeepsMemory(AggregatorV3Interface feed)
        external
        view
        returns (bool ok, int256 answer, bool before, bool afterwards)
    {
        bytes memory sentinel = abi.encode(uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE), uint256(0xF00D));
        bytes32 h = keccak256(sentinel);
        (ok, answer,,) = _readFeed(feed, false);
        before = keccak256(sentinel) == h;
        bytes memory fresh = abi.encode(uint256(7), uint256(8)); // allocated over the scratch buffer
        afterwards = fresh.length == 64 && abi.decode(fresh, (uint256)) == 7 && keccak256(sentinel) == h;
    }
}
