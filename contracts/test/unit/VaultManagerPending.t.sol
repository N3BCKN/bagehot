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
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice §6.5.3 (apply pending) and §6.5.4 (stakes after a snapshot) with a redistribution state
///         set through a test harness — P20 writes it for real; these paths are exercised now.
contract VaultManagerPendingTest is Test {
    MockWETH internal weth;
    StableToken internal token;
    VaultManagerHarness internal v;
    SortedPositions internal sorted;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        MockAggregator feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, block.timestamp - 100_000);
        feed.setRound(1, 2000e8, block.timestamp - 60);
        OracleAdapter oracle =
            new OracleAdapter(address(feed), address(seq), 3600, 3600, 10e18, 1_000_000e18, 100_000, 3175);
        sorted = new SortedPositions(30);
        MockLedgerViews ledger = new MockLedgerViews();
        v = new VaultManagerHarness(
            address(weth), address(token), address(oracle), 1.1e18, 2000e18, 0.0375e18, 0, 7500, 200_000
        );
        address pool = makeAddr("pool");
        v.wire(address(sorted), pool, pool, address(0xDE11), address(ledger), address(0x5D));
        sorted.wire(address(v));
        token.wire(address(v), pool, address(ledger), address(0x5D));
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            weth.mint(who[i], 1000e18);
            vm.prank(who[i]);
            weth.approve(address(v), type(uint256).max);
        }
        vm.prank(alice);
        v.openPosition(4e18, 4000e18, 0, 0); // stake 4e18 (no snapshot yet)
        // a redistribution happened: 0.1 WETH and 50 normalised debt per unit stake, plus dust;
        // its collateral sits in the vault, so I1 keeps holding
        v.setRedistribution(0.1e18, 50e18, 0.4e18 + 7, 200e18 + 9, 4e18, 4.4e18);
        weth.mint(address(v), 0.4e18 + 7);
    }

    function test_effectiveValuesIncludePending() public view {
        (uint256 c, uint256 n) = v.effective(1);
        assertEq(c, 4.4e18); // 4e18 + mulDivDown(4e18, 0.1e18, 1e18)
        assertEq(n, 4200e18); // 4_000e18 + mulDivDown(4e18, 50e18, 1e18)
        assertEq(v.debtOf(1), 4200e18);
        (uint256 kc, uint256 kn) = v.sortKey(1);
        assertEq(kc, c);
        assertEq(kn, n);
    }

    function test_applyPending_onTheNextOperation() public {
        vm.expectEmit(address(v));
        emit VaultManager.RewardsApplied(1, 0.4e18, 200e18);
        vm.prank(bob);
        v.addCollateral(1, 1, 0, 0);
        VaultManager.Position memory p = v.positions(1);
        assertEq(p.coll, 4.4e18 + 1);
        assertEq(p.normDebt, 4200e18);
        assertEq(p.snapLColl, 0.1e18);
        assertEq(p.snapLDebt, 50e18);
        assertEq(v.pendingColl(), 7, "dust stays pending forever");
        assertEq(v.pendingNormDebt(), 9);
        assertEq(v.totalCollateral(), 4.4e18 + 1);
        assertEq(v.totalNormDebt(), 4200e18 + 9, "unchanged by applying: pending debt was already in it");
        // update stake after applying: mulDivDown(4.4e18 + 1, 4e18, 4.4e18) = 4e18
        assertEq(p.stake, 4e18);
        assertEq(v.totalStakes(), 4e18);
        assertEq(weth.balanceOf(address(v)), v.totalCollateral() + v.pendingColl() + 0.0375e18, "I1");
        // a second operation finds nothing pending: no RewardsApplied
        vm.recordLogs();
        vm.prank(bob);
        v.addCollateral(1, 1, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != VaultManager.RewardsApplied.selector, "nothing pending the second time"
            );
        }
        assertGt(logs.length, 0);
    }

    /// @dev A new position after the snapshot gets a proportionally smaller stake (§6.5.4).
    function test_computeStake_afterASnapshot() public {
        vm.prank(bob);
        uint256 id = v.openPosition(4.4e18, 4000e18, 0, 0);
        assertEq(v.positions(id).stake, 4e18); // mulDivDown(4.4e18, 4e18, 4.4e18)
        assertEq(v.positions(id).snapLColl, 0.1e18, "a new position starts at the current L");
        (uint256 c,) = v.effective(id);
        assertEq(c, 4.4e18, "and has nothing pending");
    }
}
