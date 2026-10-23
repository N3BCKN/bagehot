// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {PriceUnusable} from "../../src/lib/Errors.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice I9 (rescue paths never read the oracle), I12 (price-sensitive operations revert on an
///         unusable price), and random operation sequences checking I1, I2 and the supporting
///         identities after every step (docs/invariants.md).
contract VaultManagerPropertiesTest is VaultFixture {
    bytes internal constant FETCH = abi.encodeCall(OracleAdapter.fetchPrice, ());

    // ------------------------------------------------------------------ I9

    /// @dev repay, addCollateral and close succeed with the feed failing and make no oracle read —
    ///      also for a position far below MCR.
    function test_I9_rescuePathsNeverReadTheOracle() public {
        _open(alice, _minColl(4000e18), 4000e18);
        _open(bob, 4e18, 4000e18);
        _setPrice(1000e18); // alice's position is now at ICR 0.55
        feed.setMode(MockAggregator.Mode.Revert); // and the oracle is unusable
        vm.expectCall(address(oracle), FETCH, 0);
        vm.startPrank(alice);
        vm_.addCollateral(1, 1e18, 0, 0);
        vm_.repay(1, 1000e18, 0, 0);
        vm_.close(1);
        vm.stopPrank();
        vm.prank(carol);
        vm_.addCollateral(2, 1, 0, 0);
        assertEq(uint8(vm_.positions(1).status), 2);
    }

    // ------------------------------------------------------------------ I12

    function _expectAllPriceOpsRevert() internal {
        uint256 supply = token.totalSupply();
        uint256 coll = vm_.totalCollateral();
        vm.startPrank(alice);
        vm.expectRevert(PriceUnusable.selector);
        vm_.openPosition(4e18, 4000e18, 0, 0);
        vm.expectRevert(PriceUnusable.selector);
        vm_.borrow(1, 1e18, 0, 0);
        vm.expectRevert(PriceUnusable.selector);
        vm_.withdrawCollateral(1, 1, 0, 0);
        vm.stopPrank();
        assertEq(token.totalSupply(), supply, "nothing minted");
        assertEq(vm_.totalCollateral(), coll, "nothing moved");
    }

    function test_I12_sequencerDown() public {
        _open(alice, 4e18, 4000e18);
        seq.setStatus(1, NOW);
        _expectAllPriceOpsRevert();
    }

    function test_I12_stalePrice() public {
        _open(alice, 4e18, 4000e18);
        feed.setRound(2, 2000e8, NOW - 3601);
        _expectAllPriceOpsRevert();
    }

    function test_I12_outOfBoundsAndFailedCall() public {
        _open(alice, 4e18, 4000e18);
        feed.setRound(2, 5e8, NOW - 60); // 5 USD < MIN_PRICE 10
        _expectAllPriceOpsRevert();
        feed.setMode(MockAggregator.Mode.Revert);
        _expectAllPriceOpsRevert();
    }

    // ------------------------------------------------------------------ random sequences: I1, I2

    function _actor(uint256 r) internal view returns (address) {
        return [alice, bob, carol][r % 3];
    }

    /// @dev I1 (VaultManager row), I2 at index RAY with no interest (supply = normalised debt
    ///      exactly; the ledger holds no auction debt or deficit), the supporting identities and
    ///      exact list order (no redistribution yet: every member is exact, ADR-0032).
    function _checkInvariants() internal view {
        assertEq(
            weth.balanceOf(address(vm_)),
            vm_.totalCollateral() + vm_.pendingColl() + vm_.activeCount() * GAS_RESERVE,
            "I1 VaultManager WETH"
        );
        assertEq(token.totalSupply() * 1e27, vm_.totalNormDebt() * vm_.index(), "I2: E = 0 at index RAY");
        uint256 sumColl;
        uint256 sumNorm;
        uint256 sumStake;
        uint256 active;
        for (uint256 id = 1; id < vm_.nextId(); ++id) {
            VaultManager.Position memory p = vm_.positions(id);
            if (p.status != VaultManager.Status.Active) continue;
            sumColl += p.coll;
            sumNorm += p.normDebt;
            sumStake += p.stake;
            ++active;
        }
        assertEq(vm_.totalCollateral(), sumColl, "totalCollateral");
        assertEq(vm_.totalNormDebt(), sumNorm + vm_.pendingNormDebt(), "totalNormDebt");
        assertEq(vm_.totalStakes(), sumStake, "totalStakes");
        assertEq(vm_.activeCount(), active, "activeCount");
        assertEq(sorted.getSize(), active, "activeCount = sorted.size");
        uint256 a = sorted.getFirst();
        if (a == 0) return;
        for (uint256 b = sorted.getNext(a); b != 0; (a, b) = (b, sorted.getNext(b))) {
            (uint256 cA, uint256 nA) = vm_.sortKey(a);
            (uint256 cB, uint256 nB) = vm_.sortKey(b);
            assertTrue(cA * nB > cB * nA || (cA * nB == cB * nA && a < b), "exact list order");
        }
    }

    function _activeOf(address who, uint256 r) internal view returns (uint256) {
        uint256 n = vm_.nextId();
        for (uint256 k; k < n; ++k) {
            uint256 id = 1 + (r + k) % (n - 1 == 0 ? 1 : n - 1);
            if (
                id < n && vm_.positions(id).status == VaultManager.Status.Active
                    && vm_.positions(id).owner == who
            ) {
                return id;
            }
        }
        return 0;
    }

    /// @dev Every step is constructed to be valid, so a revert is a failure.
    function testFuzz_randomSequences_keepI1I2AndIdentities(uint256 seed) public {
        for (uint256 i; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address who = _actor(seed);
            uint256 op = (seed >> 8) % 6;
            uint256 id = _activeOf(who, seed >> 16);
            uint256 amt = seed >> 32;
            if (op == 0 || id == 0) {
                uint256 debt = bound(amt, MIN_DEBT, 50_000e18);
                uint256 coll = _minColl(debt) + bound(amt >> 64, 0, 20e18);
                vm.prank(who);
                vm_.openPosition(coll, debt, 0, 0);
            } else if (op == 1) {
                vm.prank(_actor(seed >> 3)); // anyone
                vm_.addCollateral(id, bound(amt, 1, 5e18), 0, 0);
            } else if (op == 2) {
                VaultManager.Position memory p = vm_.positions(id);
                uint256 free = p.coll - _minColl(vm_.debtOf(id));
                if (free == 0) continue;
                vm.prank(who);
                vm_.withdrawCollateral(id, bound(amt, 1, free), 0, 0);
            } else if (op == 3) {
                VaultManager.Position memory p = vm_.positions(id);
                uint256 cap = (p.coll * PRICE) / MCR;
                uint256 debt = vm_.debtOf(id);
                if (cap <= debt) continue;
                vm.prank(who);
                vm_.borrow(id, bound(amt, 1, cap - debt), 0, 0);
            } else if (op == 4) {
                uint256 room = vm_.debtOf(id) - MIN_DEBT;
                uint256 bal = token.balanceOf(who);
                uint256 hi = room < bal ? room : bal;
                if (hi == 0) continue;
                vm.prank(who);
                vm_.repay(id, bound(amt, 1, hi), 0, 0);
            } else {
                uint256 owed = vm_.debtOf(id);
                uint256 bal = token.balanceOf(who);
                if (bal < owed) {
                    // top up from another holder so close is possible (a market purchase)
                    address other = who == alice ? bob : alice;
                    uint256 need = owed - bal;
                    if (token.balanceOf(other) < need) continue;
                    vm.prank(other);
                    token.transfer(who, need);
                }
                vm.prank(who);
                vm_.close(id);
            }
            _checkInvariants();
        }
    }
}
