// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BurnAggregator} from "../utils/BurnAggregator.sol";
import {OracleAdapterHarness} from "../utils/OracleAdapterHarness.sol";
import {Test, console} from "forge-std/Test.sol";

interface IEACAggregatorProxy {
    function aggregator() external view returns (address);
}

/// @notice CHG-004 on Base's real Chainlink proxy (fork at P09 calm block 45,198,666): the proxy's
///         deployed bytecode is kept; only the aggregator behind it is replaced (vm.etch) by an
///         honest but expensive one, the only way to starve it — the real aggregator's cold read
///         costs ~19k. Measures the gas a starved read actually leaves the adapter, and runs the
///         adversarial sweep (permanent regression for ADR-0030). Run with `just test-fork`.
contract OracleGasRuleForkTest is Test {
    uint256 internal constant BLOCK = 45_198_666;

    AggregatorV3Interface internal proxy;
    AggregatorV3Interface internal sequencer;
    address internal aggregatorAddr;

    function _fork() internal {
        if (bytes(vm.envOr("BASE_ARCHIVE_RPC", string(""))).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork("base", BLOCK);
        string memory cfg = vm.readFile("../config/8453.toml");
        proxy = AggregatorV3Interface(vm.parseTomlAddress(cfg, ".oracle.eth_usd.proxy"));
        sequencer = AggregatorV3Interface(vm.parseTomlAddress(cfg, ".oracle.sequencer_uptime.proxy"));
        aggregatorAddr = IEACAggregatorProxy(address(proxy)).aggregator();
    }

    function _expensive(uint256 need) internal {
        BurnAggregator b = new BurnAggregator(need, 2330e8, block.timestamp - 60);
        vm.etch(aggregatorAddr, address(b).code);
    }

    function _floor1(uint256 cap) internal pure returns (uint256) {
        return (cap + 62) / 63; // ceil(cap / 63): the pre-CHG-004 floor (ADR-0024), for comparison
    }

    function _floor2(uint256 cap) internal pure returns (uint256) {
        return (2 * cap + 62) / 63; // ceil(2·cap / 63): the floor since CHG-004 (ADR-0030)
    }

    /// @dev Largest gas left after a *starved* read, over every caller limit just below the edge
    ///      where the read starts to succeed (the leftover grows with the forwarded gas, so the
    ///      maximum sits at the edge).
    function _maxLeftAfterStarvedRead(OracleAdapterHarness h)
        internal
        view
        returns (uint256 maxLeft, uint256 edge)
    {
        uint256 lo = 10_000;
        uint256 hi = 3_000_000;
        while (lo < hi) {
            uint256 m = (lo + hi) / 2; // gas limits: plain integer bisection
            (bool success, bytes memory ret) =
                address(h).staticcall{gas: m}(abi.encodeCall(h.measuredRead, (proxy)));
            bool ok = success && abi.decode(ret, (bool));
            if (ok) hi = m;
            else lo = m + 1;
        }
        edge = lo;
        require(edge < hi + 1 && edge < 3_000_000, "the feed must be readable with ample gas");
        for (uint256 g = edge - 600; g < edge; ++g) {
            (bool success, bytes memory ret) =
                address(h).staticcall{gas: g}(abi.encodeCall(h.measuredRead, (proxy)));
            if (!success) continue;
            (bool ok, uint256 left) = abi.decode(ret, (bool, uint256));
            if (!ok && left > maxLeft) maxLeft = left;
        }
    }

    /// @dev The assumption behind ADR-0024 / spec §6.10.3, tested on the real proxy: after a
    ///      starved read the adapter must hold less than the floor. ceil(cap/63) fails it; the
    ///      CHG-004 floor ceil(2·cap/63) holds, with a margin for the harness's late gasleft().
    function test_fork_realProxyRefund_exceedsTheOldFloor_staysUnderTheNew() public {
        _fork();
        uint256[2] memory caps = [uint256(100_000), 1_000_000];
        for (uint256 i; i < 2; ++i) {
            uint256 cap = caps[i];
            // the feed needs 90 % of the cap: the most a real proxied read can need and still
            // succeed with ample gas (the proxy's own work and its kept 1/64 come out of the cap)
            _expensive(cap * 9 / 10);
            OracleAdapterHarness h =
                new OracleAdapterHarness(address(proxy), address(sequencer), cap, _floor2(cap));
            (uint256 maxLeft, uint256 edge) = _maxLeftAfterStarvedRead(h);
            console.log("cap", cap);
            console.log("  edge (caller gas)", edge);
            console.log("  max gas left after a starved read", maxLeft);
            console.log("  old floor / new floor", _floor1(cap), _floor2(cap));
            assertGe(maxLeft, _floor1(cap), "the real proxy hands back gas: the old floor is crossed");
            assertLt(maxLeft + 100, _floor2(cap), "the new floor holds, with 100 gas for the harness");
        }
    }

    function _forged(OracleAdapter o, uint256 from, uint256 to, uint256 step)
        internal
        returns (uint256 forged)
    {
        for (uint256 g = from; g <= to; g += step) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) =
                address(o).call{gas: g}(abi.encodeCall(OracleAdapter.fetchPrice, ()));
            vm.revertToState(snap);
            if (ok) {
                (, bool usable) = abi.decode(ret, (uint256, bool));
                if (!usable) ++forged;
            }
        }
    }

    function _adapter(uint256 cap, uint256 post) internal returns (OracleAdapter) {
        return
            new OracleAdapter(address(proxy), address(sequencer), 3600, 3600, 10e18, 1_000_000e18, cap, post);
    }

    /// @dev Permanent regression on the real proxy (ADR-0030): ORACLE_GAS = 1M, feed needing 900k, no
    ///      caller gas limit forges a recorded failure at the floor. (Before CHG-004, at 15,874, 789
    ///      of these 825 limits did; that floor can no longer be deployed.)
    function test_fork_adversarialSweep_cap1M_newFloorHolds() public {
        _fork();
        _expensive(900_000);
        uint256 forged = _forged(_adapter(1_000_000, _floor2(1_000_000)), 880_000, 960_000, 97);
        console.log("cap 1M, new floor 31,747: forged recorded failures", forged);
        assertEq(forged, 0);
    }

    /// @dev At the start parameters (ORACLE_GAS 100k, floor 3,175), feeds needing 50k … 95k: no forgery.
    function test_fork_adversarialSweep_startParameters() public {
        _fork();
        uint256 forged;
        for (uint256 need = 50_000; need <= 95_000; need += 15_000) {
            _expensive(need);
            forged += _forged(_adapter(100_000, _floor2(100_000)), 40_000, 140_000, 41);
        }
        console.log("cap 100k, floor 3,175: forged recorded failures", forged);
        assertEq(forged, 0);
    }
}
