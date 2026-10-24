// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionVectorBase} from "../utils/RedemptionVectorBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice All seven `redemption.json` vectors end to end against the contracts: every step, each
///         redemption's result and trace, every revert, and the full expected state afterwards
///         (vault, positions, list order, ledger, redemption, token, WETH, pool). The Python model
///         runs the same vectors in tests/model/test_redemption_model.py.
contract RedemptionVectorsTest is RedemptionVectorBase {
    uint256 internal constant NO_MATCH = type(uint256).max;

    function _redeemStep(string memory sp) internal {
        (address caller, uint256 amount, uint256 maxIt, uint256 maxFee, uint256 up, uint256 lo) =
            _redeemArgs(sp);
        if (_has(string.concat(sp, ".revert"))) {
            vm.expectRevert(_revertSelector(_s(string.concat(sp, ".revert"))));
            vm.prank(caller);
            rm.redeem(amount, maxIt, maxFee, up, lo);
            return;
        }
        string memory r = string.concat(sp, ".result");
        assertEq(rm.decayedBaseRate(), _u(string.concat(r, ".decayedBaseRate")), "decayedBaseRate");
        string[] memory trace = vm.parseJsonStringArray(json, string.concat(r, ".trace"));
        for (uint256 k; k < trace.length; ++k) {
            if (vm.indexOf(trace[k], "skip") == NO_MATCH) continue;
            // skipped nodes are below MCR at this price and this block's index (= currentIndex)
            assertTrue(v.isLiquidatable(_traceId(trace[k]), price), trace[k]);
        }
        vm.recordLogs();
        vm.prank(caller);
        rm.redeem(amount, maxIt, maxFee, up, lo);
        _checkLogs(vm.getRecordedLogs(), r, trace);
    }

    function _traceId(string memory line) internal pure returns (uint256) {
        return vm.parseUint(vm.replace(vm.split(line, " ")[1], ":", ""));
    }

    function _checkLogs(Vm.Log[] memory logs, string memory r, string[] memory trace) internal view {
        uint256 k;
        bool sawRedeemed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VaultManager.PositionRedeemed.selector) {
                while (vm.indexOf(trace[k], "skip") != NO_MATCH) ++k;
                assertEq(_traceLine(logs[i]), trace[k], "trace line");
                ++k;
            } else if (logs[i].topics[0] == RedemptionModule.Redeemed.selector) {
                (
                    ,
                    uint256 redeemed,
                    uint256 collSent,
                    uint256 feeRate,
                    uint256 iterations,
                    uint256 baseRate
                ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                assertEq(redeemed, _u(string.concat(r, ".redeemed")), "redeemed");
                assertEq(collSent, _u(string.concat(r, ".collSent")), "collSent");
                assertEq(feeRate, _u(string.concat(r, ".feeRate")), "feeRate");
                assertEq(iterations, _u(string.concat(r, ".iterations")), "iterations");
                assertEq(iterations, trace.length, "one trace line per iteration");
                assertEq(baseRate, _u(string.concat(r, ".baseRateAfter")), "baseRateAfter");
                assertEq(token.totalSupply() + redeemed, _u(string.concat(r, ".S0")), "S0");
                uint256 floor = rm.REDEMPTION_FEE_FLOOR();
                assertEq(feeRate - floor, _u(string.concat(r, ".baseRateForFee")), "baseRateForFee");
                sawRedeemed = true;
            }
        }
        while (k < trace.length && vm.indexOf(trace[k], "skip") != NO_MATCH) ++k;
        assertEq(k, trace.length, "every redeemed trace line matched");
        assertTrue(sawRedeemed, "Redeemed emitted");
    }

    function _traceLine(Vm.Log memory log) internal pure returns (string memory) {
        uint256 id = uint256(log.topics[1]);
        (uint256 d, uint256 coll, uint256 surplus, bool closed) =
            abi.decode(log.data, (uint256, uint256, uint256, bool));
        string memory head = string.concat("visit ", vm.toString(id), ": ");
        if (closed) {
            return string.concat(
                head,
                "full redemption d=",
                vm.toString(d),
                " collToRedeemer=",
                vm.toString(coll),
                " surplusToOwner=",
                vm.toString(surplus)
            );
        }
        return
            string.concat(
                head, "partial redemption d=", vm.toString(d), " collToRedeemer=", vm.toString(coll)
            );
    }

    // ------------------------------------------------------------------ expected state

    function _checkVault(string memory e) internal view {
        assertEq(v.index(), _u(string.concat(e, ".index")), "index");
        assertEq(v.lastAccrual(), _u(string.concat(e, ".lastAccrual")), "lastAccrual");
        assertEq(v.totalNormDebt(), _u(string.concat(e, ".totalNormDebt")), "totalNormDebt");
        assertEq(v.totalCollateral(), _u(string.concat(e, ".totalCollateral")), "totalCollateral");
        assertEq(v.totalStakes(), _u(string.concat(e, ".totalStakes")), "totalStakes");
        assertEq(v.totalStakesSnapshot(), _u(string.concat(e, ".totalStakesSnapshot")), "totalStakesSnapshot");
        assertEq(
            v.totalCollateralSnapshot(),
            _u(string.concat(e, ".totalCollateralSnapshot")),
            "totalCollateralSnapshot"
        );
        assertEq(v.LColl(), _u(string.concat(e, ".LColl")), "LColl");
        assertEq(v.LDebt(), _u(string.concat(e, ".LDebt")), "LDebt");
        // the redistribution error carries arrive with their writer at P20
        assertEq(_u(string.concat(e, ".lastErrorColl")), 0, "lastErrorColl");
        assertEq(_u(string.concat(e, ".lastErrorDebt")), 0, "lastErrorDebt");
        assertEq(v.pendingColl(), _u(string.concat(e, ".pendingColl")), "pendingColl");
        assertEq(v.pendingNormDebt(), _u(string.concat(e, ".pendingNormDebt")), "pendingNormDebt");
        assertEq(v.activeCount(), _u(string.concat(e, ".activeCount")), "activeCount");
        string[] memory order = vm.parseJsonStringArray(json, string.concat(e, ".sortedOrder"));
        assertEq(sorted.getSize(), order.length, "list size");
        uint256 cur = sorted.getFirst();
        for (uint256 i; i < order.length; ++i) {
            assertEq(cur, vm.parseUint(order[i]), "sortedOrder");
            cur = sorted.getNext(cur);
        }
    }

    function _status(string memory s) internal pure returns (uint8) {
        if (_is(s, "Active")) return uint8(VaultManager.Status.Active);
        if (_is(s, "ClosedByRedemption")) return uint8(VaultManager.Status.ClosedByRedemption);
        revert(string.concat("unmapped status ", s));
    }

    function _checkPositions(string memory e) internal {
        string[] memory ids = vm.parseJsonKeys(json, e);
        for (uint256 i; i < ids.length; ++i) {
            string memory pp = string.concat(e, ".", ids[i]);
            uint256 id = vm.parseUint(ids[i]);
            VaultManager.Position memory p = v.positions(id);
            assertEq(p.owner, makeAddr(_s(string.concat(pp, ".owner"))), "owner");
            assertEq(uint8(p.status), _status(_s(string.concat(pp, ".status"))), "status");
            assertEq(p.coll, _u(string.concat(pp, ".coll")), "coll");
            assertEq(p.normDebt, _u(string.concat(pp, ".normDebt")), "normDebt");
            assertEq(p.stake, _u(string.concat(pp, ".stake")), "stake");
            assertEq(p.snapLColl, _u(string.concat(pp, ".snapLColl")), "snapLColl");
            assertEq(p.snapLDebt, _u(string.concat(pp, ".snapLDebt")), "snapLDebt");
            if (!_has(string.concat(pp, ".effColl"))) continue;
            (uint256 c, uint256 n) = v.effective(id);
            assertEq(c, _u(string.concat(pp, ".effColl")), "effColl");
            assertEq(n, _u(string.concat(pp, ".effNorm")), "effNorm");
            assertEq(v.debtOf(id), _u(string.concat(pp, ".debt")), "debt");
        }
    }

    function _who(string memory name) internal returns (address) {
        if (_is(name, "ledger")) return address(ledger);
        if (_is(name, "pool")) return address(pool);
        if (_is(name, "vm")) return address(v);
        return makeAddr(name);
    }

    function _checkBalances(string memory vp) internal {
        string memory e = string.concat(vp, ".expected");
        assertEq(ledger.reserve(), _u(string.concat(e, ".ledger.reserve")), "ledger.reserve");
        assertEq(_u(string.concat(e, ".ledger.auctionDebt")), ledger.auctionDebt(), "auctionDebt");
        assertEq(_u(string.concat(e, ".ledger.deficit")), ledger.deficit(), "deficit");
        assertEq(_u(string.concat(e, ".ledger.recoveredColl")), ledger.recoveredColl(), "recoveredColl");
        assertEq(rm.baseRate(), _u(string.concat(e, ".redemption.baseRate")), "baseRate");
        assertEq(
            rm.lastFeeOperationTime(),
            _u(string.concat(e, ".redemption.lastFeeOperationTime")),
            "lastFeeOperationTime"
        );
        assertEq(token.totalSupply(), _u(string.concat(e, ".token.totalSupply")), "totalSupply");
        string[] memory holders = vm.parseJsonKeys(json, string.concat(e, ".token.balances"));
        uint256 sum;
        for (uint256 i; i < holders.length; ++i) {
            uint256 bal = _u(string.concat(e, ".token.balances.", holders[i]));
            assertEq(token.balanceOf(_who(holders[i])), bal, holders[i]);
            sum += bal;
        }
        assertEq(sum, token.totalSupply(), "every holder listed");
        uint256 funds = _u(string.concat(vp, ".inputs.actorWeth"));
        string[] memory names = vm.parseJsonKeys(json, string.concat(e, ".weth"));
        for (uint256 i; i < names.length; ++i) {
            string memory path = string.concat(e, ".weth.", names[i]);
            int256 want = vm.parseInt(vm.parseJsonString(json, path));
            uint256 bal = weth.balanceOf(_who(names[i]));
            if (_is(names[i], "vm")) assertEq(int256(bal), want, "weth.vm");
            else assertEq(int256(bal) - int256(funds), want, names[i]);
        }
        // the real pool arrives at P19: here it must simply have received nothing
        assertEq(_u(string.concat(e, ".pool.totalDeposits")), 0, "pool.totalDeposits");
        assertEq(_u(string.concat(e, ".pool.interestGainsBalance")), 0, "pool.interestGainsBalance");
        assertEq(pool.interestReceived(), 0, "pool interest");
        assertEq(token.balanceOf(address(pool)), 0, "pool balance");
    }

    // ------------------------------------------------------------------ tests

    function _runVector(string memory name, uint256 wantRedeems) internal {
        _load();
        string memory vp = _vp(_indexOf(name));
        _deploy(vp);
        uint256 redeems;
        for (uint256 j; _has(_sp(vp, j)); ++j) {
            string memory sp = _sp(vp, j);
            if (_setupStep(sp)) continue;
            assertTrue(_is(_s(string.concat(sp, ".op")), "redeem"), "op");
            _redeemStep(sp);
            ++redeems;
        }
        assertEq(redeems, wantRedeems, "every redeem step");
        _checkVault(string.concat(vp, ".expected.vault"));
        _checkPositions(string.concat(vp, ".expected.positions"));
        _checkBalances(vp);
    }

    function _indexOf(string memory name) internal view returns (uint256 i) {
        for (; _has(_vp(i)); ++i) {
            if (_is(_s(string.concat(_vp(i), ".name")), name)) return i;
        }
        revert(string.concat("no vector ", name));
    }

    function test_vectors_fileHasSevenVectors() public {
        _load();
        assertTrue(_has(_vp(6)) && !_has(_vp(7)), "seven vectors, each with its own test below");
    }

    function test_vector_skipFullPartial() public {
        _runVector("skip_full_partial", 1);
    }

    function test_vector_minDebtStop() public {
        _runVector("min_debt_stop", 2);
    }

    function test_vector_staleHintCancelsPartial() public {
        _runVector("stale_hint_cancels_partial", 1);
    }

    function test_vector_baseRateDecayAndFee() public {
        _runVector("base_rate_decay_and_fee", 3);
    }

    function test_vector_singleNodePartial() public {
        _runVector("single_node_partial", 1);
    }

    function test_vector_tcrGuard() public {
        _runVector("tcr_guard", 2);
    }

    function test_vector_partialCancelledBelowMcr() public {
        _runVector("partial_cancelled_below_mcr", 2);
    }
}
