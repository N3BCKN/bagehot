// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {VaultManagerHarness} from "../utils/VaultManagerHarness.sol";
import {MockLedgerViews, MockWETH} from "../utils/VaultMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared harness deployment: a VaultManagerHarness wired to real token, list and oracle.
abstract contract HarnessBase is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant GAS_RESERVE = 0.0375e18;
    MockWETH internal weth;
    StableToken internal token;
    VaultManagerHarness internal v;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant SHUTDOWN = address(0x5D);

    function setUp() public virtual {
        vm.warp(10_000_000);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        MockAggregator feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, block.timestamp - 100_000);
        feed.setRound(1, 2000e8, block.timestamp - 60);
        OracleAdapter oracle =
            new OracleAdapter(address(feed), address(seq), 3600, 3600, 10e18, 1_000_000e18, 100_000, 3175);
        SortedPositions sorted = new SortedPositions(30);
        MockLedgerViews ledger = new MockLedgerViews();
        v = new VaultManagerHarness(
            address(weth), address(token), address(oracle), 1.1e18, 2000e18, GAS_RESERVE
        );
        address pool = makeAddr("pool");
        v.wire(address(sorted), pool, pool, address(0xDE11), address(ledger), SHUTDOWN);
        sorted.wire(address(v));
        token.wire(address(v), pool, address(ledger), SHUTDOWN);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            weth.mint(who[i], 1000e18);
            vm.prank(who[i]);
            weth.approve(address(v), type(uint256).max);
        }
    }
}

/// @notice Rounding directions R1, R2, R3 at a non-round index, and R8 with a remainder (review V-1).
///         At index RAY up and down coincide, so these are the tests that can tell them apart.
contract VaultManagerRoundingTest is HarnessBase {
    uint256 internal constant I = 1_234_567_890_123_456_789_012_345_679; // ≈ 1.2346 RAY, no factor of RAY

    function setUp() public override {
        super.setUp();
        v.setIndex(I);
    }

    function test_R2_openRoundsNormalisedDebtUp() public {
        uint256 debt = 4000e18;
        assertGt(mulmod(debt, RAY, I), 0, "inexact, so up and down differ");
        vm.prank(alice);
        v.openPosition(10e18, debt, 0, 0);
        uint256 n = v.positions(1).normDebt;
        assertEq(n, Math.mulDiv(debt, RAY, I) + 1, "ceil");
        assertGe(v.debtOf(1), debt, "the position never owes less than was minted");
    }

    function test_R2_borrowRoundsNormalisedDebtUp() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        uint256 n0 = v.positions(1).normDebt;
        uint256 amount = 777e18 + 3;
        assertGt(mulmod(amount, RAY, I), 0);
        vm.prank(alice);
        v.borrow(1, amount, 0, 0);
        assertEq(v.positions(1).normDebt - n0, Math.mulDiv(amount, RAY, I) + 1, "ceil");
    }

    function test_R3_repayRoundsNormalisedDebtDown() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        uint256 n0 = v.positions(1).normDebt;
        uint256 amount = 1000e18 + 7;
        assertGt(mulmod(amount, RAY, I), 0);
        vm.prank(alice);
        v.repay(1, amount, 0, 0);
        assertEq(n0 - v.positions(1).normDebt, Math.mulDiv(amount, RAY, I), "floor");
        // an amount below index/RAY removes nothing but is still burned: rounding favours the protocol
        uint256 supply = token.totalSupply();
        uint256 n1 = v.positions(1).normDebt;
        vm.prank(alice);
        v.repay(1, 1, 0, 0);
        assertEq(v.positions(1).normDebt, n1, "dn == 0");
        assertEq(token.totalSupply(), supply - 1);
    }

    function test_R1_closeBurnsTheCeiling() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.prank(bob);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.prank(bob);
        token.transfer(alice, 10e18); // the rounding owes alice a few wei more than she minted
        uint256 n = v.positions(1).normDebt;
        assertGt(mulmod(n, I, RAY), 0, "inexact");
        uint256 owed = Math.mulDiv(n, I, RAY) + 1;
        assertEq(v.debtOf(1), owed);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        v.close(1);
        assertEq(before - token.balanceOf(alice), owed, "close burns ceil(n * index / RAY)");
    }

    /// @dev The dust pitfall at a non-round index: close is still possible after any repays.
    function testFuzz_closeAlwaysPossibleAfterRepays(uint256 a1, uint256 a2, uint256 a3) public {
        vm.prank(alice);
        v.openPosition(10e18, 10_000e18, 0, 0);
        vm.prank(bob);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.prank(bob);
        token.transfer(alice, 100e18);
        uint256[3] memory r = [a1, a2, a3];
        for (uint256 i; i < 3; ++i) {
            uint256 room = v.debtOf(1) - 2000e18;
            if (room == 0) break;
            vm.prank(alice);
            v.repay(1, bound(r[i], 1, room), 0, 0);
        }
        assertGe(token.balanceOf(alice), v.debtOf(1));
        vm.prank(alice);
        v.close(1);
        assertEq(uint8(v.positions(1).status), 2);
    }

    /// @dev R8 with a remainder: stake 4e18 + 1 against ΔL with a fractional product.
    function test_R8_pendingRoundsDown() public {
        v.setIndex(RAY);
        vm.prank(alice);
        v.openPosition(4e18 + 1, 4000e18, 0, 0); // stake = coll = 4e18 + 1
        // pendingColl = floor((4e18+1)·0.1e18 / 1e18) = 4e17 (the 0.1 wei is dropped);
        // pendingNorm = floor((4e18+1)·(50e18+1) / 1e18) = 200e18 + 4 + 50 = 200e18 + 54
        v.setRedistribution(0.1e18, 50e18 + 1, 4e17 + 5, 200e18 + 60, 0, 0);
        weth.mint(address(v), 4e17 + 5);
        (uint256 c, uint256 n) = v.effective(1);
        assertEq(c, 4e18 + 1 + 4e17, "floor");
        assertEq(n, 4000e18 + 200e18 + 54, "floor");
    }
}

/// @notice Every position operation applies pending rewards before acting and recomputes the stake
///         after (review V-4), and settlement hands over the pending collateral too (V-3). The
///         snapshot ratio (4 : 5) makes a recomputed stake differ from the old one.
contract VaultManagerPendingOpsTest is HarnessBase {
    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        v.openPosition(4e18, 4000e18, 0, 0); // stake 4e18
        // pending for alice: 0.4e18 WETH and 200e18 normalised debt, plus dust 7 / 9
        v.setRedistribution(0.1e18, 50e18, 0.4e18 + 7, 200e18 + 9, 4e18, 5e18);
        weth.mint(address(v), 0.4e18 + 7);
    }

    uint256 internal constant STAKE_AFTER = 3.52e18; // mulDivDown(4.4e18, 4e18, 5e18)

    function test_withdraw_succeedsOnlyBecausePendingCollateralIsAppliedFirst() public {
        // stored: coll 4, debt 4000 → max out 1.8; with pending: coll 4.4, debt 4200 → max out 2.09
        vm.prank(alice);
        v.withdrawCollateral(1, 2e18, 0, 0);
        assertEq(v.positions(1).coll, 2.4e18);
        assertEq(v.positions(1).stake, Math.mulDiv(2.4e18, 4e18, 5e18));
    }

    function test_borrow_capacityIncludesPendingAndStakeIsRecomputed() public {
        // stored capacity 7272.7 − 4000 = 3272.7; with pending 8000 − 4200 = 3800
        vm.prank(alice);
        v.borrow(1, 3500e18, 0, 0);
        VaultManager.Position memory p = v.positions(1);
        assertEq(p.coll, 4.4e18);
        assertEq(p.normDebt, 4200e18 + 3500e18);
        assertEq(p.stake, STAKE_AFTER, "updateStake ran");
        assertEq(v.totalStakes(), STAKE_AFTER);
    }

    function test_repay_appliesPendingAndRecomputesStake() public {
        vm.prank(alice);
        v.repay(1, 1000e18, 0, 0); // max is 4200 − 2000 = 2200 only with pending applied
        VaultManager.Position memory p = v.positions(1);
        assertEq(p.normDebt, 3200e18);
        assertEq(p.stake, STAKE_AFTER);
        vm.prank(alice);
        v.repay(1, 1200e18, 0, 0); // reaches exactly MIN_DEBT: possible only because 200 was added
        assertEq(v.debtOf(1), 2000e18);
    }

    function test_close_paysPendingCollateralAndBurnsPendingDebt() public {
        vm.prank(bob);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.prank(bob);
        token.transfer(alice, 200e18);
        uint256 wethBefore = weth.balanceOf(alice);
        vm.expectEmit(address(v));
        emit VaultManager.PositionClosed(1, 4200e18, 4.4e18, GAS_RESERVE);
        vm.prank(alice);
        v.close(1);
        assertEq(weth.balanceOf(alice), wethBefore + 4.4e18 + GAS_RESERVE);
        assertEq(token.balanceOf(alice), 0);
        assertEq(v.pendingColl(), 7, "only dust stays pending");
        assertEq(v.pendingNormDebt(), 9);
        assertEq(
            weth.balanceOf(address(v)),
            v.totalCollateral() + v.pendingColl() + v.activeCount() * GAS_RESERVE,
            "I1"
        );
    }

    function test_settlement_handsOverPendingCollateralToo() public {
        vm.prank(SHUTDOWN);
        v.onShutdown();
        vm.expectEmit(address(v));
        emit VaultManager.VaultSettled(4e18 + 0.4e18 + 7, 1);
        vm.prank(SHUTDOWN);
        uint256 coll = v.onSettlement();
        assertEq(coll, 4.4e18 + 7, "totalCollateral + pendingColl, dust included");
        assertEq(v.pendingColl(), 0);
        assertEq(v.totalCollateral(), 0);
        assertEq(weth.balanceOf(address(v)), v.activeCount() * GAS_RESERVE, "I1 after settlement");
    }
}
