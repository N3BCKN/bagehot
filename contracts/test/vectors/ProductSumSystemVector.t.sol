// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {StandInDeficitLedger} from "../../src/mocks/StandInDeficitLedger.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {MockShutdownGate} from "../utils/RedemptionMocks.sol";
import {MockWETH} from "../utils/VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice `product_sum.json#deposit_after_idle_gets_no_back_interest` end to end: the real
///         VaultManager, StabilityPool, SortedPositions, StableToken, OracleAdapter (mock feeds) and
///         RedemptionModule, with the DeficitLedger stand-in and §5.8's gate as a mock. `deposit`
///         accrues before it snapshots, so the idle interest goes to the depositor who was there.
contract ProductSumSystemVectorTest is Test {
    string internal json;
    string internal constant VP = ".vectors[2]";
    MockWETH internal weth;
    StableToken internal token;
    MockAggregator internal feed;
    VaultManager internal v;
    StabilityPool internal pool;
    StandInDeficitLedger internal ledger;
    RedemptionModule internal rm;

    function setUp() public {
        json = vm.readFile("../spec/vectors/product_sum.json");
        assertEq(_s(string.concat(VP, ".name")), "deposit_after_idle_gets_no_back_interest", "vector order");
        assertEq(_s(string.concat(VP, ".inputs.variant")), "A", "deployment A");
        _deploy(string.concat(VP, ".inputs.params"), _u(string.concat(VP, ".inputs.t0")));
    }

    function test_vector_depositAfterIdleGetsNoBackInterest() public {
        uint256 funds = _u(string.concat(VP, ".inputs.actorWeth"));
        uint256 j;
        while (vm.keyExistsJson(json, _sp(j))) {
            _step(_sp(j));
            ++j;
        }
        _checkExpected(string.concat(VP, ".expected"), funds);
    }

    // ------------------------------------------------------------------ steps

    function _step(string memory sp) internal {
        string memory op = _s(string.concat(sp, ".op"));
        assertEq(_u(string.concat(sp, ".t")), block.timestamp, "step time");
        address caller = vm.keyExistsJson(json, string.concat(sp, ".caller"))
            ? makeAddr(_s(string.concat(sp, ".caller")))
            : address(0);
        if (_is(op, "warp")) {
            vm.warp(block.timestamp + _u(string.concat(sp, ".dt")));
        } else if (_is(op, "open")) {
            feed.setRound(1, int256(_u(string.concat(sp, ".price")) / 1e10), block.timestamp);
            vm.prank(caller);
            uint256 id = v.openPosition(
                _u(string.concat(sp, ".coll")),
                _u(string.concat(sp, ".debt")),
                _u(string.concat(sp, ".upperHint")),
                _u(string.concat(sp, ".lowerHint"))
            );
            assertEq(id, _u(string.concat(sp, ".result.id")), "id");
        } else if (_is(op, "deposit")) {
            string memory r = string.concat(sp, ".result");
            assertEq(pool.compoundedDeposit(caller), _u(string.concat(r, ".compoundedBefore")), "before");
            uint256 balanceBefore = token.balanceOf(caller);
            vm.prank(caller);
            pool.deposit(_u(string.concat(sp, ".amount")));
            (uint256 initial,,,,,) = pool.deposits(caller);
            assertEq(initial, _u(string.concat(r, ".deposit")), "deposit");
            uint256 paid = balanceBefore + _u(string.concat(r, ".interestGainPaid")) - token.balanceOf(caller);
            assertEq(paid, _u(string.concat(sp, ".amount")), "deposit pulled");
            assertEq(_u(string.concat(r, ".collGainPaid")), 0, "no collateral in this vector");
        } else {
            revert(string.concat("unknown op ", op));
        }
    }

    // ------------------------------------------------------------------ expected

    function _checkExpected(string memory ep, uint256 funds) internal {
        string memory vv = string.concat(ep, ".vault");
        assertEq(v.index(), _u(string.concat(vv, ".index")), "index");
        assertEq(v.lastAccrual(), _u(string.concat(vv, ".lastAccrual")), "lastAccrual");
        assertEq(v.totalNormDebt(), _u(string.concat(vv, ".totalNormDebt")), "totalNormDebt");
        assertEq(v.totalCollateral(), _u(string.concat(vv, ".totalCollateral")), "totalCollateral");
        assertEq(v.totalStakes(), _u(string.concat(vv, ".totalStakes")), "totalStakes");
        assertEq(v.activeCount(), _u(string.concat(vv, ".activeCount")), "activeCount");
        string memory pp = string.concat(ep, ".positions");
        for (uint256 id = 1; id <= 2; ++id) {
            string memory p = string.concat(pp, ".", vm.toString(id));
            assertEq(v.debtOf(id), _u(string.concat(p, ".debt")), "debt");
        }
        assertEq(ledger.reserve(), _u(string.concat(ep, ".ledger.reserve")), "reserve");
        string memory tp = string.concat(ep, ".token");
        assertEq(token.totalSupply(), _u(string.concat(tp, ".totalSupply")), "totalSupply");
        assertEq(token.balanceOf(makeAddr("alice")), _u(string.concat(tp, ".balances.alice")), "alice");
        assertEq(token.balanceOf(makeAddr("bob")), _u(string.concat(tp, ".balances.bob")), "bob");
        assertEq(token.balanceOf(address(ledger)), _u(string.concat(tp, ".balances.ledger")), "ledger");
        assertEq(token.balanceOf(address(pool)), _u(string.concat(tp, ".balances.pool")), "pool");
        string memory wp = string.concat(ep, ".weth");
        assertEq(funds - weth.balanceOf(makeAddr("alice")), _neg(string.concat(wp, ".alice")), "alice weth");
        assertEq(funds - weth.balanceOf(makeAddr("bob")), _neg(string.concat(wp, ".bob")), "bob weth");
        assertEq(weth.balanceOf(address(v)), _u(string.concat(wp, ".vm")), "vm weth");
        _checkPool(string.concat(ep, ".pool"));
    }

    function _checkPool(string memory p) internal {
        assertEq(pool.totalDeposits(), _u(string.concat(p, ".totalDeposits")), "totalDeposits");
        assertEq(pool.P(), _u(string.concat(p, ".P")), "P");
        assertEq(pool.currentScale(), _u(string.concat(p, ".currentScale")), "currentScale");
        assertEq(pool.currentEpoch(), _u(string.concat(p, ".currentEpoch")), "currentEpoch");
        assertEq(vm.parseJsonKeys(json, string.concat(p, ".S")).length, 0, "no S");
        assertEq(pool.epochToScaleToS(0, 0), 0, "S 0:0");
        assertEq(pool.epochToScaleToG(0, 0), _u(string.concat(p, ".G['0:0']")), "G 0:0");
        assertEq(pool.lastCollError(), _u(string.concat(p, ".lastCollError")), "lastCollError");
        assertEq(pool.lastInterestError(), _u(string.concat(p, ".lastInterestError")), "lastInterestError");
        assertEq(pool.collGainsBalance(), _u(string.concat(p, ".collGainsBalance")), "collGainsBalance");
        assertEq(pool.interestGainsBalance(), _u(string.concat(p, ".interestGainsBalance")), "interestGains");
        assertEq(pool.depositorCount(0), _u(string.concat(p, ".depositorCount.0")), "depositorCount");
        string[2] memory names = ["alice", "bob"];
        for (uint256 k; k < 2; ++k) {
            string memory dp = string.concat(p, ".deposits.", names[k]);
            address who = makeAddr(names[k]);
            (
                uint256 initial,
                uint256 snapP,
                uint256 snapS,
                uint256 snapG,
                uint256 snapEpoch,
                uint256 snapScale
            ) = pool.deposits(who);
            assertEq(initial, _u(string.concat(dp, ".initial")), "initial");
            assertEq(snapP, _u(string.concat(dp, ".snapP")), "snapP");
            assertEq(snapS, _u(string.concat(dp, ".snapS")), "snapS");
            assertEq(snapG, _u(string.concat(dp, ".snapG")), "snapG");
            assertEq(snapEpoch, _u(string.concat(dp, ".snapEpoch")), "snapEpoch");
            assertEq(snapScale, _u(string.concat(dp, ".snapScale")), "snapScale");
            assertEq(pool.compoundedDeposit(who), _u(string.concat(dp, ".compounded")), "compounded");
            (uint256 cg, uint256 ig) = pool.gains(who);
            assertEq(cg, _u(string.concat(dp, ".collGain")), "collGain");
            assertEq(ig, _u(string.concat(dp, ".interestGain")), "interestGain");
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
        SortedPositions sorted = new SortedPositions(_u(string.concat(p, ".MAX_HINT_STEPS")));
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
        ledger = new StandInDeficitLedger(address(v));
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
        string[] memory actors = vm.parseJsonStringArray(json, string.concat(VP, ".inputs.actors"));
        uint256 funds = _u(string.concat(VP, ".inputs.actorWeth"));
        for (uint256 i; i < actors.length; ++i) {
            address a = makeAddr(actors[i]);
            weth.mint(a, funds);
            vm.prank(a);
            weth.approve(address(v), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ json

    function _sp(uint256 j) internal pure returns (string memory) {
        return string.concat(VP, ".steps[", vm.toString(j), "]");
    }

    /// @dev A negative WETH delta in the vector, as its magnitude.
    function _neg(string memory path) internal view returns (uint256) {
        string memory s = _s(path);
        assertEq(bytes(s)[0], bytes1("-"), "negative delta");
        return vm.parseUint(vm.replace(s, "-", ""));
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _s(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
