// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {InvalidParameter} from "../../src/lib/Errors.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {StandInDeficitLedger} from "../../src/mocks/StandInDeficitLedger.sol";
import {VaultManagerHarness} from "../utils/VaultManagerHarness.sol";
import {GasSensitivePool, HostilePool, MockWETH} from "../utils/VaultMocks.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// @notice CHG-006 / ADR-0033 acceptance criteria (P19-AC-CHG006-1 and -2): a failing stability pool
///         cannot stop accrual — its share falls back to the reserve — and a caller cannot fake a pool
///         failure by under-supplying gas. Liquidation and `ShutdownModule.check` join the operation
///         matrix at P20 and at the ShutdownModule prompt (carry-forward, human decision 2026-10-26).
contract VaultManagerPoolHookTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SHARE = 7500;
    uint256 internal constant HOOK_GAS = 200_000;
    address internal constant SHUTDOWN = address(0x5D);

    VaultManagerHarness internal v;
    StableToken internal token;
    MockWETH internal weth;
    MockAggregator internal feed;
    StandInDeficitLedger internal ledger;
    HostilePool internal hostile;
    StabilityPool internal realPool;
    address internal pool; // the wired pool: `hostile` or `realPool`
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // ------------------------------------------------------------------ deployment

    function _deploy(bool real) internal {
        vm.warp(10_000_000);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, 1);
        feed.setRound(1, 2000e8, block.timestamp);
        OracleAdapter oracle = new OracleAdapter(
            address(feed), address(seq), type(uint64).max, 0, 10e18, 1_000_000e18, 100_000, 3175
        );
        SortedPositions sorted = new SortedPositions(30);
        v = new VaultManagerHarness(
            address(weth),
            address(token),
            address(oracle),
            1.1e18,
            2000e18,
            0.0375e18,
            1_547_125_957_863_212_449,
            SHARE,
            HOOK_GAS
        );
        ledger = new StandInDeficitLedger(address(v));
        if (real) {
            realPool = new StabilityPool(address(weth), address(token), 0.05e18, 1e18);
            pool = address(realPool);
        } else {
            hostile = new HostilePool();
            pool = address(hostile);
        }
        v.wire(address(sorted), pool, pool, address(0xDE11), address(ledger), SHUTDOWN);
        sorted.wire(address(v));
        token.wire(address(v), pool, address(ledger), SHUTDOWN);
        if (real) realPool.wire(address(v), address(ledger));
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? alice : bob;
            weth.mint(a, 1000e18);
            vm.prank(a);
            weth.approve(address(v), type(uint256).max);
        }
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.prank(bob);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.prank(bob);
        token.transfer(alice, 500e18); // alice can close with interest on her debt
        if (real) {
            vm.prank(bob);
            realPool.deposit(1000e18);
        }
    }

    function _warp(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        feed.setRound(1, 2000e8, block.timestamp);
    }

    // ------------------------------------------------------------------ AC-1: the fallback cannot revert

    /// @dev The ledger's `onInterest` (the DeficitLedger stand-in until P21) takes any amount up to the
    ///      supply cap, with the tokens minted to match, and never reverts.
    function testFuzz_ledgerOnInterest_neverRevertsUpToTheSupplyCap(uint256[6] memory amounts) public {
        StableToken t = new StableToken("T", "T");
        StandInDeficitLedger l = new StandInDeficitLedger(address(this));
        t.wire(address(this), address(1), address(l), address(2));
        uint256 cap = type(uint128).max;
        uint256 sum;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 a = i == amounts.length - 1 ? cap - sum : bound(amounts[i], 0, cap - sum);
            t.mint(address(l), a);
            l.onInterest(a);
            sum += a;
            assertEq(l.reserve(), sum);
            assertEq(t.balanceOf(address(l)), l.reserve());
        }
        assertEq(l.reserve(), cap, "reached the supply cap");
    }

    /// @dev Every failure mode × every accruing operation (open, addCollateral, withdrawCollateral,
    ///      borrow, repay, close): the operation succeeds, the whole interest reaches the reserve,
    ///      `PoolInterestRedirected(offered)` is emitted, nothing is minted to the pool, and the supply
    ///      grows by exactly the interest plus the operation's own mint or burn (I2's `E` unchanged).
    function test_failingPool_everyAccruingOperation_isRedirected() public {
        _deploy(false);
        HostilePool.Mode[5] memory modes = [
            HostilePool.Mode.Revert,
            HostilePool.Mode.Panic,
            HostilePool.Mode.BurnAll,
            HostilePool.Mode.WrongSize,
            HostilePool.Mode.NonBool
        ];
        for (uint256 m; m < modes.length; ++m) {
            for (uint256 op; op < 6; ++op) {
                uint256 snap = vm.snapshotState();
                hostile.setMode(modes[m]);
                _warp(1 days);
                _expectRedirect(op);
                vm.revertToState(snap);
            }
        }
    }

    function _expectRedirect(uint256 op) internal {
        uint256 poolBefore = token.balanceOf(pool);
        uint256 reserveBefore = ledger.reserve();
        vm.recordLogs();
        _op(op);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 interest, uint256 toPool, uint256 toReserve, uint256 redirected, bool sawRedirect) =
            _accrual(logs);
        assertGt(interest, 0, "interest accrued");
        assertEq(toPool, 0, "toPool");
        assertEq(toReserve, interest, "the whole interest to the reserve");
        assertTrue(sawRedirect, "PoolInterestRedirected emitted");
        assertEq(redirected, interest * SHARE / BPS, "redirected = offered (R7, floor)");
        assertEq(ledger.reserve() - reserveBefore, interest, "reserve");
        assertEq(token.balanceOf(pool), poolBefore, "nothing minted to the failing pool");
        assertEq(hostile.bookCalls(), 0, "the pool never booked");
    }

    /// @dev The six accruing operations, each valid on the fixture's state.
    function _op(uint256 op) internal {
        vm.startPrank(alice);
        if (op == 0) v.openPosition(10e18, 2000e18, 0, 0);
        else if (op == 1) v.addCollateral(1, 1e18, 0, 0);
        else if (op == 2) v.withdrawCollateral(1, 1e18, 0, 0);
        else if (op == 3) v.borrow(1, 100e18, 0, 0);
        else if (op == 4) v.repay(1, 100e18, 0, 0);
        else v.close(1);
        vm.stopPrank();
    }

    function _accrual(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 interest, uint256 toPool, uint256 toReserve, uint256 redirected, bool sawRedirect)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(v)) continue;
            if (logs[i].topics[0] == VaultManager.InterestAccrued.selector) {
                (, interest, toPool, toReserve,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            } else if (logs[i].topics[0] == VaultManager.PoolInterestRedirected.selector) {
                redirected = abi.decode(logs[i].data, (uint256));
                sawRedirect = true;
            }
        }
    }

    /// @dev The real pool, with its `G` forced to the edge so `onInterest` panics on overflow: accrual
    ///      redirects (the §6.6.3 overflow now costs depositors that interest, nothing else).
    function test_realPool_GOverflow_isRedirected() public {
        _deploy(true);
        stdstore.target(pool)
            .sig("epochToScaleToG(uint256,uint256)")
            .with_key(uint256(0))
            .with_key(uint256(0))
            .checked_write(type(uint256).max);
        uint256 balanceBefore = realPool.interestGainsBalance();
        _warp(1 days);
        vm.recordLogs();
        vm.prank(alice);
        v.repay(1, 1e18, 0, 0);
        (, uint256 toPool,,, bool sawRedirect) = _accrual(vm.getRecordedLogs());
        assertTrue(sawRedirect, "redirected");
        assertEq(toPool, 0);
        assertEq(realPool.interestGainsBalance(), balanceBefore, "the pool's booking was rolled back");
        assertEq(realPool.epochToScaleToG(0, 0), type(uint256).max, "G unchanged");
    }

    /// @dev With every pool failure mode, accrual's only revert path is the token's supply cap, which
    ///      only compounding interest can reach (a harness state near the cap).
    function test_supplyCapExceeded_isAccrualsOnlyRemainingRevert() public {
        _deploy(false);
        hostile.setMode(HostilePool.Mode.Revert);
        _warp(1 days);
        uint256 room = 1; // leave less room than one day's interest
        stdstore.target(address(token)).sig("totalSupply()").checked_write(type(uint128).max - room);
        vm.expectRevert(StableToken.SupplyCapExceeded.selector);
        v.accrue();
        stdstore.target(address(token)).sig("totalSupply()").checked_write(1e30);
        v.accrue(); // the same failing pool, room under the cap: accrual succeeds
    }

    // ------------------------------------------------------------------ AC-2: no faked failures

    /// @dev The floor is `ceil(2·POOL_HOOK_GAS / 63)`; one unit below reverts, the floor itself passes.
    function test_floor_oneBelowReverts_atFloorPasses() public {
        _deploy(false);
        uint256 floor = v.POOL_HOOK_FLOOR();
        assertEq(floor, (2 * HOOK_GAS + 62) / 63, "ceil(2*POOL_HOOK_GAS / 63)");
        assertEq(floor, 6350);
        vm.expectRevert(VaultManager.InsufficientGasForPoolHook.selector);
        v.requirePoolHookGas(floor - 1);
        v.requirePoolHookGas(floor);
        v.requirePoolHookGas(floor + 1);
    }

    /// @dev The griefing sweep against the real pool: every caller gas limit either books the pool's
    ///      share or reverts the whole transaction — never a redirection.
    function test_gasSweep_realPool_noRedirection() public {
        _deploy(true);
        _warp(1 days);
        _sweep();
    }

    /// @dev The same against a pool that needs most of the cap (150k of 200k gas) before it books.
    function test_gasSweep_heavyPool_noRedirection() public {
        _deploy(false);
        hostile.setHeavy(150_000);
        _warp(1 days);
        _sweep();
    }

    /// @dev A pool that genuinely needs more than the cap is redirected when the caller supplies enough.
    function test_poolBurningMoreThanTheCap_isRedirected() public {
        _deploy(false);
        hostile.setHeavy(250_000);
        _warp(1 days);
        vm.recordLogs();
        (bool ok,) = address(v).call{gas: 2_000_000}(abi.encodeCall(VaultManager.accrue, ()));
        assertTrue(ok);
        (,,,, bool sawRedirect) = _accrual(vm.getRecordedLogs());
        assertTrue(sawRedirect, "redirected");
        hostile.setMode(HostilePool.Mode.BurnAll);
        _warp(1 days);
        vm.recordLogs();
        (ok,) = address(v).call{gas: 2_000_000}(abi.encodeCall(VaultManager.accrue, ()));
        assertTrue(ok);
        (,,,, sawRedirect) = _accrual(vm.getRecordedLogs());
        assertTrue(sawRedirect, "redirected");
    }

    /// @dev The assumption behind the gas rule, pinned: a pool that reverts early when short of gas
    ///      hands the gas back, passes the floor, and is redirected at some caller gas limit. The real
    ///      pool never reads gasleft() (spec §6.2), which is why its sweep finds no such limit.
    function test_gasleftBranchingPool_canBeRedirected_theAssumptionMatters() public {
        _deploy(false);
        GasSensitivePool sensitive = new GasSensitivePool(150_000);
        // a fresh VaultManager wired to the sensitive pool, same fixture otherwise
        StableToken t2 = new StableToken("T", "T");
        VaultManagerHarness v2 = new VaultManagerHarness(
            address(weth),
            address(t2),
            address(v.oracle()),
            1.1e18,
            2000e18,
            0.0375e18,
            1_547_125_957_863_212_449,
            SHARE,
            HOOK_GAS
        );
        SortedPositions s2 = new SortedPositions(30);
        StandInDeficitLedger l2 = new StandInDeficitLedger(address(v2));
        v2.wire(address(s2), address(sensitive), address(sensitive), address(0xDE11), address(l2), SHUTDOWN);
        s2.wire(address(v2));
        t2.wire(address(v2), address(sensitive), address(l2), SHUTDOWN);
        vm.prank(alice);
        weth.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.openPosition(10e18, 4000e18, 0, 0);
        _warp(1 days);
        bool faked;
        for (uint256 g = 20_000; g <= 400_000 && !faked; g += 199) {
            uint256 snap = vm.snapshotState();
            uint256 reserve = l2.reserve();
            (bool ok,) = address(v2).call{gas: g}(ACCRUE);
            // success with the whole interest in the reserve = a redirection a caller chose
            if (ok && l2.reserve() > reserve && t2.balanceOf(address(sensitive)) == 0) faked = true;
            vm.revertToState(snap);
        }
        assertTrue(faked, "a gasleft-branching pool can be redirected by the caller's gas choice");
    }

    struct Tally {
        uint256 booked;
        uint256 reverted;
    }

    /// @dev Coarse pass (step 199) from 10k to 400k — above ~260k the pool always receives its full cap,
    ///      so the outcome cannot change — then step 1 for ±600 around the first limit that books.
    function _sweep() internal {
        Tally memory t;
        uint256 firstBook = type(uint256).max;
        for (uint256 g = 10_000; g <= 400_000; g += 199) {
            if (_probe(g, t) && g < firstBook) firstBook = g;
        }
        assertLt(firstBook, type(uint256).max, "some limit books");
        for (uint256 g = firstBook - 600; g <= firstBook + 600; ++g) {
            _probe(g, t);
        }
        emit log_named_uint("first caller gas limit that books", firstBook);
        emit log_named_uint("probes that booked", t.booked);
        emit log_named_uint("probes that reverted the whole transaction", t.reverted);
        assertGt(t.reverted, 0, "the sweep reached starved limits");
    }

    /// @dev One probe at caller gas `g`, from a fresh copy of the state. Returns whether it booked. The
    ///      outcome is read from state, not logs (thousands of probes): a successful accrual either
    ///      booked — the pool's own record grew by the offered share — or redirected, the forbidden
    ///      outcome (debt is non-zero, so something is always offered).
    function _probe(uint256 g, Tally memory t) internal returns (bool booked) {
        uint256 snap = vm.snapshotState();
        uint256 before = _poolBooked();
        uint256 lastAccrual = v.lastAccrual();
        (bool ok,) = address(v).call{gas: g}(ACCRUE);
        if (ok) {
            assertGt(v.lastAccrual(), lastAccrual, "accrued");
            if (_poolBooked() <= before) fail(string.concat("redirected at caller gas ", vm.toString(g)));
            ++t.booked;
            booked = true;
        } else {
            ++t.reverted;
        }
        vm.revertToState(snap);
    }

    bytes internal constant ACCRUE = abi.encodeWithSelector(VaultManager.accrue.selector);

    function _poolBooked() internal view returns (uint256) {
        return address(realPool) == pool ? realPool.interestGainsBalance() : hostile.booked();
    }

    // ------------------------------------------------------------------ constructor (§3.4 index 8)

    function test_constructor_poolHookGasRange() public {
        weth = new MockWETH();
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 8));
        new VaultManager(address(weth), address(1), address(2), 1.1e18, 2000e18, 1, 0, 0, 49_999);
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, 8));
        new VaultManager(address(weth), address(1), address(2), 1.1e18, 2000e18, 1, 0, 0, 1_000_001);
        VaultManager lo =
            new VaultManager(address(weth), address(1), address(2), 1.1e18, 2000e18, 1, 0, 0, 50_000);
        VaultManager hi =
            new VaultManager(address(weth), address(1), address(2), 1.1e18, 2000e18, 1, 0, 0, 1_000_000);
        assertEq(lo.POOL_HOOK_FLOOR(), 1588, "ceil(100k/63)");
        assertEq(hi.POOL_HOOK_FLOOR(), 31_747, "ceil(2M/63)");
    }
}
