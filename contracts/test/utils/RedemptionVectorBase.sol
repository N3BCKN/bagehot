// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../../src/core/HintHelpers.sol";
import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {ISortKeySource} from "../../src/interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../../src/interfaces/ISortedPositions.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {MockShutdownGate} from "./RedemptionMocks.sol";
import {MockLedgerViews, MockPool, MockWETH} from "./VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Builds a deployment-A system from a `redemption.json` vector's inputs — real
///         VaultManager, SortedPositions, StableToken, OracleAdapter (mock feeds), RedemptionModule
///         and HintHelpers; mock WETH, ledger and pool (no deposits in any redemption vector, so
///         the pool takes no interest); §5.8's gate as `MockShutdownGate` — and replays its leading
///         `open` / `warp` steps.
abstract contract RedemptionVectorBase is Test {
    string internal json;
    MockWETH internal weth;
    StableToken internal token;
    MockAggregator internal feed;
    VaultManager internal v;
    SortedPositions internal sorted;
    MockLedgerViews internal ledger;
    MockPool internal pool;
    RedemptionModule internal rm;
    MockShutdownGate internal gate;
    HintHelpers internal hints;
    uint256 internal price;

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _s(string memory path) internal view returns (string memory) {
        return vm.parseJsonString(json, path);
    }

    function _is(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _has(string memory path) internal view returns (bool) {
        return vm.keyExistsJson(json, path);
    }

    function _vp(uint256 i) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(i), "]");
    }

    function _sp(string memory vp, uint256 j) internal pure returns (string memory) {
        return string.concat(vp, ".steps[", vm.toString(j), "]");
    }

    function _load() internal {
        json = vm.readFile("../spec/vectors/redemption.json");
    }

    function _deploy(string memory vp) internal {
        string memory p = string.concat(vp, ".inputs.params");
        uint256 t0 = _u(string.concat(vp, ".inputs.t0"));
        vm.warp(t0);
        assertTrue(_is(_s(string.concat(vp, ".inputs.variant")), "A"), "redemption vectors are deployment A");
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(uint8(_u(string.concat(p, ".FEED_DECIMALS"))));
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, t0 - _u(string.concat(p, ".GRACE_PERIOD")) - 1);
        _setPrice(2000e18);
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
        ledger = new MockLedgerViews();
        pool = new MockPool();
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
        rm = new RedemptionModule(
            address(token),
            address(oracle),
            _u(string.concat(p, ".REDEMPTION_FEE_FLOOR")),
            _u(string.concat(p, ".BETA")),
            _u(string.concat(p, ".BASE_RATE_DECAY"))
        );
        gate = new MockShutdownGate(address(v), address(0), _u(string.concat(p, ".CRITICAL_TCR")));
        hints = new HintHelpers(ISortKeySource(address(v)), ISortedPositions(address(sorted)));
        v.wire(address(sorted), address(pool), address(pool), address(rm), address(ledger), address(gate));
        sorted.wire(address(v));
        token.wire(address(v), address(pool), address(ledger), address(gate));
        rm.wire(address(v), address(gate), address(0));
        string[] memory actors = vm.parseJsonStringArray(json, string.concat(vp, ".inputs.actors"));
        uint256 funds = _u(string.concat(vp, ".inputs.actorWeth"));
        for (uint256 i; i < actors.length; ++i) {
            address a = makeAddr(actors[i]);
            weth.mint(a, funds);
            vm.prank(a);
            weth.approve(address(v), type(uint256).max);
        }
    }

    function _setPrice(uint256 priceWad) internal {
        price = priceWad;
        feed.setRound(1, int256(priceWad / 1e10), block.timestamp);
    }

    /// @dev Replays one `open` or `warp` step; returns false for any other op (left to the caller).
    function _setupStep(string memory sp) internal returns (bool) {
        string memory op = _s(string.concat(sp, ".op"));
        assertEq(_u(string.concat(sp, ".t")), block.timestamp, "step time");
        if (_is(op, "warp")) {
            vm.warp(block.timestamp + _u(string.concat(sp, ".dt")));
            return true;
        }
        if (!_is(op, "open")) return false;
        _setPrice(_u(string.concat(sp, ".price")));
        vm.prank(makeAddr(_s(string.concat(sp, ".caller"))));
        uint256 id = v.openPosition(
            _u(string.concat(sp, ".coll")),
            _u(string.concat(sp, ".debt")),
            _u(string.concat(sp, ".upperHint")),
            _u(string.concat(sp, ".lowerHint"))
        );
        assertEq(id, _u(string.concat(sp, ".result.id")), "id");
        return true;
    }

    /// @dev The step's redeem arguments, with the step's price set on the feed.
    function _redeemArgs(string memory sp)
        internal
        returns (address caller, uint256 amount, uint256 maxIt, uint256 maxFee, uint256 up, uint256 lo)
    {
        _setPrice(_u(string.concat(sp, ".price")));
        caller = makeAddr(_s(string.concat(sp, ".caller")));
        amount = _u(string.concat(sp, ".amount"));
        maxIt = _u(string.concat(sp, ".maxIterations"));
        maxFee = _u(string.concat(sp, ".maxFeeRate"));
        up = _u(string.concat(sp, ".upperHint"));
        lo = _u(string.concat(sp, ".lowerHint"));
    }

    function _revertSelector(string memory name) internal pure returns (bytes4) {
        if (_is(name, "NothingRedeemed")) return RedemptionModule.NothingRedeemed.selector;
        if (_is(name, "FeeExceedsMaximum")) return RedemptionModule.FeeExceedsMaximum.selector;
        if (_is(name, "TCRBelowCritical")) return RedemptionModule.TCRBelowCritical.selector;
        revert(string.concat("unmapped revert ", name));
    }
}
