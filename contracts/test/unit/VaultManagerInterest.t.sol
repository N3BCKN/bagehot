// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {VaultManagerHarness} from "../utils/VaultManagerHarness.sol";
import {MockHouseViews, MockLedgerViews, MockPool, MockWETH} from "../utils/VaultMocks.sol";
import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Interest accrual and routing (spec §5.1.8, §6.2): the interest vectors, idempotence,
///         index growth without debt, the shutdown freeze, routing, the overflow bound on `dt`, and
///         I2 with interest enabled over long horizons.
contract VaultManagerInterestTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant RATE = 1_547_125_957_863_212_449; // 5 % a year
    uint256 internal constant MAX_RATE = 21_979_553_151_239_153_028; // 100 % a year
    uint256 internal constant GAS_RESERVE = 0.0375e18;

    MockWETH internal weth;
    StableToken internal token;
    VaultManagerHarness internal v;
    SortedPositions internal sorted;
    MockPool internal pool;
    MockLedgerViews internal ledger;
    MockAggregator internal feed;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant SHUTDOWN = address(0x5D);

    function _deploy(uint256 rate, bool b) internal {
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, 1);
        feed.setRound(1, 2000e8, block.timestamp);
        OracleAdapter oracle = new OracleAdapter(
            address(feed), address(seq), type(uint64).max, 0, 10e18, 1_000_000e18, 100_000, 3175
        );
        sorted = new SortedPositions(30);
        ledger = new MockLedgerViews();
        pool = new MockPool();
        address strategy = b ? address(new MockHouseViews()) : address(pool);
        v = new VaultManagerHarness(
            address(weth),
            address(token),
            address(oracle),
            1.1e18,
            2000e18,
            GAS_RESERVE,
            rate,
            b ? 0 : 7500,
            200_000
        );
        v.wire(
            address(sorted), strategy, b ? address(0) : strategy, address(0xDE11), address(ledger), SHUTDOWN
        );
        sorted.wire(address(v));
        token.wire(address(v), strategy, address(ledger), SHUTDOWN);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            weth.mint(who[i], 1e30);
            vm.prank(who[i]);
            weth.approve(address(v), type(uint256).max);
        }
    }

    function setUp() public {
        vm.warp(10_000_000);
        _deploy(RATE, false);
    }

    function _refreshPrice() internal {
        feed.setRound(1, 2000e8, block.timestamp);
    }

    // ------------------------------------------------------------------ vectors (interest.json)

    string internal json;

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _accrueVector(uint256 i) internal {
        string memory p = string.concat(".vectors[", vm.toString(i), "]");
        string memory inp = string.concat(p, ".inputs");
        bool b = keccak256(bytes(vm.parseJsonString(json, string.concat(inp, ".variant")))) == keccak256("B");
        _deploy(_u(string.concat(inp, ".RATE_PER_SECOND")), b);
        assertEq(v.POOL_SHARE_BPS(), _u(string.concat(inp, ".POOL_SHARE_BPS")));
        v.setAccrualState(
            _u(string.concat(inp, ".index")),
            _u(string.concat(inp, ".lastAccrual")),
            _u(string.concat(inp, ".totalNormDebt"))
        );
        if (!b) pool.setDeposits(_u(string.concat(inp, ".totalDeposits")));
        // interest.json#poolHook (CHG-006): book (default) / decline (deposits below MIN_DEPOSIT) / fail
        string memory hook = vm.keyExistsJson(json, string.concat(inp, ".poolHook"))
            ? vm.parseJsonString(json, string.concat(inp, ".poolHook"))
            : "book";
        bool fails = keccak256(bytes(hook)) == keccak256("fail");
        if (fails) pool.setFail(true);
        string memory s = string.concat(p, ".steps[0]");
        vm.warp(_u(string.concat(s, ".t")));
        string memory r = string.concat(s, ".result");
        if (fails) {
            vm.expectEmit(address(v));
            emit VaultManager.PoolInterestRedirected(_u(string.concat(r, ".redirected")));
        }
        vm.expectEmit(address(v));
        emit VaultManager.InterestAccrued(
            _u(string.concat(r, ".index")),
            _u(string.concat(r, ".interest")),
            _u(string.concat(r, ".toPool")),
            _u(string.concat(r, ".toReserve")),
            block.timestamp
        );
        vm.recordLogs();
        v.accrue();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 redirects;
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].topics[0] == VaultManager.PoolInterestRedirected.selector) ++redirects;
        }
        assertEq(redirects, fails ? 1 : 0, "PoolInterestRedirected only when the pool hook fails");
        assertEq(v.index(), _u(string.concat(r, ".index")));
        assertEq(token.balanceOf(address(pool)), b ? 0 : _u(string.concat(r, ".toPool")));
        assertEq(token.balanceOf(address(ledger)), _u(string.concat(r, ".toReserve")));
        assertEq(ledger.reserve(), _u(string.concat(r, ".toReserve")), "ledger notified");
        if (!b) assertEq(pool.interestReceived(), _u(string.concat(r, ".toPool")), "pool notified");
    }

    function test_vectors_accrual() public {
        json = vm.readFile("../spec/vectors/interest.json");
        uint256[4] memory accrual = [uint256(0), 1, 2, 5]; // 5: accrue_pool_hook_fails (CHG-006)
        assertEq(vm.parseJsonString(json, ".vectors[5].name"), "accrue_pool_hook_fails");
        for (uint256 k; k < accrual.length; ++k) {
            uint256 snap = vm.snapshotState();
            _accrueVector(accrual[k]);
            vm.revertToState(snap);
        }
    }

    function test_vectors_frequency_yearlyVsDaily() public {
        json = vm.readFile("../spec/vectors/interest.json");
        string memory e = ".vectors[3].expected";
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 365 days);
        v.accrue();
        assertEq(v.index(), _u(string.concat(e, ".indexYearly")));
        _deploy(RATE, false);
        v.setAccrualState(RAY, t0, 0);
        for (uint256 d = 1; d <= 365; ++d) {
            vm.warp(t0 + d * 1 days);
            v.accrue();
        }
        assertEq(v.index(), _u(string.concat(e, ".indexDaily")));
        assertEq(_u(string.concat(e, ".indexYearly")) - v.index(), _u(string.concat(e, ".difference")));
    }

    /// @dev R1–R3 at index ≈ 1.05 RAY through real borrow / repay calls.
    function test_vectors_conversions() public {
        json = vm.readFile("../spec/vectors/interest.json");
        uint256 index = _u(".vectors[4].inputs.index");
        v.setAccrualState(index, block.timestamp, 0);
        vm.prank(alice);
        v.openPosition(1e27, 2100e18, 0, 0);
        uint256 funds = token.balanceOf(alice);
        for (uint256 i; i < 4; ++i) {
            string memory s = string.concat(".vectors[4].steps[", vm.toString(i), "]");
            uint256 amount = _u(string.concat(s, ".amount"));
            uint256 n0 = v.positions(1).normDebt;
            vm.prank(alice);
            v.borrow(1, amount, 0, 0);
            uint256 up = v.positions(1).normDebt - n0;
            assertEq(up, _u(string.concat(s, ".result.normFromBorrow_up")), "R2");
            assertEq(
                (up * index + RAY - 1) / RAY, _u(string.concat(s, ".result['debtOf(normFromBorrow)']")), "R1"
            );
            n0 = v.positions(1).normDebt;
            vm.prank(alice);
            v.repay(1, amount, 0, 0);
            assertEq(n0 - v.positions(1).normDebt, _u(string.concat(s, ".result.normFromRepay_down")), "R3");
        }
        assertEq(token.balanceOf(alice), funds);
    }

    // ------------------------------------------------------------------ behaviour

    function test_accrue_twiceInOneBlockIsANoOp() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.warp(block.timestamp + 1 days);
        v.accrue();
        uint256 index = v.index();
        uint256 supply = token.totalSupply();
        vm.recordLogs();
        v.accrue();
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(v.index(), index);
        assertEq(token.totalSupply(), supply);
    }

    function test_accrue_indexGrowsWithoutDebtAndMintsNothing() public {
        vm.warp(block.timestamp + 365 days);
        vm.expectEmit(address(v));
        emit VaultManager.InterestAccrued(1_050_000_000_000_000_000_011_578_354, 0, 0, 0, block.timestamp);
        v.accrue();
        assertEq(token.totalSupply(), 0);
        assertEq(v.lastAccrual(), block.timestamp);
    }

    function test_accrue_anyoneButOnlyWhenWired() public {
        VaultManager raw =
            new VaultManager(address(weth), address(token), address(1), 1.1e18, 2000e18, 1, RATE, 0, 200_000);
        vm.expectRevert(WiredBase.NotWired.selector);
        raw.accrue();
        vm.warp(block.timestamp + 10);
        vm.prank(makeAddr("anyone"));
        v.accrue();
        assertEq(v.lastAccrual(), block.timestamp);
    }

    function test_accrue_frozenAfterShutdown() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.warp(block.timestamp + 100 days);
        vm.prank(SHUTDOWN);
        v.onShutdown(); // the module accrues right before; here the index is left as is
        uint256 index = v.index();
        vm.warp(block.timestamp + 100 days);
        v.accrue();
        assertEq(v.index(), index, "frozen");
        assertEq(v.currentIndex(), index, "the view too");
    }

    function test_views_useTheAccruedIndexWithoutWriting() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.warp(block.timestamp + 30 days);
        uint256 viewIndex = v.currentIndex();
        uint256 viewDebt = v.debtOf(1);
        uint256 viewSystem = v.systemDebt();
        assertGt(viewIndex, RAY);
        assertEq(v.index(), RAY, "nothing written by the views");
        v.accrue();
        assertEq(v.index(), viewIndex);
        assertEq(v.debtOf(1), viewDebt);
        assertEq(v.systemDebt(), viewSystem);
    }

    function test_routing_poolShareOnlyWhileThePoolAcceptsIt() public {
        vm.prank(alice);
        v.openPosition(100e18, 100_000e18, 0, 0);
        vm.warp(block.timestamp + 1 days);
        v.accrue(); // pool below MIN_DEPOSIT: everything to the reserve
        assertEq(pool.interestCalls(), 0);
        uint256 r1 = ledger.reserve();
        assertGt(r1, 0);
        pool.setDeposits(1e18);
        vm.warp(block.timestamp + 1 days);
        vm.recordLogs();
        v.accrue();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, uint256 interest, uint256 toPool, uint256 toReserve,) =
            abi.decode(logs[logs.length - 1].data, (uint256, uint256, uint256, uint256, uint256));
        assertEq(toPool, interest * 7500 / 10_000, "R7: floor");
        assertEq(toReserve, interest - toPool);
        assertEq(pool.interestReceived(), toPool);
        assertEq(ledger.reserve(), r1 + toReserve);
    }

    function test_routing_deploymentBAllToTheReserve() public {
        _deploy(RATE, true);
        vm.prank(alice);
        v.openPosition(100e18, 100_000e18, 0, 0);
        vm.warp(block.timestamp + 1 days);
        v.accrue();
        assertEq(token.totalSupply() - 100_000e18, ledger.reserve());
    }

    /// @dev Operations accrue first: a borrow after a year sees the accrued index.
    function test_operationsAccrueFirst() public {
        vm.prank(alice);
        v.openPosition(10e18, 4000e18, 0, 0);
        vm.warp(block.timestamp + 365 days);
        _refreshPrice();
        vm.prank(alice);
        v.borrow(1, 1e18, 0, 0);
        assertEq(v.index(), 1_050_000_000_000_000_000_011_578_354);
        assertEq(v.lastAccrual(), block.timestamp);
    }

    // ------------------------------------------------------------------ every operation accrues first
    // (review F1)

    /// @dev After a wait, the operation must write the index the view predicted, stamp lastAccrual,
    ///      and log InterestAccrued before its own events.
    function _assertAccruedFirst(uint256 expectedIndex) internal {
        assertEq(v.index(), expectedIndex, "the operation accrued to the predicted index");
        assertEq(v.lastAccrual(), block.timestamp, "lastAccrual stamped");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 accrualAt = type(uint256).max;
        uint256 firstOwn = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(v)) continue;
            if (logs[i].topics[0] == VaultManager.InterestAccrued.selector) accrualAt = i;
            else if (firstOwn == type(uint256).max) firstOwn = i;
        }
        assertLt(accrualAt, firstOwn, "InterestAccrued before the operation's own events");
    }

    function _openAndWait() internal returns (uint256 predicted) {
        pool.setDeposits(10e18);
        vm.prank(alice);
        v.openPosition(20e18, 4000e18, 0, 0);
        vm.prank(bob);
        v.openPosition(20e18, 4000e18, 0, 0); // a second holder to top up from
        vm.warp(block.timestamp + 365 days);
        _refreshPrice();
        predicted = v.currentIndex();
        vm.recordLogs();
    }

    function test_accruesFirst_open() public {
        uint256 predicted = _openAndWait();
        vm.prank(bob);
        v.openPosition(20e18, 4000e18, 0, 0);
        _assertAccruedFirst(predicted);
    }

    function test_accruesFirst_addCollateral() public {
        uint256 predicted = _openAndWait();
        vm.prank(bob);
        v.addCollateral(1, 1, 0, 0);
        _assertAccruedFirst(predicted);
    }

    function test_accruesFirst_withdrawCollateral() public {
        uint256 predicted = _openAndWait();
        vm.prank(alice);
        v.withdrawCollateral(1, 1, 0, 0);
        _assertAccruedFirst(predicted);
    }

    function test_accruesFirst_borrow() public {
        uint256 predicted = _openAndWait();
        vm.prank(alice);
        v.borrow(1, 1, 0, 0);
        _assertAccruedFirst(predicted);
    }

    function test_accruesFirst_repay() public {
        uint256 predicted = _openAndWait();
        vm.prank(alice);
        v.repay(1, 1, 0, 0);
        _assertAccruedFirst(predicted);
    }

    /// @dev close also burns exactly the debt the view showed: the accrued one, not the stale one.
    function test_accruesFirst_closeBurnsTheAccruedDebt() public {
        uint256 predicted = _openAndWait();
        uint256 owed = v.debtOf(1);
        assertGt(owed, 4000e18 + 199e18, "a year at 5 %");
        uint256 shortfall = owed - token.balanceOf(alice); // computed first: a call would consume the prank
        vm.prank(bob);
        token.transfer(alice, shortfall);
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        v.close(1);
        _assertAccruedFirst(predicted);
        // supply after = supply before + interest minted at this accrual − owed
        assertEq(token.balanceOf(alice), 0, "burned exactly debtOf as viewed");
        assertGt(token.totalSupply() + owed, supply, "the interest was minted before the burn");
    }

    /// @dev In the window nothing accrues: the rescue paths make no accrual and no external hook call.
    function test_window_rescuePathsDoNotAccrue() public {
        _openAndWait();
        vm.prank(SHUTDOWN);
        v.onShutdown();
        uint256 index = v.index();
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vm.startPrank(alice);
        v.addCollateral(1, 1, 0, 0);
        v.repay(1, 1, 0, 0);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != VaultManager.InterestAccrued.selector, "no accrual in the window");
        }
        assertEq(v.index(), index);
    }

    // ------------------------------------------------------------------ overflow bound on dt

    function _maxDt(uint256 rate, uint256 maxDt) internal {
        _deploy(rate, false);
        uint256 t = maxDt + 2;
        v.setAccrualState(RAY, 1, 0);
        vm.warp(1 + maxDt);
        v.accrue(); // exactly at the bound: fits
        _deploy(rate, false);
        v.setAccrualState(RAY, 1, 0);
        vm.warp(t); // one second beyond
        vm.expectRevert(stdError.arithmeticError);
        v.accrue();
    }

    function test_maxDt_startRate() public {
        _maxDt(RATE, 74_509_693_419);
    }

    function test_maxDt_maxRate() public {
        _maxDt(MAX_RATE, 5_244_687_241);
    }

    // ------------------------------------------------------------------ I2 under accrual, long horizons

    /// @dev §10.2: E = n·I − (S − A − F)·RAY, −N·RAY ≤ E ≤ X·I + Y·RAY (strict once
    /// counted),
    ///      with N, X, Y counted from emitted events.
    function _checkI2(uint256 gN, uint256 gX, uint256 gY) internal view {
        uint256 n = v.totalNormDebt();
        uint256 I = v.index();
        uint256 lhs = n * I;
        uint256 rhs = token.totalSupply() * RAY; // A = F = 0 in these sequences
        if (lhs >= rhs) {
            uint256 e = lhs - rhs;
            if (gX + gY >= 1) assertLt(e, gX * I + gY * RAY, "I2 upper");
            else assertEq(e, 0);
        } else {
            uint256 neg = rhs - lhs;
            if (gN >= 1) assertLt(neg, gN * RAY, "I2 lower");
            else assertEq(neg, 0);
        }
    }

    /// @dev Σ debtOf(nᵢ) is a sum of ceilings: at least n·I/RAY and less than one wei per position more.
    function _checkSumOfDebts() internal view {
        uint256 sum;
        uint256 count;
        for (uint256 id = 1; id < v.nextId(); ++id) {
            if (v.positions(id).status != VaultManager.Status.Active) continue;
            sum += v.debtOf(id);
            ++count;
        }
        uint256 exact = v.totalNormDebt() * v.currentIndex();
        assertGe(sum * RAY, exact, "never below the exact system debt");
        assertLt(sum * RAY, exact + (count + (count == 0 ? 1 : 0)) * RAY, "within one wei per position");
    }

    function _count(Vm.Log[] memory logs, uint256 gN, uint256 gX, uint256 gY)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(v)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.InterestAccrued.selector) {
                ++gN;
            } else if (t == VaultManager.PositionUpdated.selector) {
                (,,,,,, uint8 op) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint8));
                if (op == 1 || op == 4 || op == 5) ++gX;
                else if (op == 6) ++gY;
            }
        }
        return (gN, gX, gY);
    }

    uint256 internal gN;
    uint256 internal gX;
    uint256 internal gY;

    function _closeWithTopUp(uint256 id, address owner) internal {
        uint256 owed = v.debtOf(id); // debtOf reads currentIndex, so it equals what close will burn
        uint256 bal = token.balanceOf(owner);
        if (bal < owed) {
            // buy the shortfall from the reserve holder (stands in for a market)
            if (token.balanceOf(address(ledger)) < owed - bal) return;
            vm.prank(address(ledger));
            token.transfer(owner, owed - bal);
        }
        vm.prank(owner);
        v.close(id);
    }

    function _positionStep(uint256 seed, uint256 op) internal {
        uint256 id = 1 + (seed >> 64) % (v.nextId() - 1);
        if (v.positions(id).status != VaultManager.Status.Active) return;
        address owner = v.positions(id).owner;
        if (op == 2) {
            uint256 debt = v.debtOf(id);
            uint256 room = debt > 2000e18 ? debt - 2000e18 : 0;
            uint256 bal = token.balanceOf(owner);
            uint256 hi = room < bal ? room : bal;
            if (hi == 0) return;
            vm.prank(owner);
            v.repay(id, 1 + (seed >> 128) % hi, 0, 0);
        } else if (op == 3) {
            vm.prank(owner);
            v.borrow(id, 1 + (seed >> 128) % 1000e18, 0, 0);
        } else {
            _closeWithTopUp(id, owner);
        }
    }

    function _step(uint256 seed) internal {
        vm.warp(block.timestamp + 1 + (seed >> 8) % (10 ** (seed % 9))); // waits of 1 s … ~3 years
        _refreshPrice();
        uint256 op = (seed >> 48) % 5;
        vm.recordLogs();
        if (op == 0 || v.activeCount() == 0) {
            vm.prank((seed >> 40) % 2 == 0 ? alice : bob);
            v.openPosition(100e18, 2000e18 + (seed >> 64) % 50_000e18, 0, 0);
        } else if (op == 1) {
            v.accrue();
        } else {
            _positionStep(seed, op);
        }
        (gN, gX, gY) = _count(vm.getRecordedLogs(), gN, gX, gY);
        _checkI2(gN, gX, gY);
        _checkSumOfDebts();
    }

    /// @dev Random operations separated by random waits from 1 second to ~3 years; I2 and the
    ///      sum-of-ceilings bound after every step.
    function testFuzz_I2_longHorizon(uint256 seed) public {
        for (uint256 i; i < 30; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
        }
    }
}
