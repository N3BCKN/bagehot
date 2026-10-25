// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
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
            "redistribute",
            "shutdown",
            "settle",
            "reclaim",
            "x"
        ];
        for (uint256 i; i < 11; ++i) {
            emit log_named_uint(string.concat("ok: ", names[i]), handler.ok(bytes32(bytes(names[i]))));
        }
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
                assertGt(handler.ok(bytes32("redistribute")), 0, "reach: a redistribution ran (A)");
            }
        }
        _unwind();
    }

    function _unwind() internal {
        uint256 snap = vm.snapshotState();
        VaultManager v = handler.v();
        bool settled = v.settled();
        if (!settled) v.accrue();
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
        assertEq(handler.weth().balanceOf(address(handler.rm())), handler.donatedWeth(address(handler.rm())));
        assertEq(
            handler.token().balanceOf(address(handler.rm())), handler.donatedToken(address(handler.rm()))
        );
        vm.revertToState(snap);
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
        vm.startPrank(caller);
        vm.expectRevert(err);
        v.wire(address(1), address(1), address(0), address(1), address(1), address(1));
        vm.expectRevert(err);
        rm.wire(address(1), address(1), address(0));
        vm.expectRevert(err);
        sorted.wire(address(1));
        vm.expectRevert(err);
        token.wire(address(1), address(1), address(1), address(1));
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
