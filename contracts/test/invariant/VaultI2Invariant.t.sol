// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {MockLedgerViews, MockPool, MockWETH} from "../utils/VaultMocks.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Inputs are sized from the views (`currentIndex`, `debtOf`), never by accruing first, so
///         each operation's own accrual is the one exercised (review F1).
/// @notice Drives the VaultManager with interest enabled: open, add, withdraw, borrow, repay, close,
///         accrue and time warps from seconds to years. Counts I2's ghost counters from emitted events
///         only (docs/invariants.md I2): N from `InterestAccrued`, X from `PositionUpdated` with op
///         OPEN / BORROW / REPAY, Y from `PositionUpdated` with op CLOSE.
contract VaultI2Handler is Test {
    VaultManager public v;
    StableToken public token;
    MockAggregator public feed;
    MockLedgerViews public ledger;
    address[3] internal actors;
    uint256 public gN;
    uint256 public gX;
    uint256 public gY;
    uint256 public calls;

    constructor(
        VaultManager v_,
        StableToken token_,
        MockAggregator feed_,
        MockLedgerViews ledger_,
        address[3] memory a
    ) {
        (v, token, feed, ledger, actors) = (v_, token_, feed_, ledger_, a);
    }

    function _begin(uint256 dt) internal {
        ++calls;
        vm.warp(block.timestamp + dt);
        feed.setRound(1, 2000e8, block.timestamp);
        vm.recordLogs();
    }

    function _end() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
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
    }

    function _wait(uint256 r) internal pure returns (uint256) {
        return (r >> 8) % (10 ** (r % 9)); // 0 … ~3 years, log-uniform-ish
    }

    function _active(uint256 r) internal view returns (uint256 id) {
        uint256 n = v.nextId();
        if (n == 1) return 0;
        for (uint256 k; k < n - 1; ++k) {
            id = 1 + (r + k) % (n - 1);
            if (v.positions(id).status == VaultManager.Status.Active) return id;
        }
        return 0;
    }

    function open(uint256 r, uint256 debt, uint256 extra) external {
        _begin(_wait(r));
        if (v.activeCount() >= 25) return _end();
        debt = bound(debt, 2000e18, 200_000e18);
        // above index RAY the position owes ceil(ceil(debt·RAY/I)·I/RAY), up to I/RAY wei more than
        // `debt` (R2 then R1): size the collateral for that
        uint256 I = v.currentIndex(); // the index openPosition will accrue to; no pre-accrual (review F1)
        uint256 owed = ((debt * 1e27 + I - 1) / I * I + 1e27 - 1) / 1e27;
        uint256 coll = (1.1e18 * owed + 2000e18 - 1) / 2000e18 + bound(extra, 0, 50e18);
        vm.prank(actors[r % 3]);
        v.openPosition(coll, debt, 0, 0);
        _end();
    }

    function addCollateral(uint256 r, uint256 amount) external {
        _begin(_wait(r));
        uint256 id = _active(r >> 16);
        if (id != 0) {
            vm.prank(actors[r % 3]);
            v.addCollateral(id, bound(amount, 1, 10e18), 0, 0);
        }
        _end();
    }

    function withdraw(uint256 r, uint256 amount) external {
        _begin(_wait(r));
        uint256 id = _active(r >> 16);
        if (id != 0) {
            VaultManager.Position memory p = v.positions(id);
            uint256 need = (1.1e18 * v.debtOf(id) + 2000e18 - 1) / 2000e18;
            if (p.coll > need) {
                vm.prank(p.owner);
                v.withdrawCollateral(id, bound(amount, 1, p.coll - need), 0, 0);
            }
        }
        _end();
    }

    function borrow(uint256 r, uint256 amount) external {
        _begin(_wait(r));
        uint256 id = _active(r >> 16);
        if (id != 0) {
            uint256 cap = v.positions(id).coll * 2000e18 / 1.1e18;
            // a borrow of `a` adds up to I/RAY wei more than `a` to the debt (R2 then R1): keep that margin
            uint256 margin = v.currentIndex() / 1e27 + 2;
            uint256 debt = v.debtOf(id);
            if (cap > debt + margin) {
                vm.prank(v.positions(id).owner);
                v.borrow(id, bound(amount, 1, cap - debt - margin), 0, 0);
            }
        }
        _end();
    }

    function repay(uint256 r, uint256 amount) external {
        _begin(_wait(r));
        uint256 id = _active(r >> 16);
        if (id != 0) {
            address owner = v.positions(id).owner;
            uint256 room = v.debtOf(id) - 2000e18;
            uint256 bal = token.balanceOf(owner);
            uint256 hi = room < bal ? room : bal;
            if (hi > 0) {
                vm.prank(owner);
                v.repay(id, bound(amount, 1, hi), 0, 0);
            }
        }
        _end();
    }

    function close(uint256 r) external {
        _begin(_wait(r));
        uint256 id = _active(r >> 16);
        if (id != 0) {
            address owner = v.positions(id).owner;
            uint256 owed = v.debtOf(id);
            uint256 bal = token.balanceOf(owner);
            if (bal < owed) {
                // the reserve (interest) stands in for a market the owner buys from
                if (token.balanceOf(address(ledger)) >= owed - bal) {
                    vm.prank(address(ledger));
                    token.transfer(owner, owed - bal);
                }
            }
            if (token.balanceOf(owner) >= owed) {
                vm.prank(owner);
                v.close(id);
            }
        }
        _end();
    }

    function accrue(uint256 r) external {
        _begin(_wait(r));
        v.accrue();
        _end();
    }
}

/// @notice I2 with interest enabled (acceptance criterion of P15), plus I1 for the VaultManager and
///         the sum-of-ceilings bound on position debts.
contract VaultI2InvariantTest is Test {
    uint256 internal constant RAY = 1e27;
    VaultManager internal v;
    StableToken internal token;
    MockWETH internal weth;
    VaultI2Handler internal handler;
    MockLedgerViews internal ledger;

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        MockAggregator feed = new MockAggregator(8);
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.setStatus(0, 1);
        feed.setRound(1, 2000e8, block.timestamp);
        OracleAdapter oracle = new OracleAdapter(
            address(feed), address(seq), type(uint64).max, 0, 10e18, 1_000_000e18, 100_000, 3175
        );
        SortedPositions sorted = new SortedPositions(1000);
        ledger = new MockLedgerViews();
        MockPool pool = new MockPool();
        pool.setDeposits(10e18); // the pool takes its share
        v = new VaultManager(
            address(weth),
            address(token),
            address(oracle),
            1.1e18,
            2000e18,
            0.0375e18,
            1_547_125_957_863_212_449,
            7500,
            200_000
        );
        v.wire(address(sorted), address(pool), address(pool), address(0xDE11), address(ledger), address(0x5D));
        sorted.wire(address(v));
        token.wire(address(v), address(pool), address(ledger), address(0x5D));
        address[3] memory a = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        for (uint256 i; i < 3; ++i) {
            weth.mint(a[i], 1e30);
            vm.prank(a[i]);
            weth.approve(address(v), type(uint256).max);
        }
        handler = new VaultI2Handler(v, token, feed, ledger, a);
        targetContract(address(handler));
    }

    /// @dev §10.2: −N·RAY ≤ E ≤ X·I + Y·RAY, strict once the counter is ≥ 1; A = F = 0 here.
    function invariant_I2_supplyEqualsSystemDebtWithinTheDerivedBound() public view {
        uint256 I = v.index();
        uint256 lhs = v.totalNormDebt() * I;
        // E = n·I − (S − A − F)·RAY, with A and F read from the ledger (both 0 until auctions and
        // deficits exist, P20+)
        uint256 rhs = (token.totalSupply() - ledger.auctionDebt() - ledger.deficit()) * RAY;
        if (lhs >= rhs) {
            uint256 e = lhs - rhs;
            if (handler.gX() + handler.gY() >= 1) {
                assertLt(e, handler.gX() * I + handler.gY() * RAY, "I2 upper");
            } else {
                assertEq(e, 0, "I2: E = 0 before any position operation");
            }
        } else {
            if (handler.gN() >= 1) assertLt(rhs - lhs, handler.gN() * RAY, "I2 lower");
            else assertEq(rhs - lhs, 0);
        }
    }

    function invariant_I1_vaultManagerWeth() public view {
        assertEq(
            weth.balanceOf(address(v)), v.totalCollateral() + v.pendingColl() + v.activeCount() * 0.0375e18
        );
    }

    /// @dev Σ debtOf(nᵢ) is a sum of ceilings of the same index: ≥ n·I/RAY and < one wei per position
    /// more.
    function invariant_sumOfPositionDebtsWithinOneWeiEach() public view {
        uint256 sum;
        uint256 count;
        for (uint256 id = 1; id < v.nextId(); ++id) {
            if (v.positions(id).status != VaultManager.Status.Active) continue;
            sum += v.debtOf(id);
            ++count;
        }
        uint256 exact = v.totalNormDebt() * v.currentIndex();
        assertGe(sum * RAY, exact);
        if (count > 0) assertLt(sum * RAY, exact + count * RAY);
    }

    function afterInvariant() external view {
        assertGt(handler.calls(), 0);
    }
}
