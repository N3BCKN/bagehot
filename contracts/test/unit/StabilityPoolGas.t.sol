// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolFixture} from "../utils/PoolFixture.sol";

/// @notice CHG-006 / ADR-0033: the measurement `POOL_HOOK_GAS` is derived from — the real pool's
///         worst-case `onInterest`: every slot it touches cold (`vm.cool`), and the three writes
///         zero-to-non-zero (a fresh `(epoch, scale)` sum `G`, the carry `lastInterestError` and
///         `interestGainsBalance`). Results are logged for spec §3.1 and asserted against the value.
contract StabilityPoolGasTest is PoolFixture {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    /// @notice The spec's value (§3.1): at least twice the worst case measured here.
    uint256 internal constant POOL_HOOK_GAS = 200_000;

    function setUp() public {
        _deployPool(MIN_DEPOSIT);
        _fund(ALICE, 1e30);
        _fund(BOB, 1e30);
    }

    /// @dev Epoch 1, scale 0: `G[1][0]`, the carry and the gains balance are all zero before the call,
    ///      and 1e18 over 3e18 of deposits leaves a non-zero carry.
    function test_gas_onInterest_worstCase_freshEpoch() public {
        _deposit(ALICE, 10e18);
        tv.offset(10e18, 1e18); // d == T: epoch 1
        _deposit(BOB, 3e18);
        assertEq(pool.epochToScaleToG(1, 0), 0);
        assertEq(pool.lastInterestError(), 0);
        assertEq(pool.interestGainsBalance(), 0);
        vm.cool(address(pool));
        (uint256 used, bool booked) = tv.measureInterest(1e18);
        assertTrue(booked);
        assertGt(pool.lastInterestError(), 0, "the carry was written non-zero");
        emit log_named_uint("onInterest worst case (fresh epoch, cold, 3 zero-to-non-zero writes)", used);
        assertLe(2 * used, POOL_HOOK_GAS, "POOL_HOOK_GAS is at least twice the worst case");
    }

    /// @dev The same after a scale change: `G[0][1]` fresh, the carry and balance zero.
    function test_gas_onInterest_worstCase_freshScale() public {
        _deposit(ALICE, 300e18);
        tv.offset(300e18 - 3e9, 0); // T − d = 3e9: P < P_MIN, scale 0 -> 1
        _deposit(BOB, 3e18);
        assertEq(pool.currentScale(), 1, "a scale change happened");
        assertEq(pool.epochToScaleToG(0, 1), 0);
        assertEq(pool.lastInterestError(), 0);
        assertEq(pool.interestGainsBalance(), 0);
        vm.cool(address(pool));
        (uint256 used, bool booked) = tv.measureInterest(1e18 + 7);
        assertTrue(booked);
        emit log_named_uint("onInterest worst case (fresh scale, cold)", used);
        assertLe(2 * used, POOL_HOOK_GAS, "POOL_HOOK_GAS is at least twice the worst case");
    }

    /// @dev The declining path (`totalDeposits < MIN_DEPOSIT`) for comparison.
    function test_gas_onInterest_decline() public {
        vm.cool(address(pool));
        (uint256 used, bool booked) = tv.measureInterest(1e18);
        assertFalse(booked);
        emit log_named_uint("onInterest decline (cold)", used);
    }
}
