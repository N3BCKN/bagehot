// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {DeficitLedger} from "../../src/safety/DeficitLedger.sol";
import {MockShutdownGate} from "../utils/RedemptionMocks.sol";
import {VaultManagerHarness} from "../utils/VaultManagerHarness.sol";
import {MockWETH} from "../utils/VaultMocks.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// @notice Every system vector of `liquidation_pool.json` (6) and `redistribution.json` (2) end to end
///         on deployment A: the real VaultManager, StabilityPool, SortedPositions, StableToken,
///         OracleAdapter (mock feeds) and RedemptionModule, the real DeficitLedger (P21) and §5.8's gate as
/// a mock. Every step's result (each liquidation's `Liquidated` and `PoolLiquidation` fields) and the full
/// expected state afterwards. The
///         reference's `weth.strategy` is a pass-through account it kept for WETH in transit (0 in
///         every vector, A and B alike); in the contracts the strategy is the pool, checked as `pool`.
///         The Python model runs the same vectors in tests/model/test_liquidation_model.py.
contract LiquidationVectorsTest is Test {
    string internal json;
    string internal vp;
    MockWETH internal weth;
    StableToken internal token;
    MockAggregator internal feed;
    VaultManager internal v;
    SortedPositions internal sorted;
    StabilityPool internal pool;
    DeficitLedger internal ledger;
    RedemptionModule internal rm;
    uint256 internal funds;

    function test_vector_withSurplus() public {
        _run("liquidation_pool", 0, "with_surplus");
    }

    function test_vector_withoutSurplus() public {
        _run("liquidation_pool", 1, "without_surplus");
    }

    function test_vector_underwater() public {
        _run("liquidation_pool", 2, "underwater");
    }

    function test_vector_partialAbsorption() public {
        _run("liquidation_pool", 3, "partial_absorption");
    }

    function test_vector_emptyPoolRedistribution() public {
        _run("liquidation_pool", 4, "empty_pool_redistribution");
    }

    function test_vector_noStakesDeficit() public {
        _run("liquidation_pool", 5, "no_stakes_deficit");
    }

    function test_vector_liquidateIntoRedistributionThenSnapshotStake() public {
        _run("redistribution", 0, "liquidate_into_redistribution_then_snapshot_stake");
    }

    function test_vector_stakesAfterLastLiquidation() public {
        _run("redistribution", 1, "stakes_after_last_liquidation");
    }

    // ------------------------------------------------------------------ replay

    function _run(string memory file, uint256 i, string memory name) internal {
        json = vm.readFile(string.concat("../spec/vectors/", file, ".json"));
        vp = string.concat(".vectors[", vm.toString(i), "]");
        assertEq(_s(".name"), name, "vector order");
        assertEq(_s(".inputs.variant"), "A", "deployment A");
        _deploy(".inputs.params", _u(".inputs.t0"));
        uint256 j;
        while (vm.keyExistsJson(json, string.concat(vp, ".steps[", vm.toString(j), "]"))) {
            _step(string.concat(".steps[", vm.toString(j), "]"));
            ++j;
        }
        _checkVault();
        _checkPositions();
        _checkLedgerTokenWeth();
        _checkPool();
    }

    function _step(string memory sp) internal {
        string memory op = _s(string.concat(sp, ".op"));
        assertEq(_u(string.concat(sp, ".t")), block.timestamp, "step time");
        address caller = _actor(_s(string.concat(sp, ".caller")));
        if (vm.keyExistsJson(json, string.concat(vp, sp, ".price"))) {
            feed.setRound(1, int256(_u(string.concat(sp, ".price")) / 1e10), block.timestamp);
        }
        if (_is(op, "open")) {
            vm.prank(caller);
            uint256 id = v.openPosition(
                _u(string.concat(sp, ".coll")),
                _u(string.concat(sp, ".debt")),
                _u(string.concat(sp, ".upperHint")),
                _u(string.concat(sp, ".lowerHint"))
            );
            assertEq(id, _u(string.concat(sp, ".result.id")), "id");
        } else if (_is(op, "deposit")) {
            vm.prank(caller);
            pool.deposit(_u(string.concat(sp, ".amount")));
        } else if (_is(op, "addCollateral")) {
            vm.prank(caller);
            v.addCollateral(
                _u(string.concat(sp, ".id")),
                _u(string.concat(sp, ".amount")),
                _u(string.concat(sp, ".upperHint")),
                _u(string.concat(sp, ".lowerHint"))
            );
        } else if (_is(op, "transfer")) {
            vm.prank(caller);
            token.transfer(_actor(_s(string.concat(sp, ".to"))), _u(string.concat(sp, ".amount")));
        } else if (_is(op, "close")) {
            uint256 before = token.balanceOf(caller);
            vm.prank(caller);
            v.close(_u(string.concat(sp, ".id")));
            assertEq(
                before - token.balanceOf(caller), _u(string.concat(sp, ".result.debtBurned")), "debtBurned"
            );
        } else if (_is(op, "liquidate")) {
            _liquidate(sp, caller);
        } else {
            revert(string.concat("unknown op ", op));
        }
    }

    function _liquidate(string memory sp, address caller) internal {
        uint256 id = _u(string.concat(sp, ".id"));
        (, uint256 effNorm) = v.effective(id);
        vm.recordLogs();
        vm.prank(caller);
        v.liquidate(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        string memory r = string.concat(sp, ".result");
        bool sawLiq;
        bool sawPool;
        for (uint256 k; k < logs.length; ++k) {
            bytes32 t = logs[k].topics[0];
            if (t == VaultManager.Liquidated.selector) {
                (uint256 debt, uint256 coll, uint256 dA, uint256 cR, uint256 nR, uint8 path, uint256 gas) =
                    abi.decode(logs[k].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint256));
                assertEq(debt, _u(string.concat(r, ".debt")), "debt");
                assertEq(coll, _u(string.concat(r, ".coll")), "coll");
                assertEq(dA, _u(string.concat(r, ".debtAbsorbed")), "debtAbsorbed");
                assertEq(cR, _u(string.concat(r, ".collRemainder")), "collRemainder");
                assertEq(nR, _u(string.concat(r, ".normRemainder")), "normRemainder");
                assertEq(effNorm - nR, _u(string.concat(r, ".normAbsorbed")), "normAbsorbed");
                assertEq(path, _path(_s(string.concat(r, ".remainderPath"))), "remainderPath");
                assertEq(gas, v.GAS_RESERVE(), "gasCompensation");
                sawLiq = true;
            } else if (t == StabilityPool.PoolLiquidation.selector) {
                (,, uint256 seized, uint256 surplus, uint256 dP, uint256 collP, uint256 back) =
                    abi.decode(logs[k].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                string memory pr = string.concat(r, ".pool");
                assertEq(seized, _u(string.concat(pr, ".seized")), "seized");
                assertEq(surplus, _u(string.concat(pr, ".surplus")), "surplus");
                assertEq(dP, _u(string.concat(pr, ".debtOffset")), "debtOffset");
                assertEq(collP, _u(string.concat(pr, ".collToPool")), "collToPool");
                assertEq(back, _u(string.concat(pr, ".collReturned")), "collReturned");
                sawPool = true;
            }
        }
        assertTrue(sawLiq && sawPool, "Liquidated and PoolLiquidation emitted");
    }

    // ------------------------------------------------------------------ expected state

    function _checkVault() internal view {
        string memory e = ".expected.vault";
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
        assertEq(v.lastErrorColl(), _u(string.concat(e, ".lastErrorColl")), "lastErrorColl");
        assertEq(v.lastErrorDebt(), _u(string.concat(e, ".lastErrorDebt")), "lastErrorDebt");
        assertEq(v.pendingColl(), _u(string.concat(e, ".pendingColl")), "pendingColl");
        assertEq(v.pendingNormDebt(), _u(string.concat(e, ".pendingNormDebt")), "pendingNormDebt");
        assertEq(v.activeCount(), _u(string.concat(e, ".activeCount")), "activeCount");
        string[] memory order = vm.parseJsonStringArray(json, string.concat(vp, e, ".sortedOrder"));
        assertEq(sorted.getSize(), order.length, "list size");
        uint256 node = sorted.getFirst();
        for (uint256 k; k < order.length; ++k) {
            assertEq(node, vm.parseUint(order[k]), "sorted order");
            node = sorted.getNext(node);
        }
    }

    function _checkPositions() internal view {
        string memory e = ".expected.positions";
        string[] memory ids = vm.parseJsonKeys(json, string.concat(vp, e));
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = vm.parseUint(ids[k]);
            string memory p = string.concat(e, ".", ids[k]);
            VaultManager.Position memory pos = v.positions(id);
            assertEq(pos.owner, _actor(_s(string.concat(p, ".owner"))), "owner");
            assertEq(uint8(pos.status), _status(_s(string.concat(p, ".status"))), "status");
            assertEq(pos.coll, _u(string.concat(p, ".coll")), "coll");
            assertEq(pos.normDebt, _u(string.concat(p, ".normDebt")), "normDebt");
            assertEq(pos.stake, _u(string.concat(p, ".stake")), "stake");
            assertEq(pos.snapLColl, _u(string.concat(p, ".snapLColl")), "snapLColl");
            assertEq(pos.snapLDebt, _u(string.concat(p, ".snapLDebt")), "snapLDebt");
            if (vm.keyExistsJson(json, string.concat(vp, p, ".effColl"))) {
                (uint256 c, uint256 n) = v.effective(id);
                assertEq(c, _u(string.concat(p, ".effColl")), "effColl");
                assertEq(n, _u(string.concat(p, ".effNorm")), "effNorm");
                assertEq(v.debtOf(id), _u(string.concat(p, ".debt")), "debt");
            }
        }
    }

    function _checkLedgerTokenWeth() internal {
        string memory l = ".expected.ledger";
        assertEq(ledger.reserve(), _u(string.concat(l, ".reserve")), "reserve");
        assertEq(ledger.deficit(), _u(string.concat(l, ".deficit")), "deficit");
        assertEq(ledger.recoveredColl(), _u(string.concat(l, ".recoveredColl")), "recoveredColl");
        assertEq(_u(string.concat(l, ".auctionDebt")), 0, "no auction debt in A");
        assertEq(rm.baseRate(), _u(".expected.redemption.baseRate"), "baseRate");
        assertEq(
            rm.lastFeeOperationTime(), _u(".expected.redemption.lastFeeOperationTime"), "lastFeeOperationTime"
        );
        assertEq(token.totalSupply(), _u(".expected.token.totalSupply"), "totalSupply");
        string memory tb = ".expected.token.balances";
        string[] memory holders = vm.parseJsonKeys(json, string.concat(vp, tb));
        for (uint256 k; k < holders.length; ++k) {
            assertEq(token.balanceOf(_holder(holders[k])), _u(string.concat(tb, ".", holders[k])), holders[k]);
        }
        string memory w = ".expected.weth";
        string[] memory names = vm.parseJsonKeys(json, string.concat(vp, w));
        for (uint256 k; k < names.length; ++k) {
            string memory nm = names[k];
            string memory want = _s(string.concat(w, ".", nm));
            if (_is(nm, "strategy")) {
                assertEq(want, "0", "the reference's pass-through account holds nothing");
            } else if (_is(nm, "vm") || _is(nm, "pool") || _is(nm, "ledger")) {
                assertEq(weth.balanceOf(_holder(nm)), vm.parseUint(want), nm);
            } else {
                assertEq(int256(weth.balanceOf(_actor(nm))) - int256(funds), vm.parseInt(want), nm);
            }
        }
    }

    function _checkPool() internal view {
        string memory p = ".expected.pool";
        assertEq(pool.totalDeposits(), _u(string.concat(p, ".totalDeposits")), "totalDeposits");
        assertEq(pool.P(), _u(string.concat(p, ".P")), "P");
        assertEq(pool.currentScale(), _u(string.concat(p, ".currentScale")), "currentScale");
        assertEq(pool.currentEpoch(), _u(string.concat(p, ".currentEpoch")), "currentEpoch");
        assertEq(pool.lastCollError(), _u(string.concat(p, ".lastCollError")), "lastCollError");
        assertEq(pool.lastInterestError(), _u(string.concat(p, ".lastInterestError")), "lastInterestError");
        assertEq(pool.collGainsBalance(), _u(string.concat(p, ".collGainsBalance")), "collGainsBalance");
        assertEq(pool.interestGainsBalance(), _u(string.concat(p, ".interestGainsBalance")), "interestGains");
        string[] memory sKeys = vm.parseJsonKeys(json, string.concat(vp, p, ".S"));
        for (uint256 k; k < sKeys.length; ++k) {
            string[] memory es = vm.split(sKeys[k], ":");
            assertEq(
                pool.epochToScaleToS(vm.parseUint(es[0]), vm.parseUint(es[1])),
                _u(string.concat(p, ".S['", sKeys[k], "']")),
                "S"
            );
        }
        string[] memory gKeys = vm.parseJsonKeys(json, string.concat(vp, p, ".G"));
        for (uint256 k; k < gKeys.length; ++k) {
            string[] memory es = vm.split(gKeys[k], ":");
            assertEq(
                pool.epochToScaleToG(vm.parseUint(es[0]), vm.parseUint(es[1])),
                _u(string.concat(p, ".G['", gKeys[k], "']")),
                "G"
            );
        }
        if (vm.keyExistsJson(json, string.concat(vp, p, ".deposits"))) {
            string[] memory ds = vm.parseJsonKeys(json, string.concat(vp, p, ".deposits"));
            for (uint256 k; k < ds.length; ++k) {
                string memory d = string.concat(p, ".deposits.", ds[k]);
                address who = _actor(ds[k]);
                (uint256 initial,,,,,) = pool.deposits(who);
                assertEq(initial, _u(string.concat(d, ".initial")), "initial");
                assertEq(pool.compoundedDeposit(who), _u(string.concat(d, ".compounded")), "compounded");
                (uint256 cg, uint256 ig) = pool.gains(who);
                assertEq(cg, _u(string.concat(d, ".collGain")), "collGain");
                assertEq(ig, _u(string.concat(d, ".interestGain")), "interestGain");
            }
        }
    }

    // ------------------------------------------------------------------ deployment

    function _deploy(string memory p, uint256 t0) internal {
        vm.warp(t0);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(uint8(_u(string.concat(p, ".FEED_DECIMALS"))));
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, t0 - _u(string.concat(p, ".GRACE_PERIOD")) - 1);
        feed.setRound(1, int256(2000e8), block.timestamp);
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
        pool = new StabilityPool(
            address(weth),
            address(token),
            _u(string.concat(p, ".LIQUIDATION_PENALTY")),
            _u(string.concat(p, ".MIN_DEPOSIT"))
        );
        ledger = new DeficitLedger(address(weth), address(token));
        rm = new RedemptionModule(
            address(token),
            address(oracle),
            _u(string.concat(p, ".REDEMPTION_FEE_FLOOR")),
            _u(string.concat(p, ".BETA")),
            _u(string.concat(p, ".BASE_RATE_DECAY"))
        );
        MockShutdownGate gate =
            new MockShutdownGate(address(v), address(0), _u(string.concat(p, ".CRITICAL_TCR")));
        v.wire(address(sorted), address(pool), address(pool), address(rm), address(ledger), address(gate));
        sorted.wire(address(v));
        token.wire(address(v), address(pool), address(ledger), address(gate));
        rm.wire(address(v), address(gate), address(0));
        pool.wire(address(v), address(ledger));
        ledger.wire(address(v), address(pool), address(0), address(pool), address(gate));
        string[] memory actors = vm.parseJsonStringArray(json, string.concat(vp, ".inputs.actors"));
        funds = _u(".inputs.actorWeth");
        for (uint256 k; k < actors.length; ++k) {
            address a = _actor(actors[k]);
            weth.mint(a, funds);
            vm.prank(a);
            weth.approve(address(v), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _actor(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(string.concat("vector actor ", name))))));
    }

    function _holder(string memory name) internal view returns (address) {
        if (_is(name, "pool")) return address(pool);
        if (_is(name, "ledger")) return address(ledger);
        if (_is(name, "vm")) return address(v);
        return _actor(name);
    }

    function _status(string memory s) internal pure returns (uint8) {
        if (_is(s, "Active")) return uint8(VaultManager.Status.Active);
        if (_is(s, "ClosedByOwner")) return uint8(VaultManager.Status.ClosedByOwner);
        if (_is(s, "ClosedByRedemption")) return uint8(VaultManager.Status.ClosedByRedemption);
        if (_is(s, "ClosedByLiquidation")) return uint8(VaultManager.Status.ClosedByLiquidation);
        if (_is(s, "ClosedByShutdown")) return uint8(VaultManager.Status.ClosedByShutdown);
        revert(string.concat("status ", s));
    }

    function _path(string memory s) internal pure returns (uint8) {
        if (_is(s, "NONE")) return 0;
        if (_is(s, "REDISTRIBUTED")) return 1;
        if (_is(s, "DEFICIT")) return 2;
        revert(string.concat("path ", s));
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, string.concat(vp, path)));
    }

    function _s(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, string.concat(vp, path));
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

/// @notice `redistribution.json#error_carry` (unit): the VaultManager's §6.5.2 accumulators and error
///         carries, step by step, through the harness's entry into the real `_redistribute`.
contract RedistributionErrorCarryVectorTest is Test {
    function test_vector_errorCarry() public {
        string memory json = vm.readFile("../spec/vectors/redistribution.json");
        string memory vp = ".vectors[2]";
        assertEq(vm.parseJsonString(json, string.concat(vp, ".name")), "error_carry");
        VaultManagerHarness h =
            new VaultManagerHarness(address(1), address(2), address(3), 1.1e18, 2000e18, 1, 0, 0, 200_000);
        uint256 stakes = vm.parseUint(vm.parseJsonString(json, string.concat(vp, ".inputs.totalStakes")));
        for (uint256 j; j < 3; ++j) {
            string memory sp = string.concat(vp, ".steps[", vm.toString(j), "]");
            h.redistributeForTest(
                stakes,
                vm.parseUint(vm.parseJsonString(json, string.concat(sp, ".collR"))),
                vm.parseUint(vm.parseJsonString(json, string.concat(sp, ".normR")))
            );
            string memory r = string.concat(sp, ".result");
            assertEq(h.LColl(), vm.parseUint(vm.parseJsonString(json, string.concat(r, ".LColl"))), "LColl");
            assertEq(h.LDebt(), vm.parseUint(vm.parseJsonString(json, string.concat(r, ".LDebt"))), "LDebt");
            assertEq(
                h.lastErrorColl(),
                vm.parseUint(vm.parseJsonString(json, string.concat(r, ".lastErrorColl"))),
                "eC"
            );
            assertEq(
                h.lastErrorDebt(),
                vm.parseUint(vm.parseJsonString(json, string.concat(r, ".lastErrorDebt"))),
                "eD"
            );
        }
    }
}
