// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {FixedOracle, HostileWETH} from "../utils/HostileTokens.sol";
import {MockShutdownGate} from "../utils/RedemptionMocks.sol";
import {MockLedgerViews, MockPool} from "../utils/VaultMocks.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The two locks of a redemption (spec §2.5, §5.10): while `redeem` runs — here, from inside
///         the WETH transfer of the collateral to the redeemer — the RedemptionModule's lock blocks a
///         second `redeem`, and the VaultManager's lock blocks `redeemCollateral`, `accrue` and every
///         other VaultManager mutator. The outer redemption completes.
contract RedemptionReentrancyTest is Test {
    HostileWETH internal weth;
    StableToken internal token;
    VaultManager internal v;
    RedemptionModule internal rm;
    address internal alice = makeAddr("alice");
    address internal erin = makeAddr("erin");

    function setUp() public {
        weth = new HostileWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        FixedOracle oracle = new FixedOracle(2000e18);
        SortedPositions sorted = new SortedPositions(30);
        MockLedgerViews ledger = new MockLedgerViews();
        MockPool pool = new MockPool();
        v = new VaultManager(
            address(weth), address(token), address(oracle), 1.1e18, 2000e18, 0.0375e18, 0, 7500
        );
        rm = new RedemptionModule(
            address(token), address(oracle), 0.005e18, 2, 999_983_955_055_097_432_543_272_791
        );
        MockShutdownGate gate = new MockShutdownGate(address(v), address(0), 1.05e18);
        v.wire(address(sorted), address(pool), address(pool), address(rm), address(ledger), address(gate));
        sorted.wire(address(v));
        token.wire(address(v), address(pool), address(ledger), address(gate));
        rm.wire(address(v), address(gate), address(0));
        address[2] memory who = [alice, erin];
        for (uint256 i; i < 2; ++i) {
            weth.mint(who[i], 1000e18);
            vm.prank(who[i]);
            weth.approve(address(v), type(uint256).max);
        }
        vm.prank(erin);
        v.openPosition(100e18, 20_000e18, 0, 0);
        vm.prank(alice);
        v.openPosition(3e18, 4000e18, 0, 0); // the tail
    }

    function _assertBlocked(bytes memory call, address target) internal {
        weth.arm(target, call);
        vm.prank(erin);
        rm.redeem(10e18, 5, 1e18, 0, 0);
        assertTrue(weth.fired(), "the callback ran");
        assertEq(
            weth.innerRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "re-entry reverted on the lock"
        );
    }

    function test_reenterRedeem_blockedByTheModuleLock() public {
        _assertBlocked(abi.encodeCall(RedemptionModule.redeem, (1e18, 5, 1e18, 0, 0)), address(rm));
    }

    function test_reenterVaultManager_blockedByItsLock() public {
        _assertBlocked(
            abi.encodeCall(VaultManager.redeemCollateral, (erin, 1, 0, 2000e18, 1, 0, 0)), address(v)
        );
        _assertBlocked(abi.encodeCall(VaultManager.accrue, ()), address(v));
        _assertBlocked(abi.encodeCall(VaultManager.repay, (2, 1, 0, 0)), address(v));
    }

    function test_outerRedemptionCompletesAfterTheBlockedReentry() public {
        _assertBlocked(abi.encodeCall(RedemptionModule.redeem, (1e18, 5, 1e18, 0, 0)), address(rm));
        assertEq(v.debtOf(2), 4000e18 - 10e18);
        assertGt(rm.baseRate(), 0);
    }
}
