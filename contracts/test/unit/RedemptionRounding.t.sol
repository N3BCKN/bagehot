// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {WadRayMath} from "../../src/lib/WadRayMath.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Rounding directions of the redemption rows of spec §8 at a non-round index, where every
///         direction is observable (each test asserts that the floor and the ceiling differ for its
///         operands, so the opposite direction would fail it):
///         R18 collateral to the redeemer (down), R3 normalised debt removed by the partial (down),
///         R1 debt of a fully redeemed position (up), R19 decayed base rate (up), R20 base-rate
///         increment (up). The index is set by the harness (supply not adjusted: I2 is not checked).
contract RedemptionRoundingTest is RedemptionFixture {
    uint256 internal constant INDEX = 1_234_567_891_234_567_891_234_567_891;
    uint256 internal idBob;

    function setUp() public override {
        super.setUp();
        v.setIndex(INDEX);
        _open(erin, 100e18, 20_000e18);
        idBob = _open(bob, 2.4e18, 4000e18 + 3); // the tail
    }

    function _down(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d);
    }

    function _up(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }

    function test_rounding_partial_R18down_R3down() public {
        uint256 d = 1000e18 + 7;
        uint256 fee = rm.redemptionFeeRate(d);
        VaultManager.Position memory b0 = v.positions(idBob);
        assertTrue(_down(d, RAY, INDEX) != _up(d, RAY, INDEX), "R3 observable");
        assertTrue(_down(d, WAD - fee, PRICE) != _up(d, WAD - fee, PRICE), "R18 observable");
        uint256 erinWeth = weth.balanceOf(erin);
        _redeem(erin, d);
        VaultManager.Position memory b1 = v.positions(idBob);
        assertEq(b0.normDebt - b1.normDebt, _down(d, RAY, INDEX), "R3: normalised debt removed rounds down");
        assertEq(b0.coll - b1.coll, _down(d, WAD - fee, PRICE), "R18: collateral out rounds down");
        assertEq(weth.balanceOf(erin) - erinWeth, b0.coll - b1.coll);
    }

    function test_rounding_full_R1up_R18down() public {
        uint256 n = v.positions(idBob).normDebt;
        uint256 debt = _up(n, INDEX, RAY);
        assertTrue(debt != _down(n, INDEX, RAY), "R1 observable");
        uint256 fee = rm.redemptionFeeRate(10_000e18);
        assertTrue(_down(debt, WAD - fee, PRICE) != _up(debt, WAD - fee, PRICE), "R18 observable");
        uint256 supply = token.totalSupply();
        uint256 bobWeth = weth.balanceOf(bob);
        vm.prank(erin);
        rm.redeem(10_000e18, 1, WAD, 0, 0);
        assertEq(supply - token.totalSupply(), debt, "R1: the closed position's debt rounds up");
        uint256 out = _down(debt, WAD - fee, PRICE);
        assertEq(weth.balanceOf(bob) - bobWeth, 2.4e18 - out + GAS_RESERVE, "R18: surplus gets the rounding");
    }

    function test_rounding_R20up_R19up() public {
        uint256 s0 = token.totalSupply();
        uint256 d = 1000e18 + 7;
        assertTrue(_down(d, WAD, s0 * BETA) != _up(d, WAD, s0 * BETA), "R20 observable");
        uint256 fee = rm.redemptionFeeRate(d);
        assertEq(fee, FEE_FLOOR + _up(d, WAD, s0 * BETA), "R20 in the fee");
        _redeem(erin, d);
        uint256 b = rm.baseRate();
        assertEq(b, _up(d, WAD, s0 * BETA), "R20: stored base rate rounds up");
        vm.warp(block.timestamp + 1);
        uint256 f = WadRayMath.rpow(DECAY, 1);
        assertTrue(_up(b, f, RAY) != _down(b, f, RAY), "R19 observable");
        assertEq(rm.decayedBaseRate(), _up(b, f, RAY), "R19: decayed base rate rounds up");
    }
}
