// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {FixedOracle, HostileStable, HostileWETH, ReentryHook} from "../utils/HostileTokens.sol";
import {MockLedgerViews} from "../utils/VaultMocks.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The transient lock is on every state-changing external function (spec §2.5): each of the
///         ten mutators, called from inside another operation's token callback, reverts
///         ReentrancyGuardReentrantCall. The lock is checked before the caller check, so even the
///         restricted hooks revert with it.
contract VaultManagerReentrancyTest is Test {
    HostileWETH internal weth;
    HostileStable internal stable;
    SortedPositions internal sorted;
    VaultManager internal v;
    address internal constant SHUTDOWN = address(0x5D);
    address internal alice = makeAddr("alice");

    function setUp() public {
        weth = new HostileWETH();
        stable = new HostileStable();
        sorted = new SortedPositions(30);
        MockLedgerViews ledger = new MockLedgerViews();
        v = new VaultManager(
            address(weth),
            address(stable),
            address(new FixedOracle(2000e18)),
            1.1e18,
            2000e18,
            0.0375e18,
            0,
            7500
        );
        address pool = makeAddr("pool");
        v.wire(address(sorted), pool, pool, address(0xDE11), address(ledger), SHUTDOWN);
        sorted.wire(address(v));
        weth.mint(alice, 1000e18);
        vm.prank(alice);
        weth.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0); // position 1
    }

    /// @dev The ten state-changing externals, as re-entry targets.
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

    function _assertReentryBlocked(ReentryHook hook) internal view {
        assertTrue(hook.fired(), "the callback ran");
        assertEq(
            hook.innerRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entry reverted on the lock"
        );
    }

    /// @dev Each mutator as the re-entered target, from addCollateral's WETH pull.
    function test_everyMutatorIsGuarded() public {
        bytes[] memory t = _targets();
        for (uint256 i; i < t.length; ++i) {
            weth.arm(address(v), t[i]);
            vm.prank(alice);
            v.addCollateral(1, 1, 0, 0);
            _assertReentryBlocked(weth);
        }
    }

    /// @dev Each mutator that calls out holds the lock across the call: open (WETH pull, then mint),
    ///      withdraw (WETH push), borrow (mint), repay (burn), close (burn, then WETH push).
    function test_everyOutgoingCallHappensUnderTheLock() public {
        bytes memory probe = abi.encodeCall(VaultManager.addCollateral, (1, 1, 0, 0));

        weth.arm(address(v), probe);
        vm.prank(alice);
        v.openPosition(4e18, 2000e18, 0, 0);
        _assertReentryBlocked(weth);
        stable.arm(address(v), probe);
        vm.prank(alice);
        v.openPosition(4e18, 2000e18, 0, 0);
        _assertReentryBlocked(stable);

        weth.arm(address(v), probe);
        vm.prank(alice);
        v.withdrawCollateral(1, 1, 0, 0);
        _assertReentryBlocked(weth);

        stable.arm(address(v), probe);
        vm.prank(alice);
        v.borrow(1, 1e18, 0, 0);
        _assertReentryBlocked(stable);

        stable.arm(address(v), probe);
        vm.prank(alice);
        v.repay(1, 1e18, 0, 0);
        _assertReentryBlocked(stable);

        stable.arm(address(v), probe);
        vm.prank(alice);
        v.close(1);
        _assertReentryBlocked(stable);
    }

    /// @dev The settlement and reclaim paths push WETH under the lock too.
    function test_settlementAndReclaimHoldTheLock() public {
        bytes memory probe = abi.encodeCall(VaultManager.addCollateral, (1, 1, 0, 0));
        vm.prank(SHUTDOWN);
        v.onShutdown();
        weth.arm(address(v), probe);
        vm.prank(SHUTDOWN);
        v.onSettlement();
        _assertReentryBlocked(weth);
        weth.arm(address(v), probe);
        vm.prank(alice);
        v.reclaimGasReserve(1);
        _assertReentryBlocked(weth);
    }
}
