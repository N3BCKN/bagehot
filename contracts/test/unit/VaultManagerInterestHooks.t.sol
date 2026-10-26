// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {HostileInterestSink, MockWETH} from "../utils/VaultMocks.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// @notice The interest hooks under hostile sinks. F3: a pool or ledger whose `onInterest` re-enters
///         the VaultManager hits the lock on every mutator. F4 (flipped by ADR-0033 / CHG-006): a
///         reverting pool no longer blocks anything — its share is redirected to the reserve and the
///         rescue paths run in normal mode; in the window they do not touch the pool at all.
contract VaultManagerInterestHooksTest is Test {
    VaultManager internal v;
    StableToken internal token;
    MockWETH internal weth;
    MockAggregator internal feed;
    HostileInterestSink internal pool;
    HostileInterestSink internal ledger;
    address internal alice = makeAddr("alice");
    address internal constant SHUTDOWN = address(0x5D);

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, 1);
        feed.setRound(1, 2000e8, block.timestamp);
        OracleAdapter oracle = new OracleAdapter(
            address(feed), address(seq), type(uint64).max, 0, 10e18, 1_000_000e18, 100_000, 3175
        );
        SortedPositions sorted = new SortedPositions(30);
        pool = new HostileInterestSink();
        ledger = new HostileInterestSink();
        v = new VaultManager(
            address(weth),
            address(token),
            address(oracle),
            1.1e18,
            2000e18,
            0.0375e18,
            1_547_125_957_863_212_449,
            7500,
            200_000
        );
        v.wire(address(sorted), address(pool), address(pool), address(0xDE11), address(ledger), SHUTDOWN);
        sorted.wire(address(v));
        token.wire(address(v), address(pool), address(ledger), SHUTDOWN);
        weth.mint(alice, 1000e18);
        vm.prank(alice);
        weth.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
    }

    function _targets() internal pure returns (bytes[] memory t) {
        t = new bytes[](10);
        t[0] = abi.encodeCall(VaultManager.openPosition, (4e18, 2000e18, 0, 0));
        t[1] = abi.encodeCall(VaultManager.addCollateral, (1, 1, 0, 0));
        t[2] = abi.encodeCall(VaultManager.withdrawCollateral, (1, 1, 0, 0));
        t[3] = abi.encodeCall(VaultManager.borrow, (1, 1, 0, 0));
        t[4] = abi.encodeCall(VaultManager.repay, (1, 1, 0, 0));
        t[5] = abi.encodeCall(VaultManager.close, (1));
        t[6] = abi.encodeCall(VaultManager.reclaimGasReserve, (1));
        t[7] = abi.encodeCall(VaultManager.onShutdown, ());
        t[8] = abi.encodeCall(VaultManager.onSettlement, ());
        t[9] = abi.encodeCall(VaultManager.accrue, ());
    }

    function _assertBlocked(HostileInterestSink sink) internal view {
        assertTrue(sink.fired(), "the hook ran: accrual reached it");
        assertEq(
            sink.innerRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_F3_poolOnInterestCannotReenterAnyMutator() public {
        bytes[] memory t = _targets();
        for (uint256 i; i < t.length; ++i) {
            vm.warp(block.timestamp + 1 days);
            feed.setRound(1, 2000e8, block.timestamp);
            pool.arm(address(v), t[i]);
            vm.prank(alice);
            v.addCollateral(1, 1, 0, 0); // accrues first: mint to the pool, then onInterest
            _assertBlocked(pool);
        }
    }

    function test_F3_ledgerOnInterestCannotReenterAnyMutator() public {
        bytes[] memory t = _targets();
        for (uint256 i; i < t.length; ++i) {
            vm.warp(block.timestamp + 1 days);
            ledger.arm(address(v), t[i]);
            v.accrue();
            _assertBlocked(ledger);
        }
    }

    /// @dev F4 after ADR-0033: a pool whose `onInterest` reverts makes accrual redirect the pool's share
    ///      to the reserve, so `repay` succeeds in normal mode — and after the trigger the rescue paths
    ///      never call the pool.
    function test_F4_revertingPool_isRedirected_normalModeAndWindowBothLive() public {
        vm.warp(block.timestamp + 1 days);
        pool.setRevertInterest(true);
        uint256 poolBefore = token.balanceOf(address(pool));
        uint256 ledgerBefore = token.balanceOf(address(ledger));
        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        vm.prank(alice);
        v.repay(1, 1, 0, 0);
        uint256 interest = token.totalSupply() + 1 - supplyBefore; // repay burned 1
        assertGt(interest, 0, "interest accrued");
        assertEq(token.balanceOf(address(pool)), poolBefore, "nothing minted to the failing pool");
        assertEq(
            token.balanceOf(address(ledger)) - ledgerBefore, interest, "the whole interest to the reserve"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool redirected;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VaultManager.PoolInterestRedirected.selector) redirected = true;
        }
        assertTrue(redirected, "PoolInterestRedirected emitted");
        // the accrued interest now sits on alice's debt: a second borrower funds her close
        address bob = makeAddr("bob");
        weth.mint(bob, 100e18);
        vm.startPrank(bob);
        weth.approve(address(v), type(uint256).max);
        v.openPosition(10e18, 4000e18, 0, 0);
        token.transfer(alice, 100e18);
        vm.stopPrank();
        vm.prank(SHUTDOWN);
        v.onShutdown();
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        v.repay(1, 1, 0, 0);
        v.addCollateral(1, 1, 0, 0);
        v.close(1);
        vm.stopPrank();
        assertEq(uint8(v.positions(1).status), 2);
    }
}
