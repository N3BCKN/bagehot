// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {AuctionCallbackActive} from "../../src/lib/Errors.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {RedemptionFixture} from "../utils/RedemptionFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A buyer whose purchase callback tries to redeem (spec §6.7.2, T-01 / T-14).
contract RedeemingBuyer {
    RedemptionModule internal immutable rm;

    constructor(RedemptionModule rm_) {
        rm = rm_;
    }

    function onAuctionPurchase() external {
        rm.redeem(1000e18, 5, 1e18, 0, 0);
    }
}

/// @notice Adversarial sequences against redemption in deployment A.
contract RedemptionAttacksTest is RedemptionFixture {
    uint256 internal idErin;
    uint256 internal idCarol;
    uint256 internal idAlice;
    uint256 internal idBob;

    function setUp() public override {
        super.setUp();
        idErin = _open(erin, 100e18, 20_000e18);
        idCarol = _open(carol, 10e18, 5000e18);
        idAlice = _open(alice, 3e18, 4000e18);
        idBob = _open(bob, 2.4e18, 4000e18);
    }

    /// @notice A 1-wei redemption still pays the floor and raises the base rate by at least 1 wei
    ///         (R20 up), so dust spam cannot redeem fee-free or leave the base rate untouched.
    function test_attack_dustStillPaysAndMovesTheBaseRate() public {
        uint256 fee = rm.redemptionFeeRate(1);
        assertEq(fee, FEE_FLOOR + 1);
        _redeem(erin, 1);
        assertEq(rm.baseRate(), 1);
    }

    /// @notice An owner redeeming their own position closes it at par: as redeemer they get the
    ///         collateral bought, as owner the surplus and the gas reserve — nothing is gained or lost
    ///         beyond the fee, which stays in the position and so comes back as surplus.
    function test_attack_selfRedemptionClosesOwnPositionAtPar() public {
        vm.prank(erin);
        token.transfer(bob, 1);
        uint256 bobWeth = weth.balanceOf(bob);
        uint256 fee = rm.redemptionFeeRate(4000e18);
        uint256 out = Math.mulDiv(4000e18, WAD - fee, PRICE);
        vm.prank(bob);
        rm.redeem(4000e18, 1, WAD, 0, 0);
        assertEq(uint8(v.positions(idBob).status), uint8(VaultManager.Status.ClosedByRedemption));
        // as redeemer bob receives `out`; as owner, the surplus and the gas reserve
        assertEq(weth.balanceOf(bob) - bobWeth, out + (2.4e18 - out) + GAS_RESERVE);
        assertEq(token.balanceOf(bob), 1);
    }

    /// @notice Documented property of §6.7.2 (as in Liquity): each redemption pays the base rate
    ///         including its own increment, so two same-block halves pay a lower average rate than one
    ///         redemption of the whole. Pinned so a change to the fee rule is noticed; not a defect.
    function test_feeSplitting_halvesPayLessThanTheWholeBySpecDesign() public {
        uint256 snap = vm.snapshotState();
        uint256 oneShot = rm.redemptionFeeRate(4000e18);
        vm.revertToState(snap);
        uint256 f1 = rm.redemptionFeeRate(2000e18);
        _redeem(erin, 2000e18);
        uint256 f2 = rm.redemptionFeeRate(2000e18);
        assertLt((f1 + f2) / 2, oneShot);
    }
}

/// @notice Only a healthy redeemer and the zero-slack position, so the TCR gate stays open at 10 USD.
contract RedemptionDustTest is RedemptionFixture {
    /// @notice Dust redemptions against a position with zero slack above MCR, at a high index and
    ///         MIN_PRICE (the widest CHG-002 window): every one either redeems nothing or leaves the
    ///         position at or above MCR. None can push it below.
    function test_attack_dustRedemptionsCannotPushAPositionBelowMcr() public {
        // the shape of redemption.json#partial_cancelled_below_mcr: whether a dust amount falls in the
        // window depends on the index and on the position's normalised debt, so use the vector's
        _setPrice(10e18);
        _open(erin, 2000e18, 10_000e18); // the redeemer
        vm.warp(block.timestamp + 134_028_000);
        _setPrice(10e18);
        uint256 dave_ = _open(dave, 6600e18 + 110, 60_000e18 + 999);
        assertEq(v.index(), 1_230_423_227_649_962_415_141_542_910);
        assertEq(sorted.getLast(), dave_, "the zero-slack position is the tail");
        (uint256 c0,) = v.effective(dave_);
        assertEq(c0 * 10e18, MCR * v.debtOf(dave_), "zero slack");
        uint256 cancelled;
        // from 11 wei: smaller amounts send 0 collateral, succeed and only add slack
        for (uint256 d = 11; d <= 60; ++d) {
            if (sorted.getLast() != dave_) break;
            vm.prank(erin);
            try rm.redeem(d, 1, WAD, 0, 0) {}
            catch {
                ++cancelled;
            }
            (uint256 c,) = v.effective(dave_);
            assertGe(c * 10e18, MCR * v.debtOf(dave_), "never below MCR");
        }
        assertGt(cancelled, 0, "the CHG-002 window was exercised");
    }
}

/// @notice With MAX_HINT_STEPS = 1 a hint two steps from the slot is stale: the partial is cancelled
///         but the full redemption before it stands and the call succeeds. (This is also a successful
///         call whose last visit is a cancelled partial — the sequence of CHG-007.)
contract RedemptionStaleHintTest is RedemptionFixture {
    function setUp() public override {
        maxHintSteps = 1;
        super.setUp();
    }

    /// @dev Exact hints: the new position goes right after `prev` at the tail.
    function _openAfter(address who, uint256 coll, uint256 debt, uint256 prev) internal returns (uint256 id) {
        vm.prank(who);
        id = v.openPosition(coll, debt, prev, 0);
    }

    function test_attack_staleHintCostsOnlyThePartial() public {
        uint256 idErin = _openAfter(erin, 100e18, 20_000e18, 0);
        uint256 idCarol = _openAfter(carol, 10e18, 5000e18, idErin);
        uint256 idAlice = _openAfter(alice, 3e18, 4000e18, idCarol);
        uint256 idBob = _openAfter(bob, 2.4e18, 4000e18, idAlice);
        assertEq(sorted.getLast(), idBob);
        vm.prank(erin);
        rm.redeem(4500e18, 10, WAD, idErin, idErin); // alice's new slot is two steps below erin
        assertEq(uint8(v.positions(idBob).status), uint8(VaultManager.Status.ClosedByRedemption));
        assertEq(v.debtOf(idAlice), 4000e18, "the partial was cancelled");
        assertEq(token.balanceOf(erin), 16_000e18, "only bob's 4,000 was burned");
    }

    /// @notice The hint helper's own "no slot within MAX_HINT_STEPS" cancellation agrees with the
    ///         contract's: alice's partial lifts her NICR past two nodes, one walk step is not enough
    ///         from the helper's start (the tail, numTrials = 0), so both cancel the partial and
    ///         redeem bob's 4,000 only.
    function test_hints_noSlotCancellationAgreesWithTheContract() public {
        uint256 idErin = _openAfter(erin, 100e18, 20_000e18, 0);
        uint256 idCarol = _openAfter(carol, 10e18, 5000e18, idErin);
        uint256 idDave = _openAfter(dave, 4e18, 4000e18, idCarol); // NICR 0.00100
        uint256 f2 = _openAfter(dave, 3.4e18, 4000e18, idDave); // 0.00085
        uint256 f1 = _openAfter(carol, 3.2e18, 4000e18, f2); // 0.00080
        uint256 idAlice = _openAfter(alice, 3e18, 4000e18, f1); // 0.00075
        uint256 idBob = _openAfter(bob, 2.4e18, 4000e18, idAlice); // the tail
        uint256 amount = 4000e18 + 1950e18; // bob in full, then alice to 2,050 at NICR ~0.00099
        uint256 fee = rm.redemptionFeeRate(amount);
        (uint256 up, uint256 lo, uint256 partialId, uint256 redeemable) =
            hints.getRedemptionHints(amount, PRICE, 10, fee, 0, 0);
        assertEq(abi.encode(up, lo, partialId, redeemable), abi.encode(0, 0, 0, 4000e18));
        vm.prank(erin);
        rm.redeem(amount, 10, WAD, up, lo);
        assertEq(uint8(v.positions(idBob).status), uint8(VaultManager.Status.ClosedByRedemption));
        assertEq(v.debtOf(idAlice), 4000e18, "the partial was cancelled on the contract too");
    }
}

/// @notice Deployment B: a redemption from inside an auction buyer's callback reverts
///         AuctionCallbackActive (§6.7.2; open issues P02-4 / P04-1, threat T-01 / T-14); outside the
///         callback the same buyer redeems normally. The gate counts the house's lots and auctions.
contract RedemptionAuctionCallbackTest is RedemptionFixture {
    RedeemingBuyer internal buyer;

    function setUp() public override {
        variantB = true;
        super.setUp();
        _open(erin, 100e18, 20_000e18);
        _open(bob, 2.4e18, 4000e18);
        buyer = new RedeemingBuyer(rm);
        vm.prank(erin);
        token.transfer(address(buyer), 2000e18);
    }

    function test_redeem_fromInsideABuyerCallback_revertsAuctionCallbackActive() public {
        (bool ok, bytes memory ret) =
            house.buyWithCallback(address(buyer), abi.encodeCall(RedeemingBuyer.onAuctionPurchase, ()));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AuctionCallbackActive.selector));
        assertFalse(house.inPurchase());
        buyer.onAuctionPurchase(); // outside the callback the same call succeeds
        assertEq(token.balanceOf(address(buyer)), 1000e18);
    }

    function test_redeem_flagCheckedBeforeTheGateAndBalance() public {
        house.setInPurchase(true);
        _setPrice(100e18); // TCR far below critical
        vm.prank(dave); // no balance
        vm.expectRevert(AuctionCallbackActive.selector);
        rm.redeem(1, 1, WAD, 0, 0);
    }

    /// @dev C = 102.4 WETH · 2,000 = 204,800; with a 200,000 deficit D = 224,000 and
    ///      1.05 · D = 235,200 > C. 100 WETH of lots in the house lift C to 404,800.
    function test_gate_countsTheHouseLotsInB() public {
        assertFalse(gate.belowCritical(PRICE));
        ledger.set(0, 0, 200_000e18);
        assertTrue(gate.belowCritical(PRICE));
        house.set(100e18, 0);
        assertFalse(gate.belowCritical(PRICE));
    }
}

/// @notice Deployment B with no positions: an active auction alone makes the system live (§5.8).
contract RedemptionGateLiveBTest is RedemptionFixture {
    function setUp() public override {
        variantB = true;
        super.setUp();
    }

    function test_gate_liveThroughAnActiveAuctionOnly() public {
        ledger.set(0, 0, 1000e18);
        assertFalse(gate.belowCritical(PRICE), "nothing live: the deficit is not judged");
        house.set(0, 1);
        assertTrue(gate.belowCritical(PRICE), "an active auction makes it live");
    }
}
