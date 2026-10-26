// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {
    InsufficientBalance,
    InvalidParameter,
    PriceUnusable,
    SystemShutdown,
    Unauthorized,
    ZeroAmount
} from "../../src/lib/Errors.sol";
import {WadRayMath} from "../../src/lib/WadRayMath.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice RedemptionModule (spec §4.6, §5.5, §6.7.1–6.7.2) and VaultManager.redeemCollateral
///         (§5.1.9, §6.7.3): construction, wiring, every error in its order, the fee, the loop's
///         behaviour, the two transient locks on the normal path.
contract RedemptionModuleTest is RedemptionFixture {
    uint256 internal idErin;
    uint256 internal idCarol;
    uint256 internal idAlice;
    uint256 internal idBob;

    /// @dev Tail first: bob (ICR 1.2), alice (1.5), carol (4.0), erin (10.0) at PRICE.
    function setUp() public override {
        super.setUp();
        idErin = _open(erin, 100e18, 20_000e18);
        idCarol = _open(carol, 10e18, 5000e18);
        idAlice = _open(alice, 3e18, 4000e18);
        idBob = _open(bob, 2.4e18, 4000e18);
    }

    function deployModule(uint256[5] memory a) external returns (RedemptionModule) {
        return new RedemptionModule(address(uint160(a[0])), address(uint160(a[1])), a[2], a[3], a[4]);
    }

    function _expectConstructorRevert(uint256[5] memory a, uint8 index) internal {
        try this.deployModule(a) returns (RedemptionModule) {
            fail("constructor did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(InvalidParameter.selector, index));
        }
    }

    function _fee(uint256 amount, uint256 s0, uint256 decayed) internal pure returns (uint256) {
        uint256 inc = Math.mulDiv(amount, WAD, s0 * BETA, Math.Rounding.Ceil);
        return Math.min(FEE_FLOOR + Math.min(decayed + inc, WAD), WAD);
    }

    // ------------------------------------------------------------------ construction and wiring

    function test_constructor_rejectsEachArgumentAtItsBoundary() public {
        // fresh literals each time: assigning a memory array aliases it
        uint256[5] memory good =
            [uint256(uint160(address(token))), uint160(address(oracle)), FEE_FLOOR, BETA, DECAY];
        uint256[5] memory a = [0, good[1], good[2], good[3], good[4]];
        _expectConstructorRevert(a, 0);
        a = [good[0], 0, good[2], good[3], good[4]];
        _expectConstructorRevert(a, 1);
        a = [good[0], good[1], WAD + 1, good[3], good[4]];
        _expectConstructorRevert(a, 2);
        a = [good[0], good[1], good[2], 0, good[4]];
        _expectConstructorRevert(a, 3);
        a = [good[0], good[1], good[2], 101, good[4]];
        _expectConstructorRevert(a, 3);
        a = [good[0], good[1], good[2], good[3], 0];
        _expectConstructorRevert(a, 4);
        a = [good[0], good[1], good[2], good[3], RAY];
        _expectConstructorRevert(a, 4);
        // the inclusive ends of every range are accepted
        RedemptionModule m = this.deployModule([good[0], good[1], WAD, 100, RAY - 1]);
        assertEq(m.REDEMPTION_FEE_FLOOR(), WAD);
        m = this.deployModule([good[0], good[1], 0, 1, 1]);
        assertEq(m.BETA(), 1);
        assertEq(m.BASE_RATE_DECAY(), 1);
        assertEq(m.baseRate(), 0);
        assertEq(m.lastFeeOperationTime(), block.timestamp);
        assertEq(address(m.token()), address(token));
        assertEq(address(m.oracle()), address(oracle));
    }

    function test_wire_checksAndOnce() public {
        RedemptionModule m = new RedemptionModule(address(token), address(oracle), FEE_FLOOR, BETA, DECAY);
        vm.prank(alice);
        vm.expectRevert(WiredBase.NotDeployer.selector);
        m.wire(address(v), address(gate), address(0));
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(0)));
        m.wire(address(0), address(gate), address(0));
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(1)));
        m.wire(address(v), address(0), address(0));
        address[] memory exp = new address[](3);
        (exp[0], exp[1], exp[2]) = (address(v), address(gate), address(house));
        vm.expectEmit(address(m));
        emit WiredBase.Wired(exp);
        m.wire(address(v), address(gate), address(house));
        assertEq(address(m.vaultManager()), address(v));
        assertEq(address(m.shutdownModule()), address(gate));
        assertEq(m.auctionHouse(), address(house));
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        m.wire(address(v), address(gate), address(0));
    }

    function test_redeem_revertsNotWired() public {
        RedemptionModule m = new RedemptionModule(address(token), address(oracle), FEE_FLOOR, BETA, DECAY);
        vm.expectRevert(WiredBase.NotWired.selector);
        m.redeem(1, 1, WAD, 0, 0);
    }

    function test_redeemCollateral_notWiredThenOnlyTheModule() public {
        VaultManager fresh = new VaultManager(
            address(weth),
            address(token),
            address(oracle),
            MCR,
            MIN_DEBT,
            GAS_RESERVE,
            RATE,
            POOL_SHARE_BPS,
            200_000
        );
        vm.expectRevert(WiredBase.NotWired.selector);
        fresh.redeemCollateral(erin, 1, 0, PRICE, 1, 0, 0);
        vm.prank(erin);
        vm.expectRevert(Unauthorized.selector);
        v.redeemCollateral(erin, 1, 0, PRICE, 1, 0, 0);
    }

    // ------------------------------------------------------------------ errors in order

    function test_redeem_errorsInOrder() public {
        uint256 snap = vm.snapshotState();
        vm.prank(address(gate));
        v.onShutdown();
        vm.prank(erin);
        vm.expectRevert(SystemShutdown.selector);
        rm.redeem(0, 0, 0, 0, 0); // shutdown before the argument checks
        vm.revertToState(snap);

        vm.startPrank(erin);
        vm.expectRevert(ZeroAmount.selector);
        rm.redeem(0, 0, 0, 0, 0); // amount before iterations
        vm.expectRevert(RedemptionModule.ZeroIterations.selector);
        rm.redeem(1, 0, 0, 0, 0);
        vm.stopPrank();

        snap = vm.snapshotState();
        vm.warp(block.timestamp + 3601); // stale feed: price unusable before the gate and balance
        vm.prank(dave);
        vm.expectRevert(PriceUnusable.selector);
        rm.redeem(1, 1, 0, 0, 0);
        vm.revertToState(snap);

        // TCR = 115.4 WETH · p / 33,000: below 1.05 at p = 300.25…; the feed has 8 decimals
        _setPrice(300.25e18);
        vm.prank(dave);
        vm.expectRevert(RedemptionModule.TCRBelowCritical.selector);
        rm.redeem(1, 1, 0, 0, 0); // gate before the balance check
        _setPrice(300.26e18); // just above: the gate passes, dave's empty balance is next
        vm.prank(dave);
        vm.expectRevert(InsufficientBalance.selector);
        rm.redeem(1, 1, 0, 0, 0);

        _setPrice(PRICE);
        uint256 fee = rm.redemptionFeeRate(1000e18);
        assertEq(fee, _fee(1000e18, token.totalSupply(), 0));
        vm.prank(erin);
        vm.expectRevert(RedemptionModule.FeeExceedsMaximum.selector);
        rm.redeem(1000e18, 1, fee - 1, 0, 0);
        snap = vm.snapshotState();
        vm.prank(erin);
        rm.redeem(1000e18, 1, fee, 0, 0); // exactly the maximum is accepted
        vm.revertToState(snap);

        // bob below MCR at 1,800 (ICR 1.08): one iteration skips him and redeems nothing
        _setPrice(1800e18);
        vm.prank(erin);
        vm.expectRevert(RedemptionModule.NothingRedeemed.selector);
        rm.redeem(1000e18, 1, WAD, 0, 0);
        vm.prank(erin);
        rm.redeem(1000e18, 2, WAD, 0, 0); // the second iteration reaches alice
        assertEq(v.debtOf(idAlice), 3000e18);
    }

    // ------------------------------------------------------------------ behaviour

    function test_redeem_fullThenPartial_stateTransfersAndEvents() public {
        uint256 s0 = token.totalSupply();
        uint256 fee = _fee(5000e18, s0, 0);
        uint256 outBob = Math.mulDiv(4000e18, WAD - fee, PRICE);
        uint256 outAlice = Math.mulDiv(1000e18, WAD - fee, PRICE);
        uint256 bobWeth = weth.balanceOf(bob);
        uint256 erinWeth = weth.balanceOf(erin);
        uint256 vmWeth = weth.balanceOf(address(v));

        vm.recordLogs();
        _redeem(erin, 5000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        VaultManager.Position memory b = v.positions(idBob);
        assertEq(uint8(b.status), uint8(VaultManager.Status.ClosedByRedemption));
        assertEq(b.coll + b.normDebt + b.stake, 0);
        assertEq(weth.balanceOf(bob) - bobWeth, 2.4e18 - outBob + GAS_RESERVE, "surplus + gas reserve pushed");
        assertFalse(sorted.contains(idBob));
        VaultManager.Position memory a = v.positions(idAlice);
        assertEq(a.coll, 3e18 - outAlice);
        assertEq(a.normDebt, 3000e18);
        assertEq(a.stake, a.coll);
        assertEq(weth.balanceOf(erin) - erinWeth, outBob + outAlice);
        assertEq(vmWeth - weth.balanceOf(address(v)), outBob + outAlice + 2.4e18 - outBob + GAS_RESERVE);
        assertEq(token.totalSupply(), s0 - 5000e18);
        assertEq(token.balanceOf(erin), 20_000e18 - 5000e18);
        assertEq(v.activeCount(), 3);
        assertEq(v.totalNormDebt(), 28_000e18);
        assertEq(v.totalCollateral(), 100e18 + 10e18 + a.coll);
        assertEq(rm.baseRate(), Math.mulDiv(5000e18, WAD, s0 * BETA, Math.Rounding.Ceil));
        assertEq(rm.lastFeeOperationTime(), block.timestamp);

        _checkFullThenPartialLogs(logs, outBob, outAlice, fee);
    }

    /// @dev bob closed, alice partial, each followed by PositionUpdated(op 7), then Redeemed.
    function _checkFullThenPartialLogs(Vm.Log[] memory logs, uint256 outBob, uint256 outAlice, uint256 fee)
        internal
        view
    {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.PositionRedeemed.selector) {
                bytes memory want = seen == 0
                    ? abi.encode(uint256(4000e18), outBob, 2.4e18 - outBob, true)
                    : abi.encode(uint256(1000e18), outAlice, uint256(0), false);
                assertEq(uint256(logs[i].topics[1]), seen == 0 ? idBob : idAlice);
                assertEq(logs[i].data, want, "PositionRedeemed fields");
                assertEq(logs[i + 1].topics[0], VaultManager.PositionUpdated.selector);
                (,,,,, uint8 status, uint8 op) =
                    abi.decode(logs[i + 1].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint8));
                assertEq(op, 7, "OP_REDEEM");
                assertEq(status, seen == 0 ? 3 : 1);
                ++seen;
            } else if (t == RedemptionModule.Redeemed.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), erin);
                assertEq(
                    logs[i].data,
                    abi.encode(5000e18, 5000e18, outBob + outAlice, fee, uint256(2), rm.baseRate()),
                    "Redeemed fields"
                );
                ++seen;
            }
        }
        assertEq(seen, 3);
    }

    function test_redeem_feeFromRequested_baseRateFromRedeemed() public {
        uint256 s0 = token.totalSupply();
        uint256 fee = _fee(20_000e18, s0, 0);
        vm.recordLogs();
        vm.prank(erin);
        rm.redeem(20_000e18, 1, WAD, 0, 0); // one iteration: only bob's 4,000 is redeemed
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, uint256 redeemed,, uint256 feeRate,,) =
            abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(redeemed, 4000e18);
        assertEq(feeRate, fee, "fee from the requested 20,000");
        assertEq(rm.baseRate(), Math.mulDiv(4000e18, WAD, s0 * BETA, Math.Rounding.Ceil), "base from 4,000");
        assertEq(token.balanceOf(erin), 16_000e18, "only the redeemed amount is burned");
    }

    function test_decayedBaseRate_halvesInTwelveHoursAndFloorsAtOneWei() public {
        _redeem(erin, 1000e18);
        uint256 b = rm.baseRate();
        assertGt(b, 0);
        vm.warp(block.timestamp + 43_200);
        uint256 half = Math.mulDiv(b, WadRayMath.rpow(DECAY, 43_200), RAY, Math.Rounding.Ceil);
        assertEq(rm.decayedBaseRate(), half);
        assertApproxEqRel(half, b / 2, 1e12);
        vm.warp(block.timestamp + 1e9);
        assertEq(rm.decayedBaseRate(), 1, "never decays to 0 (R19 up)");
    }

    function test_redemptionFeeRate_viewMatchesRedeemInTheSameBlockUntilInterestAccrues() public {
        uint256 view0 = rm.redemptionFeeRate(1000e18);
        vm.recordLogs();
        _redeem(erin, 1000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, uint256 feeRate,,) =
            abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(feeRate, view0, "dt = 0: the view is exact");
        vm.warp(block.timestamp + 30 days);
        _setPrice(PRICE);
        uint256 view1 = rm.redemptionFeeRate(1000e18);
        vm.recordLogs();
        _redeem(erin, 1000e18);
        logs = vm.getRecordedLogs();
        (,,, feeRate,,) =
            abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertLe(feeRate, view1, "the accrual grows S0, so the charged rate can only be lower (5.5)");
        assertLt(feeRate, view1);
    }

    function test_redeem_partialDownToExactlyMinDebtThenStops() public {
        _redeem(erin, 2000e18); // bob 4,000 → 2,000 = MIN_DEBT
        assertEq(v.debtOf(idBob), MIN_DEBT);
        // bob is still the tail (his NICR rose but stays lowest); at MIN_DEBT the partial is cancelled
        assertEq(sorted.getLast(), idBob);
        vm.prank(erin);
        vm.expectRevert(RedemptionModule.NothingRedeemed.selector);
        rm.redeem(1, 10, WAD, 0, 0);
        _redeem(erin, MIN_DEBT); // the whole of bob closes him
        assertEq(uint8(v.positions(idBob).status), uint8(VaultManager.Status.ClosedByRedemption));
    }

    /// @dev Valid hints from the caller place the partial (stale hints: `RedemptionStaleHintTest`).
    function test_redeem_validCallerHintsPlaceThePartial() public {
        uint256 bobDebt = v.debtOf(idBob);
        vm.prank(erin);
        rm.redeem(bobDebt + 500e18, 10, WAD, idErin, idCarol); // alice's slot is behind carol: hints valid
        assertEq(v.debtOf(idAlice), 3500e18);
    }

    function test_redeem_pendingRewardsAreAppliedToTheRedeemedPositionOnly() public {
        // 0.01 WETH and 20 normalised debt per unit of stake, pending on every position
        uint256 stakes = v.totalStakes();
        weth.mint(address(v), stakes / 100);
        v.setRedistribution(1e16, 20e18, stakes / 100, stakes * 20, 0, 0);
        (uint256 cB, uint256 nB) = v.effective(idBob);
        assertEq(cB, 2.4e18 + 0.024e18);
        assertEq(nB, 4000e18 + 48e18);
        uint256 fee = _fee(1000e18, token.totalSupply(), 0);
        vm.expectEmit(address(v));
        emit VaultManager.RewardsApplied(idBob, 0.024e18, 48e18);
        _redeem(erin, 1000e18);
        VaultManager.Position memory b = v.positions(idBob);
        assertEq(b.coll, cB - Math.mulDiv(1000e18, WAD - fee, PRICE));
        assertEq(b.normDebt, nB - 1000e18);
        assertEq(b.snapLColl, 1e16);
        (uint256 cA, uint256 nA) = v.effective(idAlice);
        assertEq(v.positions(idAlice).coll, 3e18, "alice's rewards stay pending");
        assertEq(cA, 3.03e18);
        assertEq(nA, 4060e18);
        assertGe(b.coll * PRICE, MCR * v.debtOf(idBob), "I5");
    }

    /// @dev Pending rewards on every position (`lColl`, `lDebt` per unit of stake), then bob — the tail —
    ///      redeemed in full. Review F1: `_applyPending` in `_redeemFull` was untested.
    function _fullRedemptionWithPending(uint256 lColl, uint256 lDebt) internal {
        uint256 stakes = v.totalStakes();
        uint256 pendColl = stakes * lColl / 1e18; // exact for these stakes and rates
        uint256 pendNorm = stakes * lDebt / 1e18;
        weth.mint(address(v), pendColl);
        v.setRedistribution(lColl, lDebt, pendColl, pendNorm, 0, 0);
        uint256 pc = 2.4e18 * lColl / 1e18;
        uint256 pn = 2.4e18 * lDebt / 1e18; // per unit of stake; bob's stake is his 2.4 WETH
        (uint256 c, uint256 n) = v.effective(idBob);
        assertEq(abi.encode(c, n), abi.encode(2.4e18 + pc, 4000e18 + pn));
        uint256 debt = v.debtOf(idBob); // index RAY: = n
        assertGe(c * PRICE, MCR * debt, "bob is redeemable, not skipped");
        uint256 fee = _fee(debt, token.totalSupply(), 0);
        uint256 out = Math.mulDiv(debt, WAD - fee, PRICE);
        uint256 bobWeth = weth.balanceOf(bob);
        uint256 totalNorm = v.totalNormDebt();
        uint256 supply = token.totalSupply();
        vm.expectEmit(address(v));
        emit VaultManager.RewardsApplied(idBob, pc, pn);
        vm.prank(erin);
        rm.redeem(debt, 1, WAD, 0, 0);
        assertEq(uint8(v.positions(idBob).status), uint8(VaultManager.Status.ClosedByRedemption));
        assertEq(
            weth.balanceOf(bob) - bobWeth, c - out + GAS_RESERVE, "surplus includes the pending collateral"
        );
        assertEq(v.pendingColl(), pendColl - pc, "pending collateral moved out");
        assertEq(v.pendingNormDebt(), pendNorm - pn, "pending debt moved out");
        assertEq(totalNorm - v.totalNormDebt(), n, "the effective normalised debt leaves");
        assertEq(supply - token.totalSupply(), debt, "burned = effective debt");
    }

    function test_redeem_fullWithPendingRewards_appliesThemFirst() public {
        _fullRedemptionWithPending(1e16, 20e18);
    }

    /// @dev Here the collateral out exceeds bob's *stored* collateral: without `_applyPending` the
    ///      surplus `p.coll − out` would underflow and a healthy tail position could not be redeemed.
    function test_redeem_fullWithPendingRewards_outAboveStoredCollateral() public {
        // bob: 3.0 WETH and 5,440 debt effective (ICR 1.103), of which 2.4 WETH stored
        uint256 out = Math.mulDiv(5440e18, WAD - _fee(5440e18, token.totalSupply(), 0), PRICE);
        assertGt(out, 2.4e18, "the case the review describes");
        _fullRedemptionWithPending(0.25e18, 600e18);
    }

    /// @dev The user's condition at plan approval: the normal path RedemptionModule.redeem →
    ///      VaultManager.accrue / redeemCollateral runs under two separate transient locks that do not
    ///      interfere, and both are released afterwards.
    function test_redeem_twoTransientLocksDoNotInterfere() public {
        vm.warp(block.timestamp + 1 days); // so accrue does real work inside the RM lock
        _setPrice(PRICE);
        vm.expectCall(address(v), abi.encodeCall(VaultManager.accrue, ()), 1);
        vm.expectCall(address(v), abi.encodeWithSelector(VaultManager.redeemCollateral.selector), 1);
        _redeem(erin, 1000e18);
        assertGt(rm.baseRate(), 0, "the redemption completed under both locks");
    }

    /// @dev After a redemption both locks are released: the module takes another redemption and the
    ///      VaultManager takes its own calls in the same transaction context.
    function test_redeem_bothLocksReleasedAfterwards() public {
        _redeem(erin, 1000e18);
        _redeem(erin, 1000e18);
        v.accrue();
        vm.prank(alice);
        v.addCollateral(idAlice, 1, 0, 0);
        assertEq(v.debtOf(idBob), 2000e18, "both redemptions took from bob");
        assertEq(v.positions(idAlice).coll, 3e18 + 1, "the VaultManager took alice's call");
    }
}
