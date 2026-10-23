// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {Test} from "forge-std/Test.sol";

/// @notice OracleAdapter against the real Chainlink ETH/USD and sequencer-uptime feeds on Base
///         mainnet (read-only fork), at a pinned calm block from P09's selection
///         (`data/cards/blocks_selected.md`: calm rank 8, 2026-04-26 06:58 UTC). Addresses come from
///         `config/8453.toml`. Skipped when BASE_ARCHIVE_RPC is unset (CI has none).
contract OracleAdapterForkTest is Test {
    uint256 internal constant BLOCK = 45_198_666;
    /// @dev Coinbase ETH-USD close at that minute (P09 card): context, not the oracle's own value.
    uint256 internal constant COINBASE_CLOSE = 2330.83e18;

    function test_fork_realFeedsAreUsableAndScaledExactly() public {
        if (bytes(vm.envOr("BASE_ARCHIVE_RPC", string(""))).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork("base", BLOCK);

        string memory cfg = vm.readFile("../config/8453.toml");
        address priceFeed = vm.parseTomlAddress(cfg, ".oracle.eth_usd.proxy");
        address sequencerFeed = vm.parseTomlAddress(cfg, ".oracle.sequencer_uptime.proxy");

        OracleAdapter oracle =
            new OracleAdapter(priceFeed, sequencerFeed, 3600, 3600, 10e18, 1_000_000e18, 100_000, 3175);
        assertEq(oracle.FEED_DECIMALS(), 8, "Base ETH/USD has 8 decimals");

        (, int256 seqAnswer, uint256 startedAt,,) = AggregatorV3Interface(sequencerFeed).latestRoundData();
        assertEq(seqAnswer, 0, "sequencer up");
        assertGt(block.timestamp - startedAt, 3600, "past the grace period");

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();
        assertLe(block.timestamp - updatedAt, 3600, "fresh: the feed's heartbeat is 1,200 s");

        (uint256 p, bool usable, OracleAdapter.Reason reason) = oracle.peek();
        assertTrue(usable);
        assertEq(uint8(reason), 0);
        assertEq(p, uint256(answer) * 1e10, "answer scaled to WAD exactly");

        (uint256 fp, bool fu) = oracle.fetchPrice();
        assertTrue(fu);
        assertEq(fp, p);
        assertEq(oracle.lastGoodPrice(), p);

        // within 2 % of the exchange price at that minute: the feed is the one we think it is
        assertApproxEqRel(p, COINBASE_CLOSE, 0.02e18, "near Coinbase close");
    }
}
