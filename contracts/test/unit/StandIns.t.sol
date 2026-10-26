// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Unauthorized} from "../../src/lib/Errors.sol";
import {LocalWETH} from "../../src/mocks/LocalWETH.sol";
import {StandInShutdownModule} from "../../src/mocks/StandInShutdownModule.sol";
import {StandInStrategy} from "../../src/mocks/StandInStrategy.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The views §5.8's gate reads, settable.
contract GateVaultViews {
    uint256 public activeCount;
    uint256 public systemColl;
    uint256 public systemDebt;

    function set(uint256 a, uint256 c, uint256 d) external {
        (activeCount, systemColl, systemDebt) = (a, c, d);
    }
}

/// @notice An auction house as far as the gate sees it.
contract GateHouse {
    uint256 public activeAuctions;

    function set(uint256 n) external {
        activeAuctions = n;
    }
}

/// @notice P18 local stand-ins: each answers exactly what the deployed contracts read.
contract StandInsTest is Test {
    function test_strategy_isAnEmptyPoolAndAnIdleAuctionHouse() public {
        StandInStrategy s = new StandInStrategy();
        assertFalse(s.acceptsInterest());
        assertFalse(s.inPurchase());
        assertEq(s.totalLot(), 0);
        assertEq(s.activeAuctions(), 0);
    }

    function test_strategy_onInterest_declines() public {
        StandInStrategy s = new StandInStrategy();
        assertFalse(s.onInterest(1), "an empty pool declines (ADR-0033)");
    }

    /// @dev §5.8: live and D > 0 and C · price < CRITICAL_TCR · D, live counting auctions in B.
    function test_gate_belowCritical_boundary() public {
        GateVaultViews v = new GateVaultViews();
        GateHouse h = new GateHouse();
        StandInShutdownModule a = new StandInShutdownModule(address(v), address(0), 1.05e18);
        StandInShutdownModule b = new StandInShutdownModule(address(v), address(h), 1.05e18);
        v.set(1, 105e18, 100e18); // TCR exactly 1.05 at price 1e18: not below
        assertFalse(a.belowCritical(1e18));
        v.set(1, 105e18 - 1, 100e18); // one wei short: below
        assertTrue(a.belowCritical(1e18));
        v.set(0, 1, 100e18); // nothing live in A
        assertFalse(a.belowCritical(1e18));
        h.set(1); // B: a live auction keeps the system live
        assertTrue(b.belowCritical(1e18));
        v.set(1, 0, 0); // no debt
        assertFalse(a.belowCritical(1e18));
    }

    function test_localWeth_mintsToAnyone() public {
        LocalWETH w = new LocalWETH();
        w.mint(address(this), 3);
        assertEq(w.balanceOf(address(this)), 3);
        assertEq(w.decimals(), 18);
    }

    function test_standIns_offLocalChain_revert() public {
        vm.chainId(84_532);
        vm.expectRevert(StandInStrategy.StandInLocalOnly.selector);
        new StandInStrategy();
        vm.expectRevert(StandInShutdownModule.StandInInvalid.selector);
        new StandInShutdownModule(address(1), address(0), 1.05e18);
    }

    /// @dev The real ShutdownModule constructor requires CRITICAL_TCR >= WAD (§3.4 index 4).
    function test_gate_criticalTcrBelowWad_reverts() public {
        vm.expectRevert(StandInShutdownModule.StandInInvalid.selector);
        new StandInShutdownModule(address(1), address(0), 1e18 - 1);
    }
}
