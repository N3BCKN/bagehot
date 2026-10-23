// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared set-up for the OracleAdapter tests: start parameters of spec §3.1, an 8-decimal
///         price feed and a sequencer that has been up for longer than the grace period.
abstract contract OracleFixture is Test {
    uint256 internal constant NOW = 10_000_000;
    uint256 internal constant STALENESS = 3600;
    uint256 internal constant GRACE = 3600;
    uint256 internal constant MIN_PRICE = 10e18;
    uint256 internal constant MAX_PRICE = 1_000_000e18;
    uint256 internal constant ORACLE_GAS = 100_000;
    uint256 internal constant POST_GAS = 3175; // ceil(2 * 100_000 / 63), ADR-0030
    int256 internal constant ANSWER = 2000e8;

    MockAggregator internal feed;
    MockSequencerFeed internal seq;
    OracleAdapter internal oracle;

    function setUp() public virtual {
        vm.warp(NOW);
        feed = new MockAggregator(8);
        seq = new MockSequencerFeed();
        seq.setStatus(0, NOW - 100_000);
        feed.setRound(1, ANSWER, NOW - 60);
        oracle = _deploy(address(feed), address(seq));
    }

    function _deploy(address priceFeed, address sequencerFeed) internal returns (OracleAdapter) {
        return new OracleAdapter(
            priceFeed, sequencerFeed, STALENESS, GRACE, MIN_PRICE, MAX_PRICE, ORACLE_GAS, POST_GAS
        );
    }

    function _reason(OracleAdapter.Reason r) internal pure returns (uint8) {
        return uint8(r);
    }
}
