// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {OracleFixture} from "../utils/OracleFixture.sol";
import {ProxyFeed} from "../utils/ProxyFeed.sol";

/// @notice Gas griefing (spec §6.10.3, threat T-03): a caller who starves a feed call through the
///         63/64 rule must never make an honest feed look failed. Two separate sweeps — the
///         sequencer call, and the price call that runs on what the first call left — each at
///         step 1 around both edges where the outcome changes, and with a coarse pass (step 97)
///         over every limit from 1k to past the first usable one.
/// @dev The honest feed is a MockAggregator in BurnGas mode: it needs `NEED` gas, then answers
///      correctly. For every limit the outcome must be a usable price, or a revert that leaves the
///      failure clock untouched. "Unusable" with `failureStart` set is the forbidden outcome.
contract OracleAdapterGasTest is OracleFixture {
    uint256 internal constant NEED = 60_000;

    struct Tally {
        uint256 usable;
        uint256 insufficientGas;
        uint256 otherRevert;
    }

    function _try(uint256 g) internal returns (bool ok, bool usable, bytes4 err) {
        bytes memory ret;
        (ok, ret) = address(oracle).call{gas: g}(abi.encodeCall(OracleAdapter.fetchPrice, ()));
        if (ok) {
            (, usable) = abi.decode(ret, (uint256, bool));
        } else if (ret.length >= 4) {
            err = bytes4(ret);
        }
    }

    /// @dev Smallest limit in [lo, hi] for which `pred` turns true; outcomes are monotone in the limit.
    function _bisect(uint256 lo, uint256 hi, bool wantUsable) internal returns (uint256) {
        while (lo < hi) {
            uint256 m = (lo + hi) / 2; // gas limits, not protocol amounts: plain integer bisection
            (bool ok,, bytes4 err) = _try(m);
            bool hit = wantUsable ? ok : (ok || err != OracleAdapter.InsufficientGasForOracle.selector);
            if (hit) hi = m;
            else lo = m + 1;
        }
        return lo;
    }

    /// @dev Two edges: `fed` — the first limit at which the starving feed call stops tripping the
    ///      gas rule (the 63/64 crossing) — and `usable` — the first limit that returns a price. Between
    ///      them the adapter's own frame runs out of gas (a safe, empty revert that consumes the whole
    ///      limit). A coarse pass (step 97) covers 1k … usable + 2k; step 1 covers ±6k around `fed`
    ///      and −2k … +2k around `usable`.
    function _sweepAll() internal returns (Tally memory t) {
        uint256 usable = _bisect(1000, 400_000, true);
        uint256 fed = _bisect(1000, usable, false);
        for (uint256 g = 1000; g < usable + 2000; g += 97) {
            _record(t, g);
        }
        for (uint256 g = fed > 6000 ? fed - 6000 : 1000; g <= fed + 6000; ++g) {
            _record(t, g);
        }
        for (uint256 g = usable - 2000; g <= usable + 2000; ++g) {
            _record(t, g);
        }
    }

    function _record(Tally memory t, uint256 g) internal {
        (bool ok, bool usable, bytes4 err) = _try(g);
        if (ok) {
            // the forbidden outcome: an honest feed reported as failed
            assertTrue(usable, string.concat("honest feed reported unusable at gas ", vm.toString(g)));
            ++t.usable;
        } else if (err == OracleAdapter.InsufficientGasForOracle.selector) {
            ++t.insufficientGas;
        } else {
            ++t.otherRevert;
        }
        assertEq(oracle.failureStart(), 0, "a revert never starts the failure clock");
    }

    function test_sweep_sequencerCallStarvation() public {
        seq.setMode(MockAggregator.Mode.BurnGas);
        seq.setGasToBurn(NEED);
        Tally memory t = _sweepAll();
        assertGt(t.insufficientGas, 0, "the sweep reached the starvation band");
        assertGt(t.otherRevert, 0, "and the adapter-out-of-gas band");
        assertGt(t.usable, 0, "and the usable band");
    }

    function test_sweep_priceCallStarvation() public {
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(NEED);
        Tally memory t = _sweepAll();
        assertGt(t.insufficientGas, 0, "the sweep reached the starvation band");
        assertGt(t.otherRevert, 0, "and the adapter-out-of-gas band");
        assertGt(t.usable, 0, "and the usable band");
    }

    /// @dev The same price-call sweep with the sequencer also expensive, so the second call starts
    ///      with as little as the first leaves.
    function test_sweep_priceCallStarvationAfterAnExpensiveSequencer() public {
        seq.setMode(MockAggregator.Mode.BurnGas);
        seq.setGasToBurn(30_000);
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(NEED);
        Tally memory t = _sweepAll();
        assertGt(t.insufficientGas, 0, "the sweep reached the starvation band");
        assertGt(t.otherRevert, 0, "and the adapter-out-of-gas band");
        assertGt(t.usable, 0, "and the usable band");
    }

    /// @dev Real Chainlink feeds are proxies. At the start parameters (ORACLE_GAS 100k, POST 1,588)
    ///      a proxied price feed cannot be forged into a recorded failure: the proxy's returned
    ///      1/64 brings the adapter to at most ~2·ORACLE_GAS/63 ≈ 3.2k after a starved call, far
    ///      below the ~22k needed to write `failureStart`. At ORACLE_GAS near 1M it can — CHG-004.
    function test_sweep_proxiedPriceFeedAtTheStartParameters() public {
        oracle = _deploy(address(new ProxyFeed(AggregatorV3Interface(address(feed)))), address(seq));
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(NEED);
        Tally memory t = _sweepAll();
        assertGt(t.insufficientGas, 0, "the sweep reached the starvation band");
        assertGt(t.usable, 0, "and the usable band");
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

    function _proxiedAdapter(uint256 cap, uint256 post, uint256 need) internal returns (OracleAdapter) {
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(need);
        return new OracleAdapter(
            address(new ProxyFeed(AggregatorV3Interface(address(feed)))),
            address(seq),
            STALENESS,
            GRACE,
            MIN_PRICE,
            MAX_PRICE,
            cap,
            post
        );
    }

    /// @dev Permanent regression for ADR-0030 (the CHG-004 sweep): a proxied feed needing 900k at
    ///      ORACLE_GAS = 1M, the floor ceil(2·1M/63) = 31,747 — no caller gas limit forges a recorded
    ///      failure. (At the old floor 15,874 every one of 1,601 limits did; it can no longer be
    ///      deployed.) The same sweep on Base's real proxy bytecode: OracleGasRuleForkTest.
    function test_regression_proxiedFeed_cap1M_noForgery() public {
        OracleAdapter o = _proxiedAdapter(1_000_000, 31_747, 900_000);
        assertEq(_forged(o, 880_000, 960_000, 97), 0);
    }

    /// @dev … and at the start parameters (ORACLE_GAS 100k, floor 3,175), feeds needing 50k … 95k.
    function test_regression_proxiedFeed_startParameters_noForgery() public {
        uint256 forged;
        for (uint256 need = 50_000; need <= 95_000; need += 15_000) {
            forged += _forged(_proxiedAdapter(ORACLE_GAS, POST_GAS, need), 40_000, 140_000, 41);
        }
        assertEq(forged, 0);
    }
}
