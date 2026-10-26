// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {DeficitLedger} from "../../src/safety/DeficitLedger.sol";
import {CoreHandler} from "./handlers/CoreHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The core invariants (P17) over `CoreHandler`: I1 (VaultManager and RedemptionModule
///         holders, supporting sums), I2, I5, I8 (bucket inequalities and the unwind), I9 and I12
///         (checked inside the actions), I11, I13 and no unexpected revert. Deployment A here,
///         B in `CoreInvariantsBTest`. Every protocol call in the handler is caught and classified,
///         so a revert that escapes an action is a harness or protocol failure, never a skipped call.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: nightly.invariant.fail-on-revert = true
contract CoreInvariantsTest is Test {
    CoreHandler internal handler;

    function _variantB() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        address[5] memory a =
            [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        handler = new CoreHandler(_variantB(), true, a);
        targetContract(address(handler));
        // replay-only since P20: the campaign liquidates for real
        bytes4[] memory replayOnly = new bytes4[](1);
        replayOnly[0] = CoreHandler.redistribute.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: replayOnly}));
    }

    function _assert(bool ok, string memory why) internal pure {
        assertTrue(ok, why);
    }

    function invariant_I1_holderBalances() public view {
        (bool ok, string memory why) = handler.checkI1Holders();
        _assert(ok, why);
    }

    function invariant_I1_supportingSums() public view {
        (bool ok, string memory why) = handler.checkI1Sums();
        _assert(ok, why);
    }

    /// @dev Deployment A's real pool (P19): I1 pool row, I3's exact inequalities and P range, U4.
    function invariant_I3_poolSolvencyAndU4() public view {
        (bool ok, string memory why) = handler.checkPool();
        _assert(ok, why);
    }

    /// @dev I4 (bundle and full-absorption TCR, A1–A3 / B1–B2), I6 (conservation) and I7 (surplus to
    ///      the owner, gas reserve to the caller), checked inside every liquidation (P20).
    function invariant_I4_I6_I7_liquidations() public view {
        (bool ok, string memory why) = handler.checkLiquidations();
        _assert(ok, why);
    }

    function invariant_I2_supplyDriftBound() public view {
        (bool ok, string memory why) = handler.checkI2();
        _assert(ok, why);
    }

    /// @dev The state reconstruction Medusa relies on agrees with the events (I2 counters, I5).
    function invariant_stateReconstructionMatchesEvents() public view {
        (bool ok, string memory why) = handler.checkEventsAgree();
        _assert(ok, why);
    }

    function invariant_I5_redemptionLeavesHealthyPositions() public view {
        (bool ok, string memory why) = handler.checkI5();
        _assert(ok, why);
    }

    function invariant_I8_noRoundingDeficit() public view {
        (bool ok, string memory why) = handler.checkI8();
        _assert(ok, why);
    }

    function invariant_I9_rescuePathsLive() public view {
        (bool ok, string memory why) = handler.checkI9();
        _assert(ok, why);
    }

    function invariant_I11_parametersImmutable() public view {
        (bool ok, string memory why) = handler.checkI11();
        _assert(ok, why);
    }

    function invariant_I12_noOperationOnUnusablePrice() public view {
        (bool ok, string memory why) = handler.checkI12();
        _assert(ok, why);
    }

    function invariant_I13_sortedByNicrWithinTolerance() public view {
        (bool ok, string memory why) = handler.checkI13();
        _assert(ok, why);
    }

    function invariant_noUnexpectedReverts() public view {
        bytes memory where = abi.encodePacked("unexpected revert in ", handler.lastUnexpectedAction());
        assertEq(handler.unexpectedReverts(), 0, string(where));
    }

    /// @dev I8's unwind (docs/invariants.md I8): snapshot; accrue; give every owner their effective
    ///      debt; close every position (live, window) or reclaim every gas reserve (settled); then the
    ///      VaultManager holds only donations plus the pending dust, the RedemptionModule only
    ///      donations; revert. Also: both I13 regimes reached in A, and the k measurement logged.
    function afterInvariant() external {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint(
            "I13: largest constant k any observed list would have needed", handler.maxNeededK()
        );
        emit log_named_uint("I13: max relative slack granted (WAD)", handler.maxRelativeSlackE18());
        emit log_named_uint("smallest member stake seen", handler.minMemberStake());
        emit log_named_uint(
            "I13 hidden-key: insertions with a non-zero allowance", handler.insertionsWithIota()
        );
        emit log_named_uint("I13 hidden-key: largest allowance / key scale (WAD)", handler.maxIotaRelE18());
        emit log_named_uint("steps in the exact regime", handler.stepsAllExact());
        emit log_named_uint("steps in the tolerance regime", handler.stepsNonExact());
        string[12] memory names = [
            "open",
            "add",
            "withdraw",
            "borrow",
            "repay",
            "close",
            "redeem",
            "liquidate",
            "shutdown",
            "settle",
            "reclaim",
            "x"
        ];
        for (uint256 i; i < 11; ++i) {
            emit log_named_uint(string.concat("ok: ", names[i]), handler.ok(bytes32(bytes(names[i]))));
        }
        string[7] memory liq = [
            "liqFull",
            "liqPartial",
            "liqNoOffset",
            "liqRedistributed",
            "liqDeficit",
            "liqUnderwater",
            "snapshotReset"
        ];
        for (uint256 i; i < 7; ++i) {
            emit log_named_uint(string.concat("ok: ", liq[i]), handler.ok(bytes32(bytes(liq[i]))));
        }
        emit log_named_uint("ok: poolDeposit", handler.ok("poolDeposit"));
        emit log_named_uint("ok: poolWithdraw", handler.ok("poolWithdraw"));
        emit log_named_uint("ok: poolClaim", handler.ok("poolClaim"));
        // CHG-005: every campaign run reaches both regimes. A shrunk replay of a failure is not a
        // run (it may hold a single call), so it is held only to the failure it reproduces.
        if (handler.calls() >= 100) {
            assertGt(handler.stepsAllExact(), 0, "I13: the exact regime was reached");
            if (!_variantB()) {
                assertGt(handler.stepsNonExact(), 0, "I13: the tolerance regime was reached (A)");
            }
            // reach: the tolerance regime above needs a redistribution; a redemption cannot be required
            // per run (a price path below the critical TCR refuses every one legitimately), so a dead
            // redemption is caught instead by the handler, which accepts a refusal only when the state
            // before the call justifies it
            if (!_variantB()) {
                assertGt(handler.ok(bytes32("liqRedistributed")), 0, "reach: a liquidation redistributed (A)");
            }
        }
        _unwind();
    }

    function _unwind() internal {
        uint256 snap = vm.snapshotState();
        VaultManager v = handler.v();
        bool settled = v.settled();
        if (!settled) v.accrue();
        _unwindPool(settled);
        for (uint256 id = 1; id < v.nextId(); ++id) {
            VaultManager.Position memory p = v.positions(id);
            if (p.status != VaultManager.Status.Active) continue;
            if (settled) {
                vm.prank(p.owner);
                v.reclaimGasReserve(id);
                continue;
            }
            uint256 debt = v.debtOf(id);
            StableToken token = handler.token(); // fetched before the prank: a call would consume it
            uint256 bal = token.balanceOf(p.owner);
            if (bal < debt) {
                vm.prank(address(v));
                token.mint(p.owner, debt - bal);
            }
            vm.prank(p.owner);
            v.close(id); // must succeed (I8 step 2)
        }
        assertEq(v.activeCount(), 0, "I8 unwind: every position exited");
        uint256 residual = settled ? 0 : v.pendingColl();
        assertEq(
            handler.weth().balanceOf(address(v)),
            handler.donatedWeth(address(v)) + residual,
            "I8 unwind: VaultManager holds donations plus pending dust"
        );
        _assertPoolResidual(settled);
        // I8 step 3, DeficitLedger (P21): recoveredColl and reserve stay (the unwind never covers)
        DeficitLedger l = handler.ledger();
        assertEq(
            handler.weth().balanceOf(address(l)),
            (l.settled() ? 0 : l.recoveredColl()) + handler.donatedWeth(address(l)),
            "I8 unwind: ledger WETH"
        );
        assertEq(
            handler.token().balanceOf(address(l)),
            (l.settled() ? 0 : l.reserve()) + handler.donatedToken(address(l)),
            "I8 unwind: ledger stablecoin"
        );
        assertEq(handler.weth().balanceOf(address(handler.rm())), handler.donatedWeth(address(handler.rm())));
        assertEq(
            handler.token().balanceOf(address(handler.rm())), handler.donatedToken(address(handler.rm()))
        );
        vm.revertToState(snap);
    }

    /// @dev I8 step 2, deployment A: every depositor claims, then withdraws everything — claimGains
    ///      first, because withdraw(max) deletes the record and claimGains would then revert NoDeposit.
    function _unwindPool(bool settled) internal {
        if (_variantB() || settled) return; // the pool step belongs to the live and window phases
        StabilityPool pool = handler.pool();
        for (uint256 i; i < 5; ++i) {
            address a = handler.actors(i);
            (uint256 initial,,,,,) = pool.deposits(a);
            if (initial == 0) continue;
            vm.prank(a);
            pool.claimGains(); // must succeed
            (initial,,,,,) = pool.deposits(a);
            if (initial == 0) continue; // a zero compounded deposit left on the claim
            vm.prank(a);
            pool.withdraw(type(uint256).max); // must succeed
        }
    }

    /// @dev I8 step 3 for the pool: WETH == collGainsBalance + D_w, stablecoin == interestGainsBalance +
    ///      D_t (plus totalDeposits once the ledger has settled), and no depositor claim left unpaid.
    function _assertPoolResidual(bool settled) internal view {
        if (_variantB()) return;
        StabilityPool pool = handler.pool();
        assertEq(
            handler.weth().balanceOf(address(pool)),
            pool.collGainsBalance() + handler.donatedWeth(address(pool)),
            "I8 unwind: pool WETH"
        );
        assertEq(
            handler.token().balanceOf(address(pool)),
            pool.interestGainsBalance() + pool.totalDeposits() + handler.donatedToken(address(pool)),
            "I8 unwind: pool stablecoin"
        );
        if (settled) return;
        assertEq(pool.totalDeposits(), 0, "I8 unwind: deposits fully withdrawn or swept");
        for (uint256 i; i < 5; ++i) {
            (uint256 initial,,,,,) = pool.deposits(handler.actors(i));
            assertEq(initial, 0, "I8 unwind: no depositor record left");
        }
    }

    // ------------------------------------------------------------------ I11: wiring is one-shot

    function test_wire_secondCallReverts() public {
        _wireAll(address(handler), WiredBase.AlreadyWired.selector); // the deployer
    }

    function test_wire_nonDeployerReverts() public {
        _wireAll(makeAddr("attacker"), WiredBase.NotDeployer.selector);
    }

    /// @dev Every wired contract's `wire`, called by `caller`, must revert with `err`. The contracts
    ///      are fetched first: a getter call would be the "next call" `expectRevert` applies to.
    function _wireAll(address caller, bytes4 err) internal {
        VaultManager v = handler.v();
        RedemptionModule rm = handler.rm();
        SortedPositions sorted = handler.sorted();
        StableToken token = handler.token();
        StabilityPool pool = handler.pool();
        vm.startPrank(caller);
        vm.expectRevert(err);
        v.wire(address(1), address(1), address(0), address(1), address(1), address(1));
        vm.expectRevert(err);
        rm.wire(address(1), address(1), address(0));
        vm.expectRevert(err);
        sorted.wire(address(1));
        vm.expectRevert(err);
        token.wire(address(1), address(1), address(1), address(1));
        if (address(pool) != address(0)) {
            vm.expectRevert(err);
            pool.wire(address(1), address(1));
        }
        vm.stopPrank();
    }
}

/// @notice The same invariants in deployment B (no pool, no redistribution).
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: nightly.invariant.fail-on-revert = true
contract CoreInvariantsBTest is CoreInvariantsTest {
    function _variantB() internal pure override returns (bool) {
        return true;
    }
}
