// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {PoolFixture} from "../utils/PoolFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The two unit vectors of `product_sum.json` (`sequence`, `dust_sweep`) against the real pool
///         behind the test VaultManager: every step's result, the pool's full state and every
///         depositor's views after each step, and the expected end state. The system vector
///         `deposit_after_idle_gets_no_back_interest` runs in `ProductSumSystemVectorTest`. The Python
///         model runs the same vectors in tests/model/test_stability_pool_model.py.
contract ProductSumVectorsTest is PoolFixture {
    string internal json;

    function setUp() public {
        json = vm.readFile("../spec/vectors/product_sum.json");
    }

    function test_vector_sequence() public {
        _run(0, "sequence");
    }

    function test_vector_dustSweep() public {
        _run(1, "dust_sweep");
    }

    // ------------------------------------------------------------------ replay

    function _run(uint256 i, string memory name) internal {
        string memory vp = string.concat(".vectors[", vm.toString(i), "]");
        assertEq(_s(string.concat(vp, ".name")), name, "vector order");
        _deployPool(MIN_DEPOSIT);
        if (_has(string.concat(vp, ".inputs.params"))) _checkParams(string.concat(vp, ".inputs.params"));
        string memory bp = string.concat(vp, ".inputs.stablecoinBalances");
        string[] memory actors = vm.parseJsonKeys(json, bp);
        for (uint256 k; k < actors.length; ++k) {
            _fund(makeAddr(actors[k]), _u(string.concat(bp, ".", actors[k])));
        }
        uint256 n = _count(string.concat(vp, ".steps"));
        for (uint256 j; j < n; ++j) {
            string memory sp = string.concat(vp, ".steps[", vm.toString(j), "]");
            _step(sp);
            if (_has(string.concat(sp, ".after"))) _checkState(string.concat(sp, ".after"));
        }
        _checkExpected(string.concat(vp, ".expected"));
    }

    function _step(string memory sp) internal {
        string memory op = _s(string.concat(sp, ".op"));
        if (_is(op, "hook.offset")) {
            tv.offset(_u(string.concat(sp, ".debt")), _u(string.concat(sp, ".coll")));
        } else if (_is(op, "hook.onInterest")) {
            assertTrue(tv.interest(_u(string.concat(sp, ".amount"))), "booked");
        } else if (_is(op, "deposit") || _is(op, "withdraw")) {
            _depositorStep(sp, _is(op, "deposit"));
        } else {
            revert(string.concat("unknown op ", op));
        }
    }

    function _depositorStep(string memory sp, bool isDeposit) internal {
        address a = makeAddr(_s(string.concat(sp, ".caller")));
        uint256 amount = _u(string.concat(sp, ".amount"));
        string memory r = string.concat(sp, ".result");
        bool hasResult = _has(r);
        if (hasResult) {
            assertEq(pool.compoundedDeposit(a), _u(string.concat(r, ".compoundedBefore")), "before");
        }
        uint256 stableBefore = token.balanceOf(a);
        uint256 reserveBefore = ledger.reserve();
        vm.recordLogs();
        if (isDeposit) _deposit(a, amount);
        else _withdraw(a, amount);
        (uint256 collPaid, uint256 interestPaid, uint256 swept) = _logs(vm.getRecordedLogs(), a);
        assertEq(ledger.reserve() - reserveBefore, swept, "sweep reaches the reserve");
        if (!hasResult) return;
        assertEq(collPaid, _u(string.concat(r, ".collGainPaid")), "collGainPaid");
        assertEq(interestPaid, _u(string.concat(r, ".interestGainPaid")), "interestGainPaid");
        (uint256 initial,,,,,) = pool.deposits(a);
        assertEq(initial, _u(string.concat(r, ".deposit")), "deposit");
        if (isDeposit) {
            assertEq(stableBefore + interestPaid - token.balanceOf(a), amount, "deposit pulled");
        } else {
            uint256 w = _u(string.concat(r, ".withdrawn"));
            assertEq(token.balanceOf(a) - stableBefore, w + interestPaid, "withdrawn");
            assertEq(swept, _u(string.concat(r, ".dustSwept")), "dustSwept");
        }
    }

    /// @dev GainsPaid's amounts for `a` and PoolDustSwept's amount (0 if absent).
    function _logs(Vm.Log[] memory logs, address a)
        internal
        pure
        returns (uint256 collPaid, uint256 interestPaid, uint256 swept)
    {
        bool sawGains;
        for (uint256 k; k < logs.length; ++k) {
            bytes32 t0 = logs[k].topics[0];
            if (t0 == StabilityPool.GainsPaid.selector) {
                assertEq(address(uint160(uint256(logs[k].topics[1]))), a, "GainsPaid depositor");
                (collPaid, interestPaid) = abi.decode(logs[k].data, (uint256, uint256));
                sawGains = true;
            } else if (t0 == StabilityPool.PoolDustSwept.selector) {
                swept = abi.decode(logs[k].data, (uint256));
            }
        }
        assertTrue(sawGains, "GainsPaid emitted");
    }

    // ------------------------------------------------------------------ state checks

    function _checkParams(string memory p) internal view {
        assertEq(pool.MIN_DEPOSIT(), _u(string.concat(p, ".MIN_DEPOSIT")), "MIN_DEPOSIT");
        assertEq(pool.P_PRECISION(), _u(string.concat(p, ".P_PRECISION")), "P_PRECISION");
        assertEq(pool.SCALE_FACTOR(), _u(string.concat(p, ".SCALE_FACTOR")), "SCALE_FACTOR");
        assertEq(pool.DECIMAL_PRECISION(), _u(string.concat(p, ".DECIMAL_PRECISION")), "DECIMAL_PRECISION");
    }

    function _checkState(string memory a) internal {
        assertEq(pool.totalDeposits(), _u(string.concat(a, ".totalDeposits")), "totalDeposits");
        assertEq(pool.P(), _u(string.concat(a, ".P")), "P");
        assertEq(pool.currentScale(), _u(string.concat(a, ".currentScale")), "currentScale");
        assertEq(pool.currentEpoch(), _u(string.concat(a, ".currentEpoch")), "currentEpoch");
        _checkSums(string.concat(a, ".S"), true);
        _checkSums(string.concat(a, ".G"), false);
        assertEq(pool.lastCollError(), _u(string.concat(a, ".lastCollError")), "lastCollError");
        assertEq(pool.lastInterestError(), _u(string.concat(a, ".lastInterestError")), "lastInterestError");
        assertEq(pool.collGainsBalance(), _u(string.concat(a, ".collGainsBalance")), "collGainsBalance");
        assertEq(
            pool.interestGainsBalance(), _u(string.concat(a, ".interestGainsBalance")), "interestGainsBalance"
        );
        string memory dp = string.concat(a, ".depositors");
        string[] memory names = vm.parseJsonKeys(json, dp);
        for (uint256 k; k < names.length; ++k) {
            string memory p = string.concat(dp, ".", names[k]);
            address who = makeAddr(names[k]);
            assertEq(pool.compoundedDeposit(who), _u(string.concat(p, ".compounded")), "compounded");
            (uint256 cg, uint256 ig) = pool.gains(who);
            assertEq(cg, _u(string.concat(p, ".collGain")), "collGain");
            assertEq(ig, _u(string.concat(p, ".interestGain")), "interestGain");
        }
        // I1 (pool holder) at every step
        assertGe(
            token.balanceOf(address(pool)), pool.totalDeposits() + pool.interestGainsBalance(), "I1 stable"
        );
        assertEq(weth.balanceOf(address(pool)), pool.collGainsBalance(), "I1 WETH");
    }

    /// @dev Every listed `e:s` entry equals the sum, and every unlisted entry up to the current epoch
    ///      and `currentScale + SCALE_SPAN` is 0.
    function _checkSums(string memory path, bool isS) internal view {
        string[] memory keys = vm.parseJsonKeys(json, path);
        uint256 listed;
        for (uint256 e; e <= pool.currentEpoch(); ++e) {
            for (uint256 s; s <= pool.currentScale() + 2 || s <= 2; ++s) {
                string memory key = string.concat(vm.toString(e), ":", vm.toString(s));
                uint256 got = isS ? pool.epochToScaleToS(e, s) : pool.epochToScaleToG(e, s);
                uint256 want;
                for (uint256 k; k < keys.length; ++k) {
                    if (_is(keys[k], key)) {
                        want = _u(string.concat(path, "['", key, "']"));
                        ++listed;
                    }
                }
                assertEq(got, want, string.concat(isS ? "S " : "G ", key));
            }
        }
        assertEq(listed, keys.length, "every listed sum checked");
    }

    function _checkExpected(string memory ep) internal view {
        assertEq(ledger.reserve(), _u(string.concat(ep, ".reserve")), "reserve");
        assertEq(token.balanceOf(address(ledger)), ledger.reserve(), "ledger I1");
        if (_has(string.concat(ep, ".totalDeposits"))) {
            assertEq(pool.totalDeposits(), _u(string.concat(ep, ".totalDeposits")), "totalDeposits");
        }
        if (_has(string.concat(ep, ".depositorCount"))) {
            string memory cp = string.concat(ep, ".depositorCount");
            string[] memory es = vm.parseJsonKeys(json, cp);
            for (uint256 k; k < es.length; ++k) {
                assertEq(pool.depositorCount(vm.parseUint(es[k])), _u(string.concat(cp, ".", es[k])), "count");
            }
        }
    }

    // ------------------------------------------------------------------ json

    function _count(string memory arrayPath) internal view returns (uint256 n) {
        while (_has(string.concat(arrayPath, "[", vm.toString(n), "]"))) ++n;
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _s(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _has(string memory path) internal view returns (bool) {
        return vm.keyExistsJson(json, path);
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
