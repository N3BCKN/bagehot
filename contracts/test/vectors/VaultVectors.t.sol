// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {MockHouseViews, MockLedgerViews, MockWETH} from "../utils/VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The part of every system vector P14 can execute: the leading position operations
///         (open, addCollateral, borrow, repay, close) before the first time warp or non-VaultManager
///         step — ids, list placement from the given hints, and each step's recorded `drift` state
///         (index, normalised debt, supply). The rest of each vector needs interest (P15),
///         redemption (P16), the pool and liquidation (P19–P21) and is replayed from those prompts on
///         and in full by the differential harness (P23).
contract VaultVectorsTest is Test {
    string internal json;
    MockWETH internal weth;
    StableToken internal token;
    MockAggregator internal feed;
    VaultManager internal v;
    SortedPositions internal sorted;

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _s(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _deploy(string memory vp) internal {
        string memory p = string.concat(vp, ".inputs.params");
        uint256 t0 = _u(string.concat(vp, ".inputs.t0"));
        vm.warp(t0);
        bool b = _is(_s(string.concat(vp, ".inputs.variant")), "B");
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(uint8(_u(string.concat(p, ".FEED_DECIMALS"))));
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, t0 - _u(string.concat(p, ".GRACE_PERIOD")) - 1);
        feed.setRound(1, 2000e8, t0);
        OracleAdapter oracle = new OracleAdapter(
            address(feed),
            address(seq),
            _u(string.concat(p, ".STALENESS")),
            _u(string.concat(p, ".GRACE_PERIOD")),
            _u(string.concat(p, ".MIN_PRICE")),
            _u(string.concat(p, ".MAX_PRICE")),
            _u(string.concat(p, ".ORACLE_GAS")),
            _u(string.concat(p, ".ORACLE_POST_FAILURE_GAS"))
        );
        sorted = new SortedPositions(_u(string.concat(p, ".MAX_HINT_STEPS")));
        MockLedgerViews ledger = new MockLedgerViews();
        address strategy = b ? address(new MockHouseViews()) : makeAddr("pool");
        v = new VaultManager(
            address(weth),
            address(token),
            address(oracle),
            _u(string.concat(p, ".MCR")),
            _u(string.concat(p, ".MIN_DEBT")),
            _u(string.concat(p, ".GAS_RESERVE")),
            _u(string.concat(p, ".RATE_PER_SECOND")),
            _u(string.concat(p, ".POOL_SHARE_BPS")),
            200_000
        );
        v.wire(
            address(sorted),
            strategy,
            b ? address(0) : strategy,
            address(0xDE11),
            address(ledger),
            address(0x5D)
        );
        sorted.wire(address(v));
        token.wire(address(v), strategy, address(ledger), address(0x5D));
        string[] memory actors = vm.parseJsonStringArray(json, string.concat(vp, ".inputs.actors"));
        uint256 funds = _u(string.concat(vp, ".inputs.actorWeth"));
        for (uint256 i; i < actors.length; ++i) {
            address a = makeAddr(actors[i]);
            weth.mint(a, funds);
            vm.prank(a);
            weth.approve(address(v), type(uint256).max);
        }
    }

    function _isPositionOp(string memory op) internal pure returns (bool) {
        return _is(op, "open") || _is(op, "addCollateral") || _is(op, "borrow") || _is(op, "repay")
            || _is(op, "close");
    }

    function _setPrice(string memory sp) internal {
        if (vm.keyExistsJson(json, string.concat(sp, ".price"))) {
            feed.setRound(1, int256(_u(string.concat(sp, ".price")) / 1e10), block.timestamp);
        }
    }

    function _step(string memory sp) internal {
        string memory op = _s(string.concat(sp, ".op"));
        assertEq(_u(string.concat(sp, ".t")), block.timestamp, "no time passes in the prefix");
        _setPrice(sp);
        address caller = makeAddr(_s(string.concat(sp, ".caller")));
        vm.startPrank(caller);
        if (_is(op, "open")) {
            uint256 id = v.openPosition(
                _u(string.concat(sp, ".coll")),
                _u(string.concat(sp, ".debt")),
                _u(string.concat(sp, ".upperHint")),
                _u(string.concat(sp, ".lowerHint"))
            );
            assertEq(id, _u(string.concat(sp, ".result.id")), "id");
        } else if (_is(op, "close")) {
            v.close(_u(string.concat(sp, ".id")));
        } else {
            uint256 id = _u(string.concat(sp, ".id"));
            uint256 amt = _u(string.concat(sp, ".amount"));
            uint256 up = _u(string.concat(sp, ".upperHint"));
            uint256 lo = _u(string.concat(sp, ".lowerHint"));
            if (_is(op, "addCollateral")) v.addCollateral(id, amt, up, lo);
            else if (_is(op, "borrow")) v.borrow(id, amt, up, lo);
            else v.repay(id, amt, up, lo);
        }
        vm.stopPrank();
        if (vm.keyExistsJson(json, string.concat(sp, ".drift"))) {
            string memory d = string.concat(sp, ".drift");
            assertEq(v.index(), _u(string.concat(d, ".index")), "drift.index");
            assertEq(v.totalNormDebt(), _u(string.concat(d, ".totalNormDebt")), "drift.totalNormDebt");
            assertEq(token.totalSupply(), _u(string.concat(d, ".totalSupply")), "drift.totalSupply");
        }
    }

    /// @dev Counts are locals: vm.revertToState also rolls back this contract's storage.
    function _replayFile(string memory file) internal returns (uint256 vectors, uint256 steps) {
        json = vm.readFile(string.concat("../spec/vectors/", file));
        for (uint256 i; vm.keyExistsJson(json, string.concat(".vectors[", vm.toString(i), "]")); ++i) {
            string memory vp = string.concat(".vectors[", vm.toString(i), "]");
            if (!_is(_s(string.concat(vp, ".level")), "system")) continue;
            uint256 snap = vm.snapshotState();
            _deploy(vp);
            for (uint256 j; vm.keyExistsJson(json, string.concat(vp, ".steps[", vm.toString(j), "]")); ++j) {
                string memory sp = string.concat(vp, ".steps[", vm.toString(j), "]");
                if (!_isPositionOp(_s(string.concat(sp, ".op")))) break;
                _step(sp);
                ++steps;
            }
            vm.revertToState(snap);
            ++vectors;
        }
    }

    function test_vectors_positionPrefixes() public {
        string[7] memory files = [
            "auction.json",
            "deficit.json",
            "drift.json",
            "liquidation_pool.json",
            "product_sum.json",
            "redemption.json",
            "redistribution.json"
        ];
        uint256 vectors;
        uint256 steps;
        for (uint256 f; f < files.length; ++f) {
            (uint256 nv, uint256 ns) = _replayFile(files[f]);
            vectors += nv;
            steps += ns;
        }
        assertEq(vectors, 23, "every system vector visited");
        assertEq(steps, 61, "every leading position step replayed");
    }
}
