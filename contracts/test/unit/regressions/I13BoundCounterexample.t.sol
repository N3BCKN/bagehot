// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../../src/core/SortedPositions.sol";
import {StableToken} from "../../../src/core/StableToken.sol";
import {VaultManager} from "../../../src/core/VaultManager.sol";
import {MockAggregator} from "../../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../../src/mocks/MockSequencerFeed.sol";
import {I13HiddenKeys} from "../../utils/I13HiddenKeys.sol";
import {VaultManagerHarness} from "../../utils/VaultManagerHarness.sol";
import {MockLedgerViews, MockWETH} from "../../utils/VaultMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice P17-2 / CHG-009: a protocol-valid sequence — every open at or above MCR and MIN_DEBT, every
///         redistribution a deployment-A liquidation that returns the whole collateral (checked in
///         `_liquidate`) — on which a correct VaultManager breaks CHG-008's per-member bound, while the
///         hidden-key bound holds. The cause is the one the P17 review named (F3): the snapshot ratio
///         (§6.5.4) is short of the members' common ratio by the accumulated carry and dust, so a
///         newcomer is under-staked by more than one unit relative to its neighbour, which CHG-008 does
///         not allow for. The integer state asserted is the one `scripts/analysis/i13_bound_search.py`
///         (an independent exact-integer model of §6.5.2–6.5.4) predicts for the same sequence.
contract I13BoundCounterexampleTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DP = 1e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant PRICE = 100_000e18;
    uint256 internal constant LIQ_PRICE = 50_000e18; // oracle bounds: 10e18 to 1,000,000e18
    uint256 internal constant PENALTY = 0.05e18; // LIQUIDATION_PENALTY's default (§3)

    MockWETH internal weth;
    VaultManagerHarness internal v;
    SortedPositions internal sorted;
    MockAggregator internal feed;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockWETH();
        StableToken token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, block.timestamp - 100_000);
        feed.setRound(1, int256(PRICE / 1e10), block.timestamp - 60);
        OracleAdapter oracle =
            new OracleAdapter(address(feed), address(seq), 3600, 3600, 10e18, 1_000_000e18, 100_000, 3175);
        sorted = new SortedPositions(30);
        MockLedgerViews ledger = new MockLedgerViews();
        // interest rate 0: the index stays at RAY, so normalised debt equals debt (as in the model)
        v = new VaultManagerHarness(
            address(weth), address(token), address(oracle), 1.1e18, MIN_DEBT, 0.0375e18, 0, 7500
        );
        address pool = makeAddr("pool");
        v.wire(address(sorted), pool, pool, address(0xDE11), address(ledger), address(0x5D));
        sorted.wire(address(v));
        token.wire(address(v), pool, address(ledger), address(0x5D));
        weth.mint(alice, 1e24);
        vm.prank(alice);
        weth.approve(address(v), type(uint256).max);
    }

    function _collFor(uint256 debt, uint256 icrMilli) internal pure returns (uint256) {
        return debt * icrMilli * WAD / (1000 * PRICE) + 1;
    }

    function _open(uint256 coll, uint256 debt) internal returns (uint256 id) {
        id = v.nextId();
        vm.prank(alice);
        v.openPosition(coll, debt, 0, 0);
    }

    /// @dev The harness redistribution stands in for a deployment-A liquidation with an empty pool
    ///      (§6.4.1–6.4.2). Each victim is checked to be one: at the price `LIQ_PRICE` (inside the
    ///      oracle's bounds) its ICR is below MCR, and below 1 + LIQUIDATION_PENALTY, so the pool
    ///      seizes its whole collateral (§6.6.4) and all of it is redistributed. Redistributed amounts
    ///      do not depend on the price, so the opens can stay at `PRICE`.
    function _liquidate(uint256 id) internal {
        VaultManager.Position memory p = v.positions(id);
        assertLt(p.coll * LIQ_PRICE, 1.1e18 * p.normDebt, "victim below MCR at LIQ_PRICE");
        assertLe(p.coll * LIQ_PRICE, (WAD + PENALTY) * p.normDebt, "whole collateral seized at LIQ_PRICE");
        v.redistribute(id);
    }

    function test_chg008BoundBrokenByACorrectVaultManager_hiddenKeyBoundHolds() public {
        (uint256 a, uint256 b, int256 iotaB) = _build();
        _assertModelState(a, b);
        _assertBounds(a, b, iotaB);
    }

    /// @dev The sequence: A and six members; ten small redistributions, each followed by every member
    ///      but A re-applying (dust); one more (the snapshot carries it); B placed just behind A; one
    ///      liquidation-sized remainder (opened at ICR 1.1 at `PRICE`, liquidated at `LIQ_PRICE`).
    function _build() internal returns (uint256 a, uint256 b, int256 iotaB) {
        a = _open(_collFor(3 * MIN_DEBT, 3000), 3 * MIN_DEBT);
        uint256[6] memory others;
        for (uint256 j; j < 6; ++j) {
            others[j] = _open(_collFor(MIN_DEBT * (2 + j), 2500 + 100 * j), MIN_DEBT * (2 + j));
        }
        for (uint256 r; r < 10; ++r) {
            _liquidate(_open(_collFor(MIN_DEBT, 2000), MIN_DEBT));
            for (uint256 j; j < 6; ++j) {
                vm.prank(alice);
                v.addCollateral(others[j], 1 + (r * 7919 + j * 104_729) % 1e9, 0, 0);
            }
        }
        _liquidate(_open(_collFor(MIN_DEBT, 2000), MIN_DEBT));
        (uint256 cA0, uint256 nA0) = v.sortKey(a);
        uint256 cB0 = cA0 * 10 + 12_345;
        b = _open(cB0, cB0 * nA0 / cA0 + 1);
        assertEq(sorted.getNext(a), b, "B sits directly behind A");
        iotaB = _iotaAtInsertion(b);
        uint256 t = v.totalStakes();
        uint256 d = Math.max(MIN_DEBT, t * t / DP * 1e4);
        _liquidate(_open(_collFor(d, 1100), d));
    }

    /// @dev The integer state the exact model predicts for the same sequence.
    function _assertModelState(uint256 a, uint256 b) internal view {
        assertEq(v.LColl(), 643_823_529_412_311_063, "LColl");
        assertEq(v.LDebt(), 47_941_176_470_686_635_858_303, "LDebt");
        (uint256 cA, uint256 nA) = v.sortKey(a);
        (uint256 cB, uint256 nB) = v.sortKey(b);
        assertEq(cA, 295_888_235_294_215_992, "cA");
        assertEq(nA, 14_629_411_764_723_594_502_435, "nA");
        assertEq(cB, 2_958_882_352_942_175_992, "cB");
        assertEq(nB, 146_294_117_647_236_737_103_087, "nB");
        assertEq(v.positions(b).stake, 1_800_000_000_000_009_675, "B's stake");
        assertEq(sorted.getNext(a), b, "still adjacent");
    }

    /// @dev CHG-008 (m(A) = 12, m(B) = 1) fails; the hidden-key bound (CHG-009, A's ι = 0) holds.
    function _assertBounds(uint256 a, uint256 b, int256 iotaB) internal view {
        (uint256 cA, uint256 nA) = v.sortKey(a);
        (uint256 cB, uint256 nB) = v.sortKey(b);
        uint256 kcA = _k(v.LColl() - v.positions(a).snapLColl, 12, v.positions(a).stake);
        uint256 knB = _k(v.LDebt() - v.positions(b).snapLDebt, 1, v.positions(b).stake);
        assertEq(kcA, 4, "kc(A)");
        assertEq(knB, 35_003, "kn(B)");
        assertLt((cA + kcA) * (nB + knB), cB * nA, "CHG-008's bound fails on a correct execution");
        assertTrue(I13HiddenKeys.pairHolds(_hOf(a), 0, _hOf(b), iotaB), "hidden-key bound holds");
    }

    function _k(uint256 dL, uint256 m, uint256 stake) internal pure returns (uint256) {
        return 1 + Math.mulDiv(dL + m + stake * m, 1, DP, Math.Rounding.Ceil);
    }

    function _hOf(uint256 id) internal view returns (I13HiddenKeys.Rat memory) {
        VaultManager.Position memory p = v.positions(id);
        return I13HiddenKeys.h(p.coll, p.normDebt, p.snapLColl, p.snapLDebt);
    }

    /// @dev ι of B from its neighbours at insertion, taking the neighbours' own ι as 0. That can only
    ///      make ι_B smaller, so the hidden-key check in this test is at least as strict as the
    ///      handler's (which tracks every member's ι).
    function _iotaAtInsertion(uint256 id) internal view returns (int256) {
        I13HiddenKeys.Side memory x = _side(sorted.getPrev(id));
        I13HiddenKeys.Side memory y = _side(sorted.getNext(id));
        return I13HiddenKeys.iota(x, y);
    }

    function _side(uint256 id) internal view returns (I13HiddenKeys.Side memory s) {
        if (id == 0) return s;
        s.h = _hOf(id);
        (uint256 c, uint256 n) = v.sortKey(id);
        s.obs = I13HiddenKeys.hObs(c, n, v.LColl(), v.LDebt());
        s.present = true;
    }
}
