// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {Test} from "forge-std/Test.sol";

/// @notice OracleAdapter against spec/vectors/oracle.json (protected, normative): every row of the
///         §6.10.1 table, its boundaries, overflow-safe scaling and the lazy read. A `null` feed is
///         a failed call (a reverting mock); a price of "0" means "no price".
contract OracleVectorsTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("../spec/vectors/oracle.json");
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _i(string memory path) internal view returns (int256) {
        return vm.parseInt(vm.parseJsonString(json, path));
    }

    /// @dev The reason names of oracle.json mapped to the ABI values of spec §11.1.
    function _reasonOf(string memory name) internal pure returns (uint8) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("OK")) return 0;
        if (h == keccak256("SEQUENCER_CALL_FAILED")) return 1;
        if (h == keccak256("SEQUENCER_DOWN")) return 2;
        if (h == keccak256("SEQUENCER_INVALID")) return 3;
        if (h == keccak256("GRACE_PERIOD")) return 4;
        if (h == keccak256("PRICE_CALL_FAILED")) return 5;
        if (h == keccak256("NON_POSITIVE")) return 6;
        if (h == keccak256("INVALID_TIMESTAMP")) return 7;
        if (h == keccak256("STALE")) return 8;
        if (h == keccak256("OUT_OF_BOUNDS")) return 9;
        revert(string.concat("unknown reason ", name));
    }

    string internal constant LAZY = "lazy_sequencer_down_price_feed_failing";

    function _base(uint256 v) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(v), "]");
    }

    function _name(uint256 v) internal view returns (string memory) {
        return vm.parseJsonString(json, string.concat(_base(v), ".name"));
    }

    function test_vectors_oracle() public {
        uint256 n;
        for (; vm.keyExistsJson(json, _base(n)); ++n) {
            if (keccak256(bytes(_name(n))) == keccak256(bytes(LAZY))) continue; // own test below
            uint256 snap = vm.snapshotState();
            (OracleAdapter oracle,) = _setup(n);
            _expect(n, oracle);
            vm.revertToState(snap);
        }
        assertEq(n, 20, "all oracle vectors read");
    }

    /// @dev The lazy vector: with the sequencer down, the failing price feed is never called.
    function test_vectors_oracle_lazyRead() public {
        uint256 v = 19;
        assertEq(_name(v), LAZY);
        (OracleAdapter oracle, MockAggregator feed) = _setup(v);
        vm.expectCall(address(feed), abi.encodeCall(AggregatorV3Interface.latestRoundData, ()), 0);
        _expect(v, oracle);
    }

    function _setup(uint256 v) internal returns (OracleAdapter oracle, MockAggregator feed) {
        string memory inp = string.concat(_base(v), ".inputs");
        vm.warp(_u(string.concat(inp, ".now")));
        feed = new MockAggregator(uint8(_u(string.concat(inp, ".params.FEED_DECIMALS"))));
        MockSequencerFeed seq = new MockSequencerFeed();
        oracle = new OracleAdapter(
            address(feed),
            address(seq),
            _u(string.concat(inp, ".params.STALENESS")),
            _u(string.concat(inp, ".params.GRACE_PERIOD")),
            _u(string.concat(inp, ".params.MIN_PRICE")),
            _u(string.concat(inp, ".params.MAX_PRICE")),
            100_000,
            1588
        );
        if (vm.keyExistsJson(json, string.concat(inp, ".sequencer.answer"))) {
            seq.setStatus(
                _i(string.concat(inp, ".sequencer.answer")), _u(string.concat(inp, ".sequencer.startedAt"))
            );
        } else {
            seq.setMode(MockAggregator.Mode.Revert); // null: failed call
        }
        if (vm.keyExistsJson(json, string.concat(inp, ".priceFeed.answer"))) {
            feed.setRound(
                1, _i(string.concat(inp, ".priceFeed.answer")), _u(string.concat(inp, ".priceFeed.updatedAt"))
            );
        } else {
            feed.setMode(MockAggregator.Mode.Revert); // null: failed call
        }
    }

    function _expect(uint256 v, OracleAdapter oracle) internal {
        string memory e = string.concat(_base(v), ".expected");
        string memory name = _name(v);
        bool expUsable = vm.parseJsonBool(json, string.concat(e, ".usable"));
        uint256 expPrice = _u(string.concat(e, ".price"));
        (uint256 p, bool usable, OracleAdapter.Reason reason) = oracle.peek();
        assertEq(usable, expUsable, name);
        assertEq(uint8(reason), _reasonOf(vm.parseJsonString(json, string.concat(e, ".reason"))), name);
        assertEq(usable ? p : 0, expPrice, name); // "0" = no price
        (uint256 fp, bool fu) = oracle.fetchPrice();
        assertEq(fu, expUsable, name);
        assertEq(fu ? fp : 0, expPrice, name);
    }
}
