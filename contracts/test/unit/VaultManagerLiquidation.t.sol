// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {PriceUnusable, SystemShutdown} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {LiquidationFixture, ScriptedStrategy} from "../utils/LiquidationFixture.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `VaultManager.liquidate` (spec §5.1.7, §6.4, §6.5) in deployment A against the real pool:
///         every revert, each remainder path, the snapshot reset, the gas reserve, the CHG-012 bounds,
///         re-entry from the strategy, the self-liquidation attack (T-10) and the JIT sandwich (T-26).
///         Vectors: test/vectors/LiquidationVectors.t.sol.
contract VaultManagerLiquidationTest is LiquidationFixture {
    function setUp() public {
        _deploy(address(0));
    }

    /// @dev Alice 10 WETH / 10,000 (ICR 2 at 2,000) and bob 2 WETH / 3,000 as the target.
    function _base() internal returns (uint256 target) {
        _open(alice, 10e18, 10_000e18);
        target = _open(bob, 2e18, 3000e18);
    }

    // ------------------------------------------------------------------ reverts (§6.4.1 order)

    function test_liquidate_notWired_reverts() public {
        VaultManager fresh =
            new VaultManager(address(weth), address(token), address(oracle), MCR, MIN_DEBT, 1, 0, 0, 200_000);
        vm.expectRevert(WiredBase.NotWired.selector);
        fresh.liquidate(1);
    }

    function test_liquidate_afterShutdown_reverts() public {
        uint256 id = _base();
        vm.prank(SHUTDOWN);
        v.onShutdown();
        vm.expectRevert(SystemShutdown.selector);
        v.liquidate(id);
    }

    function test_liquidate_notActive_reverts() public {
        vm.expectRevert(VaultManager.PositionNotActive.selector);
        v.liquidate(7);
    }

    /// @dev ICR exactly MCR is not liquidatable (`coll·price < MCR·debt` is strict); one wei of price
    ///      less is.
    function test_liquidate_atExactlyMcr_reverts_oneBelowLiquidates() public {
        _open(alice, 10e18, 10_000e18);
        uint256 id = _open(bob, 11e18, 10_000e18); // ICR 2.2 at 2,000
        // debt is exactly 10,000 + nothing accrued (same block): MCR at price 1,000
        _setPrice(1000e18);
        vm.expectRevert(VaultManager.NotLiquidatable.selector);
        v.liquidate(id);
        _setPrice(1000e18 - 1e10); // the feed's smallest step below
        vm.prank(liq);
        v.liquidate(id);
        assertEq(uint8(v.positions(id).status), uint8(VaultManager.Status.ClosedByLiquidation));
    }

    /// @dev §7: liquidation needs a usable price; whenever `peek` says unusable it reverts PriceUnusable —
    ///      stale answer, sequencer down, and the grace window at its boundary.
    function test_liquidate_unusablePrice_reverts() public {
        uint256 id = _base();
        _setPrice(1400e18);
        uint256 t = block.timestamp;
        // stale
        vm.warp(t + STALENESS + 1);
        _assertGate(id);
        vm.warp(t);
        _setPrice(1400e18);
        // sequencer down
        seq.setStatus(1, block.timestamp - 10);
        _assertGate(id);
        // grace window: restarted exactly GRACE ago is still inside (§6.10.1 "≤"), one second more is out
        seq.setStatus(0, block.timestamp - GRACE);
        _assertGate(id);
        seq.setStatus(0, block.timestamp - GRACE - 1);
        (, bool usable,) = oracle.peek();
        assertTrue(usable, "out of the grace window");
        vm.prank(liq);
        v.liquidate(id);
    }

    function _assertGate(uint256 id) internal {
        (, bool usable,) = oracle.peek();
        assertFalse(usable, "the oracle reports unusable");
        vm.prank(liq);
        vm.expectRevert(PriceUnusable.selector);
        v.liquidate(id);
    }

    // ------------------------------------------------------------------ remainder paths

    /// @dev Full offset: the pool absorbs the whole debt, the owner gets the surplus, the caller the gas
    ///      reserve, nothing is redistributed (path NONE).
    function test_liquidate_fullOffset_surplusAndGas() public {
        uint256 id = _base();
        _deposit(alice, 5000e18);
        _setPrice(1500e18); // bob: 2 WETH · 1,500 = 3,000 < 1.1 · 3,000
        uint256 bobBefore = weth.balanceOf(bob);
        uint256 liqBefore = weth.balanceOf(liq);
        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        vm.prank(liq);
        v.liquidate(id);
        assertEq(weth.balanceOf(liq) - liqBefore, GAS_RESERVE, "gas reserve to the caller");
        uint256 seized = 3000e18 * 1.05e18 / 1500e18; // 2.1 WETH capped at coll = 2
        assertEq(seized > 2e18 ? 0 : 2e18 - seized, weth.balanceOf(bob) - bobBefore, "surplus to the owner");
        assertEq(supplyBefore - token.totalSupply(), 3000e18, "the pool burned the debt");
        assertEq(v.pendingNormDebt(), 0, "nothing redistributed");
        assertEq(sorted.getSize(), 1, "removed from the list");
        _assertPath(vm.getRecordedLogs(), 0);
    }

    /// @dev Partial offset: the pool covers part, the rest is redistributed to alice (REDISTRIBUTED).
    function test_liquidate_partialOffset_restRedistributed() public {
        uint256 id = _base();
        _deposit(alice, 1000e18);
        _setPrice(1500e18);
        vm.recordLogs();
        vm.prank(liq);
        v.liquidate(id);
        _assertPath(vm.getRecordedLogs(), 1);
        assertEq(pool.totalDeposits(), 0, "pool emptied");
        assertEq(v.pendingNormDebt(), 2000e18, "the unabsorbed debt is pending on alice");
        (, uint256 effNorm) = v.effective(1);
        // stake = coll = 10e18, so dLDebt = 2,000e18 · 1e18 / 10e18 is exact and so is the reward
        assertEq(effNorm, 12_000e18, "alice's key includes the redistributed debt");
    }

    /// @dev An empty pool absorbs nothing: everything seized comes back and is redistributed.
    function test_liquidate_emptyPool_redistributionOnly() public {
        uint256 id = _base();
        _setPrice(1500e18);
        vm.recordLogs();
        vm.prank(liq);
        v.liquidate(id);
        _assertPath(vm.getRecordedLogs(), 1);
        assertEq(v.pendingNormDebt(), 3000e18);
        assertGt(v.LColl(), 0);
        assertEq(v.totalStakesSnapshot(), v.totalStakes(), "snapshot after the liquidation");
    }

    /// @dev The last active position: no stake left, so the remainder is a deficit with its collateral
    ///      (§6.4.4), and the snapshots reset so the next position is staked 1:1.
    function test_liquidate_lastPosition_deficitAndSnapshotReset() public {
        uint256 id = _open(bob, 2e18, 3000e18);
        _setPrice(1500e18);
        vm.recordLogs();
        vm.prank(liq);
        v.liquidate(id);
        _assertPath(vm.getRecordedLogs(), 2);
        assertEq(ledger.deficit(), 3000e18, "the deficit is the debt (R27, no interest yet)");
        assertEq(ledger.recoveredColl(), 2e18, "the pool returned all it seized: the whole collateral");
        assertEq(weth.balanceOf(address(ledger)), 2e18);
        assertEq(v.totalNormDebt(), 0);
        assertEq(v.totalStakesSnapshot(), 0);
        assertEq(v.totalCollateralSnapshot(), 0);
        _setPrice(2000e18);
        uint256 next = _open(carol, 4e18, 2000e18);
        assertEq(v.positions(next).stake, 4e18, "staked 1:1 after the reset");
    }

    /// @dev Underwater (ICR < 1): the pool takes the loss — it burns the whole debt for less collateral.
    function test_liquidate_underwater_poolTakesTheLoss() public {
        uint256 id = _base();
        _deposit(alice, 5000e18);
        _setPrice(1400e18); // bob: 2 · 1,400 = 2,800 < 3,000
        vm.prank(liq);
        v.liquidate(id);
        assertEq(pool.collGainsBalance(), 2e18, "all of the collateral");
        assertEq(pool.totalDeposits(), 2000e18, "3,000 of debt burned from the deposits");
        assertLt(2e18 * 1400e18 / WAD, 3000e18, "worth less than the debt absorbed");
    }

    function _assertPath(Vm.Log[] memory logs, uint8 want) internal view {
        bool seen;
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].emitter == address(v) && logs[k].topics[0] == VaultManager.Liquidated.selector) {
                (,,,,, uint8 path,) =
                    abi.decode(logs[k].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint256));
                assertEq(path, want, "remainderPath");
                seen = true;
            }
        }
        assertTrue(seen, "Liquidated emitted");
    }

    // ------------------------------------------------------------------ CHG-012 and re-entry

    function _scripted() internal returns (ScriptedStrategy s, uint256 id) {
        s = new ScriptedStrategy();
        _deploy(address(s));
        s.setVault(address(v), weth);
        _open(alice, 10e18, 10_000e18);
        id = _open(bob, 2e18, 3000e18);
        _setPrice(1500e18);
    }

    function test_chg012_debtAbsorbedAboveDebt_reverts() public {
        (ScriptedStrategy s, uint256 id) = _scripted();
        s.script(1, 0, false);
        vm.prank(liq);
        vm.expectRevert(VaultManager.DebtAbsorbedExceedsDebt.selector);
        v.liquidate(id);
    }

    function test_chg012_collReturnedAboveColl_reverts() public {
        (ScriptedStrategy s, uint256 id) = _scripted();
        s.script(0, 1, true);
        vm.prank(liq);
        vm.expectRevert(VaultManager.CollReturnedExceedsColl.selector);
        v.liquidate(id);
    }

    /// @dev Both bounds exactly are accepted: everything returned (redistributed), or the whole debt
    ///      absorbed.
    function test_chg012_exactBounds_accepted() public {
        (ScriptedStrategy s, uint256 id) = _scripted();
        uint256 snap = vm.snapshotState();
        s.script(0, 0, true); // collReturned == coll, debtAbsorbed 0
        vm.prank(liq);
        v.liquidate(id);
        assertEq(v.pendingColl(), 2e18);
        vm.revertToState(snap);
        s.script(0, 0, false); // debtAbsorbed == debt, collReturned 0
        vm.prank(liq);
        v.liquidate(id);
        assertEq(v.pendingNormDebt(), 0);
    }

    /// @dev A strategy that calls back into any VaultManager mutator during `onLiquidation` hits the lock.
    function test_strategyReentry_hitsTheLock() public {
        (ScriptedStrategy s, uint256 id) = _scripted();
        s.script(0, 0, true);
        s.setReenter(abi.encodeCall(VaultManager.liquidate, (1)));
        vm.prank(liq);
        v.liquidate(id);
        assertEq(
            s.innerRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    // ------------------------------------------------------------------ attacks

    /// @dev T-10: self-liquidation is never profitable beyond the gas reserve. For an ICR between 1 and
    ///      MCR the owner liquidating their own position ends with exactly GAS_RESERVE more WETH than if a
    ///      third party had, and — valued at the liquidation price — no more than closing would give.
    ///      Also as the pool's only depositor (the seized collateral comes back to them as a gain).
    function testFuzz_selfLiquidation_notProfitableBeyondGasReserve(uint256 priceSeed, bool ownerIsDepositor)
        public
    {
        uint256 id = _base();
        if (ownerIsDepositor) _deposit(bob, 3000e18 - 1e18); // bob's own minted stablecoin
        // ICR in (1.0, 1.1): price in (1,500, 1,650)
        uint256 price = bound(priceSeed, 1500e18 + 1e10, 1650e18 - 1e10) / 1e10 * 1e10;
        _setPrice(price);
        uint256 snap = vm.snapshotState();
        uint256 selfValue = _valueAfterLiquidation(bob, price);
        vm.revertToState(snap);
        uint256 thirdValue = _valueAfterLiquidation(liq, price);
        vm.revertToState(snap);
        assertEq(selfValue, thirdValue + GAS_RESERVE * price / WAD, "self = third party + the gas reserve");
        // closing instead: burn the debt, get coll + gas reserve back
        if (ownerIsDepositor) {
            vm.prank(bob);
            pool.withdraw(type(uint256).max);
        }
        vm.prank(bob);
        v.close(id);
        uint256 closeValue = _bobValue(price);
        assertLe(selfValue, closeValue + 2, "self-liquidation never beats closing (2 wei of rounding)");
    }

    function _valueAfterLiquidation(address caller, uint256 price) internal returns (uint256) {
        vm.prank(caller);
        v.liquidate(2);
        (, uint256 depositGain) = (0, 0);
        uint256 extra;
        (uint256 initial,,,,,) = pool.deposits(bob);
        if (initial > 0) {
            (uint256 cg,) = pool.gains(bob);
            extra = pool.compoundedDeposit(bob) + cg * price / WAD;
        }
        return _bobValue(price) + extra + depositGain;
    }

    /// @dev Bob's WETH and stablecoin, valued at `price` (stablecoin at par).
    function _bobValue(uint256 price) internal view returns (uint256) {
        return weth.balanceOf(bob) * price / WAD + token.balanceOf(bob);
    }

    /// @dev T-26 (P19 review L-2), measured not prevented: depositing just before a liquidation and
    ///      withdrawing right after captures a share of the penalty from the standing depositor.
    function test_jitSandwich_measuresProfitAndDilution() public {
        uint256 id = _base();
        _deposit(alice, 5000e18); // the standing depositor
        _setPrice(1600e18); // ICR 1.067: 1.96875 WETH (worth 3,150) seized for 3,000 of debt
        uint256 snap = vm.snapshotState();
        vm.prank(liq);
        v.liquidate(id);
        (uint256 aliceAlone,) = pool.gains(alice);
        uint256 aliceDepositAlone = pool.compoundedDeposit(alice);
        vm.revertToState(snap);
        // carol, the sandwicher, with 5,000 of stablecoin
        _open(carol, 20e18, 5000e18);
        uint256 wethBefore = weth.balanceOf(carol);
        _deposit(carol, 5000e18);
        vm.prank(liq);
        v.liquidate(id);
        vm.prank(carol);
        pool.withdraw(type(uint256).max);
        uint256 collGot = weth.balanceOf(carol) - wethBefore;
        uint256 stableBack = token.balanceOf(carol);
        // carol paid (5,000 − stableBack) of deposit for collGot of collateral at 1,600
        int256 profit = int256(collGot * 1600e18 / WAD) - int256(5000e18 - stableBack);
        (uint256 aliceShared,) = pool.gains(alice);
        emit log_named_int("sandwicher profit (stablecoin wei at the oracle price)", profit);
        emit log_named_uint("standing depositor's collateral gain alone", aliceAlone);
        emit log_named_uint("standing depositor's collateral gain when sandwiched", aliceShared);
        assertGt(profit, 0, "the sandwich captures part of the penalty");
        assertLt(aliceShared, aliceAlone, "the standing depositor is diluted");
        assertGt(pool.compoundedDeposit(alice), aliceDepositAlone, "but loses less deposit");
    }

    // ------------------------------------------------------------------ P20 security review

    /// @dev P20-M1 / T-27, measured not prevented: capital that opens a position just before a liquidation
    ///      into an empty pool and closes right after captures part of the redistributed penalty.
    function test_jitRedistributionSandwich_measuresCapture() public {
        uint256 id = _base(); // alice 10 WETH / 10,000 (the honest staker), bob the target
        _setPrice(1600e18); // bob at ICR 1.067: 1.96875 WETH seized for 3,000 of debt, 0.03125 surplus
        uint256 snap = vm.snapshotState();
        vm.prank(liq);
        v.liquidate(id);
        (uint256 aliceCollAlone,) = v.effective(1);
        vm.revertToState(snap);
        // carol opens 90 WETH against the minimum debt, waits for the liquidation, closes
        uint256 wethBefore = weth.balanceOf(carol);
        uint256 cid = _open(carol, 90e18, 2000e18);
        vm.prank(liq);
        v.liquidate(id);
        uint256 owed = v.debtOf(cid);
        uint256 have = token.balanceOf(carol);
        if (have < owed) {
            vm.prank(alice); // the amount is computed first: a call in the arguments would consume the prank
            token.transfer(carol, owed - have);
        }
        vm.prank(carol);
        v.close(cid);
        int256 wethGain = int256(weth.balanceOf(carol)) - int256(wethBefore);
        int256 debtTaken = int256(owed) - int256(2000e18); // the redistributed debt carol repaid
        int256 profit = wethGain * 1600 - debtTaken; // WETH valued at 1,600, stablecoin at par
        (uint256 aliceCollShared,) = v.effective(1);
        emit log_named_int("sandwicher profit (stablecoin wei at the oracle price)", profit);
        emit log_named_uint("honest staker's effective collateral alone", aliceCollAlone);
        emit log_named_uint("honest staker's effective collateral when sandwiched", aliceCollShared);
        assertGt(profit, 0, "the sandwich captures part of the redistributed penalty");
        assertLt(aliceCollShared, aliceCollAlone, "the honest staker is diluted");
    }

    /// @dev P20-L2: the no-stakes path also runs with active positions whose stake is 0 (T-25), not only
    ///      for the last position. A genuine zero stake needs the snapshot ratio collapsed over many
    ///      liquidations (P17-1); this unit test sets the collapsed snapshots with the harness setter
    ///      (`setRedistribution`, P14) and exercises the real `liquidate` branch on top. The core campaign
    ///      counts the same state reached with real liquidations only (`ok("liqDeficitWithActive")`).
    function test_liquidate_stakeZeroSurvivor_deficitWhileActive() public {
        uint256 small = _open(alice, 3e18, 2000e18);
        // a collapsed snapshot ratio: every new position is staked at floor(coll · 1 / 1e40) = 0
        v.setRedistribution(0, 0, 0, 0, 1, 1e40);
        uint256 carolId = _open(carol, 4e18, 2000e18);
        assertEq(v.positions(carolId).stake, 0, "carol is staked 0");
        assertEq(v.totalStakes(), v.positions(small).stake, "alice holds the only stake");
        _setPrice(700e18); // alice at ICR 1.05; carol at 1.4
        uint256 ledgerBefore = weth.balanceOf(address(ledger));
        vm.recordLogs();
        vm.prank(liq);
        v.liquidate(small);
        _assertPath(vm.getRecordedLogs(), 2);
        assertEq(v.activeCount(), 1, "carol is still active");
        assertEq(uint8(v.positions(carolId).status), uint8(VaultManager.Status.Active));
        assertEq(v.totalStakesSnapshot(), 0, "the snapshots reset");
        assertEq(v.totalCollateralSnapshot(), 0);
        assertEq(
            weth.balanceOf(address(ledger)) - ledgerBefore, ledger.recoveredColl(), "I1: the ledger holds it"
        );
        assertEq(
            weth.balanceOf(address(v)),
            v.totalCollateral() + v.pendingColl() + v.activeCount() * GAS_RESERVE,
            "I1: the VaultManager row"
        );
        assertEq(v.positions(carolId).stake, 0, "carol keeps stake 0 until touched (P17-1 (e))");
        _setPrice(2000e18);
        vm.prank(carol);
        v.addCollateral(carolId, 1, 0, 0);
        assertEq(v.positions(carolId).stake, 4e18 + 1, "touched after the reset: staked 1:1");
    }

    /// @dev Review test gap: a full absorption that empties the pool exactly (`debt == totalDeposits`)
    ///      moves the pool to a new epoch through the real `liquidate`.
    function test_liquidate_fullAbsorptionEmptiesPoolExactly_newEpoch() public {
        uint256 id = _base();
        _deposit(alice, 3000e18); // exactly bob's debt (same block: no interest)
        _setPrice(1500e18);
        vm.prank(liq);
        v.liquidate(id);
        assertEq(pool.totalDeposits(), 0);
        assertEq(pool.currentEpoch(), 1, "d == T: new epoch");
        assertEq(v.pendingNormDebt(), 0, "fully absorbed: nothing redistributed");
    }

    /// @dev Review test gap: a partial absorption from a 1-wei-short pool at an index above RAY, so R34's
    ///      floor is exercised (normAbsorbed = ⌊dP·RAY/I⌋) and the rest is redistributed.
    function test_liquidate_partialAbsorption_indexAboveRay() public {
        uint256 id = _base();
        _deposit(alice, 3000e18);
        vm.warp(block.timestamp + 30 days);
        _setPrice(1500e18);
        v.accrue();
        uint256 debt = v.debtOf(id);
        assertGt(debt, pool.totalDeposits(), "the pool is short after interest");
        (, uint256 n) = v.effective(id);
        uint256 index = v.index();
        vm.recordLogs();
        vm.prank(liq);
        v.liquidate(id);
        uint256 dP = 3000e18; // all the pool held
        uint256 normAbsorbed = dP * 1e27 / index; // R34 (down)
        assertEq(v.pendingNormDebt(), n - normAbsorbed, "normRest = n - floor(dP*RAY/I)");
        _assertPath(vm.getRecordedLogs(), 1);
    }

    /// @dev Review test gap: T-10 underwater (ICR < 1) into an empty pool, and with the redistribution
    ///      recipient also owned by the liquidated owner — self-liquidation is still worth exactly the gas
    ///      reserve over a third party.
    function test_selfLiquidation_underwater_ownerAlsoRecipient() public {
        _open(bob, 10e18, 10_000e18); // bob owns the position the remainder is redistributed to
        uint256 id = _open(bob, 2e18, 3000e18);
        _setPrice(1400e18); // ICR 0.93
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        v.liquidate(id);
        (uint256 cSelf, uint256 nSelf) = v.effective(1);
        uint256 wSelf = weth.balanceOf(bob);
        vm.revertToState(snap);
        vm.prank(liq);
        v.liquidate(id);
        (uint256 cThird, uint256 nThird) = v.effective(1);
        assertEq(cSelf, cThird, "the same redistribution either way");
        assertEq(nSelf, nThird);
        assertEq(wSelf - weth.balanceOf(bob), GAS_RESERVE, "self = third party + the gas reserve");
    }
}

