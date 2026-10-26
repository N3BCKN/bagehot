// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../../../src/core/HintHelpers.sol";
import {OracleAdapter} from "../../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../../src/core/SortedPositions.sol";
import {StableToken} from "../../../src/core/StableToken.sol";
import {VaultManager} from "../../../src/core/VaultManager.sol";
import {ISortKeySource} from "../../../src/interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../../../src/interfaces/ISortedPositions.sol";
import {InsufficientBalance, PriceUnusable, SystemSettled, SystemShutdown} from "../../../src/lib/Errors.sol";
import {StabilityPool} from "../../../src/liquidation/StabilityPool.sol";
import {MockAggregator} from "../../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../../src/mocks/MockSequencerFeed.sol";
import {RedemptionModule} from "../../../src/redemption/RedemptionModule.sol";
import {CountingOracle} from "../../utils/CountingOracle.sol";
import {I13HiddenKeys} from "../../utils/I13HiddenKeys.sol";
import {RedemptionLastVisit} from "../../utils/RedemptionLastVisit.sol";
import {MockPurchaseHouse, MockShutdownGate} from "../../utils/RedemptionMocks.sol";
import {VaultManagerHarness} from "../../utils/VaultManagerHarness.sol";
import {MockLedgerViews, MockWETH} from "../../utils/VaultMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The core handler (P17): deploys the core of one deployment (A or B) at the start
///         parameters and drives it with bounded actions — open, addCollateral, withdrawCollateral,
///         borrow, repay, close, redeem, redeemAcrossTail, warp, movePrice (±30 %), toggleOracle
///         (all nine unusable reasons of §6.10.1), donate, the real StabilityPool's deposit / withdraw /
///         claim in deployment A (P19), the test-only
///         redistribute (I13's tolerance regime before P20) and rare shutdown / settlement through the
///         wired shutdown address (before the ShutdownModule exists). `claimSurplus` from the prompt is
///         superseded by the P16 push model (no such function).
/// @dev Every protocol call is wrapped in try/catch; an error outside the action's allow-list is an
///      unexpected revert. I9 and I12 are checked inside the actions; everything else is a view
///      check (`check*`) that the Foundry invariants assert and the Medusa properties return.
///      I2's counters and the I5 analysis of a redemption are reconstructed from state, so they
///      work without event logs (Medusa has no recordLogs); under Foundry the handler also counts
///      from events and `checkEventsAgree` asserts the two agree.
contract CoreHandler is Test {
    // ------------------------------------------------------------------ parameters (§3.1 start)
    uint256 internal constant START = 10_000_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MCR = 1.1e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant GAS_RESERVE = 0.0375e18;
    uint256 internal constant RATE = 1_547_125_957_863_212_449;
    uint256 internal constant POOL_SHARE_BPS = 7500;
    uint256 internal constant FEE_FLOOR = 0.005e18;
    uint256 internal constant BETA = 2;
    uint256 internal constant DECAY = 999_983_955_055_097_432_543_272_791;
    uint256 internal constant CRITICAL_TCR = 1.05e18;
    uint256 internal constant MIN_PRICE = 10e18;
    uint256 internal constant MAX_PRICE = 1_000_000e18;
    uint256 internal constant STALENESS = 3600;
    uint256 internal constant GRACE = 3600;
    uint256 internal constant HINT_STEPS = 6;
    uint256 internal constant MAX_POSITIONS = 24;

    // ------------------------------------------------------------------ the system
    bool public immutable variantB;
    bool public immutable eventsAvailable; // Foundry: true; Medusa: false
    MockWETH public weth;
    StableToken public token;
    MockAggregator public feed;
    MockSequencerFeed public seq;
    OracleAdapter public oracle;
    CountingOracle public counting;
    SortedPositions public sorted;
    MockLedgerViews public ledger;
    StabilityPool public pool; // deployment A only (P19); address(0) in B
    MockPurchaseHouse public house;
    VaultManagerHarness public v;
    RedemptionModule public rm;
    MockShutdownGate public gate;
    HintHelpers public hints;
    address[5] public actors;
    uint256 public price = 2000e18;
    uint256 public oracleMode; // 0 healthy, 1..9 = OracleAdapter.Reason
    uint256 internal seqStart;
    bytes32 public paramsHash; // I11

    // ------------------------------------------------------------------ ghosts
    uint256 public gN; // I2 counters, reconstructed from state
    uint256 public gX;
    uint256 public gY;
    uint256 public eN; // the same, from events (Foundry only)
    uint256 public eX;
    uint256 public eY;
    uint256 public eventMismatches; // I5 reconstruction vs PositionRedeemed / Redeemed
    mapping(address => uint256) public donatedWeth;
    mapping(address => uint256) public donatedToken;
    uint256 public unexpectedReverts;
    bytes4 public lastUnexpected;
    string public lastUnexpectedAction;
    uint256 public i9Violations;
    uint256 public poolEntitlementViolations; // I3: withdraw paid other than min(x, compounded)
    uint256 public i12Violations;
    uint256 public oracleModeMismatches;
    uint256 public i5Violations;
    uint256 public partialOrderViolations;
    uint256 public skipViolations;
    uint256 public lastVisitWithoutReason;
    // I13 exactness (CHG-005): key unchanged since the last insertion, every member exact then
    mapping(uint256 => bool) public exact;
    mapping(uint256 => uint256) internal keyColl;
    mapping(uint256 => uint256) internal keyNorm;
    uint256 public nonExact;
    uint256 public stepsAllExact;
    uint256 public stepsNonExact;
    uint256 public maxNeededK; // the smallest k each observed list needed, maximised (k re-validation)
    // CHG-008 (superseded; measured for comparison only): m(p) = redistributions since p's last insertion
    uint256 public redistributions;
    mapping(uint256 => uint256) internal redistAtPlacement;
    // I13 hidden-key bound (CHG-009): h and ι per member, fixed at insertion
    mapping(uint256 => I13HiddenKeys.Rat) internal hOf;
    mapping(uint256 => int256) internal iotaOf;
    uint256 public insertionViolations; // an insertion not exact against its neighbours' keys (§6.3.1)
    uint256 public insertionsWithIota; // insertions that inherited a non-zero ι (docs/fuzzing.md)
    uint256 public maxIotaRelE18; // largest ι / (h + LDebt) at insertion, WAD-scaled (docs/fuzzing.md)
    uint256 public maxPairTolRelE18; // largest observed-key pair tolerance, relative (docs/fuzzing.md)
    uint256 public maxChg008PairRelE18; // CHG-008's pair tolerance on the same pairs, relative (comparison)
    uint256 public maxRelativeSlackE18; // max over members of max(kc/c, kn/n), WAD-scaled
    uint256 public minMemberStake = type(uint256).max;
    uint256 public eRedistributions; // HarnessRedistributed events (Foundry)
    // coverage
    mapping(bytes32 => uint256) public ok;
    uint256 public calls;

    constructor(bool variantB_, bool eventsAvailable_, address[5] memory actors_) {
        variantB = variantB_;
        eventsAvailable = eventsAvailable_;
        actors = actors_;
        vm.warp(START);
        _deploy();
        for (uint256 i; i < actors_.length; ++i) {
            weth.mint(actors_[i], 1e30);
            vm.prank(actors_[i]);
            weth.approve(address(v), type(uint256).max);
        }
        // a live base: TCR ≈ 1.49 at 2,000, so price falls reach the critical-TCR gate
        _seedOpen(actors_[4], 25e18, 30_000e18);
        _seedOpen(actors_[0], 9e18, 15_000e18);
        _seedOpen(actors_[1], 10e18, 15_000e18);
        _seedOpen(actors_[2], 12e18, 15_000e18);
        paramsHash = _paramsHash();
        eX = gX; // the seeded opens happened before any log recording
    }

    function _deploy() internal {
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        seq = new MockSequencerFeed();
        seqStart = START - 100_000;
        seq.setStatus(0, seqStart);
        feed.setRound(1, int256(price / 1e10), block.timestamp);
        oracle = new OracleAdapter(
            address(feed), address(seq), STALENESS, GRACE, MIN_PRICE, MAX_PRICE, 100_000, 3175
        );
        counting = new CountingOracle(oracle);
        sorted = new SortedPositions(HINT_STEPS);
        ledger = new MockLedgerViews();
        if (!variantB) pool = new StabilityPool(address(weth), address(token), 0.05e18, 1e18);
        house = new MockPurchaseHouse();
        address strategy = variantB ? address(house) : address(pool);
        v = new VaultManagerHarness(
            address(weth),
            address(token),
            address(counting),
            MCR,
            MIN_DEBT,
            GAS_RESERVE,
            RATE,
            variantB ? 0 : POOL_SHARE_BPS,
            200_000
        );
        rm = new RedemptionModule(address(token), address(counting), FEE_FLOOR, BETA, DECAY);
        gate = new MockShutdownGate(address(v), variantB ? address(house) : address(0), CRITICAL_TCR);
        hints = new HintHelpers(ISortKeySource(address(v)), ISortedPositions(address(sorted)));
        v.wire(
            address(sorted),
            strategy,
            variantB ? address(0) : strategy,
            address(rm),
            address(ledger),
            address(gate)
        );
        sorted.wire(address(v));
        token.wire(address(v), strategy, address(ledger), address(gate));
        rm.wire(address(v), address(gate), variantB ? address(house) : address(0));
        if (!variantB) pool.wire(address(v), address(ledger));
    }

    function _seedOpen(address who, uint256 coll, uint256 debt) internal {
        vm.prank(who);
        uint256 id = v.openPosition(coll, debt, 0, 0);
        ++gX;
        _placed(id);
    }

    // ================================================================== actions

    /// @dev Bookkeeping around every action, also when the body returns early.
    modifier action() {
        _begin();
        _;
        _end();
    }

    function open(uint256 actorSeed, uint256 debtSeed, uint256 icrSeed) external action {
        if (v.activeCount() >= MAX_POSITIONS) return;
        address who = _actor(actorSeed);
        // a quarter of the opens sit at exactly MIN_DEBT, where a partial is cancelled
        uint256 debt = debtSeed % 4 == 0 ? MIN_DEBT : bound(debtSeed, MIN_DEBT, 30_000e18);
        uint256 I = v.currentIndex();
        uint256 n = Math.mulDiv(debt, RAY, I, Math.Rounding.Ceil);
        uint256 debtOf = Math.mulDiv(n, I, RAY, Math.Rounding.Ceil);
        uint256 coll = Math.mulDiv(bound(icrSeed, MCR, 3e18), debtOf, price, Math.Rounding.Ceil) + 1;
        (uint256 hint,,) = hints.getApproxHint(coll, n, 10, debtSeed); // before the prank
        bool unusable = _oracleUnusable();
        uint256 next = v.nextId();
        vm.prank(who);
        try v.openPosition(coll, debt, hint, hint) {
            if (unusable) ++i12Violations;
            ++ok["open"];
            ++gX;
            _placed(next);
        } catch (bytes memory err) {
            _discardLogs();
            bytes4 sel = bytes4(err);
            if (unusable && !v.shutdown()) {
                if (sel != PriceUnusable.selector) ++i12Violations;
            } else if (sel != SortedPositions.StaleHint.selector && sel != SystemShutdown.selector) {
                _unexpected(sel, "open");
            }
        }
    }

    function addCollateral(uint256 actorSeed, uint256 idSeed, uint256 amountSeed) external action {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address who = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, 50e18);
        (uint256 c, uint256 n) = v.effective(id);
        (bool exactHints, uint256 up, uint256 lo) = _slot(id, c + amount, n);
        bool settled = v.settled();
        uint256 readsBefore = counting.reads();
        vm.prank(who);
        try v.addCollateral(id, amount, up, lo) {
            ++ok["add"];
            _placed(id);
        } catch (bytes memory err) {
            _discardLogs();
            bytes4 sel = bytes4(err);
            if (!settled && exactHints) {
                ++i9Violations; // I9: must succeed
            } else if (sel != SystemSettled.selector && sel != SortedPositions.StaleHint.selector) {
                _unexpected(sel, "add");
            }
        }
        if (counting.reads() != readsBefore) ++i9Violations; // I9: no oracle read
    }

    function withdrawCollateral(uint256 idSeed, uint256 amountSeed) external action {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        VaultManager.Position memory p = v.positions(id);
        uint256 amount = bound(amountSeed, 1, p.coll / 2 + 1);
        (uint256 c, uint256 n) = v.effective(id);
        if (amount > c) return;
        (, uint256 up, uint256 lo) = _slot(id, c - amount, n);
        bool unusable = _oracleUnusable();
        vm.prank(p.owner);
        try v.withdrawCollateral(id, amount, up, lo) {
            if (unusable) ++i12Violations;
            ++ok["withdraw"];
            _placed(id);
        } catch (bytes memory err) {
            _discardLogs();
            bytes4 sel = bytes4(err);
            if (unusable && !v.shutdown()) {
                if (sel != PriceUnusable.selector) ++i12Violations;
            } else if (
                sel != VaultManager.IcrBelowMcr.selector && sel != SortedPositions.StaleHint.selector
                    && sel != SystemShutdown.selector
            ) {
                _unexpected(sel, "withdraw");
            }
        }
    }

    function borrow(uint256 idSeed, uint256 amountSeed) external action {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address owner = v.positions(id).owner;
        uint256 amount = bound(amountSeed, 1, 5000e18);
        (uint256 c, uint256 n) = v.effective(id);
        uint256 dn = Math.mulDiv(amount, RAY, v.currentIndex(), Math.Rounding.Ceil);
        (, uint256 up, uint256 lo) = _slot(id, c, n + dn);
        bool unusable = _oracleUnusable();
        vm.prank(owner);
        try v.borrow(id, amount, up, lo) {
            if (unusable) ++i12Violations;
            ++ok["borrow"];
            ++gX;
            _placed(id);
        } catch (bytes memory err) {
            _discardLogs();
            bytes4 sel = bytes4(err);
            if (unusable && !v.shutdown()) {
                if (sel != PriceUnusable.selector) ++i12Violations;
            } else if (
                sel != VaultManager.IcrBelowMcr.selector && sel != SortedPositions.StaleHint.selector
                    && sel != SystemShutdown.selector
            ) {
                _unexpected(sel, "borrow");
            }
        }
    }

    function repay(uint256 actorSeed, uint256 idSeed, uint256 amountSeed) external action {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address who = _actor(actorSeed);
        uint256 maxRepay = v.debtOf(id) - MIN_DEBT;
        if (maxRepay == 0) return;
        uint256 amount = bound(amountSeed, 1, maxRepay);
        if (token.balanceOf(who) < amount) return;
        (uint256 c, uint256 n) = v.effective(id);
        uint256 dn = Math.mulDiv(amount, RAY, v.currentIndex());
        (bool exactHints, uint256 up, uint256 lo) = _slot(id, c, n - dn);
        bool settled = v.settled();
        uint256 readsBefore = counting.reads();
        vm.prank(who);
        try v.repay(id, amount, up, lo) {
            ++ok["repay"];
            ++gX;
            _placed(id);
        } catch (bytes memory err) {
            _discardLogs();
            bytes4 sel = bytes4(err);
            if (!settled && exactHints) {
                ++i9Violations;
            } else if (sel != SystemSettled.selector && sel != SortedPositions.StaleHint.selector) {
                _unexpected(sel, "repay");
            }
        }
        if (counting.reads() != readsBefore) ++i9Violations;
    }

    function close(uint256 idSeed) external action {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address owner = v.positions(id).owner;
        uint256 debt = v.debtOf(id);
        _topUp(owner, debt);
        if (token.balanceOf(owner) < debt) return;
        bool settled = v.settled();
        uint256 readsBefore = counting.reads();
        vm.prank(owner);
        try v.close(id) {
            ++ok["close"];
            ++gY;
            _forget(id);
        } catch (bytes memory err) {
            _discardLogs();
            if (!settled) ++i9Violations;
            else if (bytes4(err) != SystemSettled.selector) _unexpected(bytes4(err), "close");
        }
        if (counting.reads() != readsBefore) ++i9Violations;
    }

    /// @param hintMode 0: none; 1: the hint helper's; 2: the head for both (stale with HINT_STEPS)
    function redeem(uint256 actorSeed, uint256 amountSeed, uint256 itSeed, uint8 hintMode) external action {
        address who = _actor(actorSeed);
        uint256 bal = token.balanceOf(who);
        if (bal == 0) return;
        // dust a third of the time (never above the balance: InsufficientBalance is not a protocol event
        // here)
        uint256 amount =
            amountSeed % 3 == 0 ? bound(amountSeed, 1, Math.min(1e6, bal)) : bound(amountSeed, 1, bal);
        _redeem(who, amount, bound(itSeed, 1, 8), hintMode);
    }

    /// @notice The first redeemable node in full and a small partial on the next: the shape whose last
    ///         visit can be a cancelled partial in a successful call.
    function redeemAcrossTail(uint256 actorSeed, uint256 extraSeed, uint8 hintMode) external action {
        address who = _actor(actorSeed);
        uint256 first = sorted.getLast();
        for (uint256 k; k < 6 && first != 0 && v.isLiquidatable(first, price); ++k) {
            first = sorted.getPrev(first);
        }
        if (first == 0 || v.isLiquidatable(first, price)) return;
        uint256 amount = v.debtOf(first) + bound(extraSeed, 1, 1000e18);
        _topUp(who, amount);
        if (token.balanceOf(who) < amount) return;
        _redeem(who, amount, 8, hintMode);
    }

    function warp(uint256 seed) external action {
        vm.warp(block.timestamp + bound(seed, 1, 7 days));
        _applyOracleMode();
    }

    function movePrice(uint256 seed) external action {
        price = Math.min(Math.max(price * bound(seed, 70, 130) / 100, 100e18), 100_000e18) / 1e10 * 1e10;
        _applyOracleMode();
    }

    /// @notice Two times in three healthy, otherwise one of the nine unusable reasons of §6.10.1.
    function toggleOracle(uint256 seed) external action {
        oracleMode = seed % 3 != 0 ? 0 : 1 + (seed / 3) % 9;
        _applyOracleMode();
    }

    function donate(uint256 holderSeed, uint256 amountSeed, bool stable) external action {
        address holder = holderSeed % 2 == 0 ? address(v) : address(rm);
        uint256 amount = bound(amountSeed, 1, 10e18);
        if (stable) {
            address from = _actor(amountSeed);
            if (token.balanceOf(from) < amount) return;
            vm.prank(from);
            token.transfer(holder, amount);
            donatedToken[holder] += amount;
        } else {
            weth.mint(holder, amount);
            donatedWeth[holder] += amount;
        }
    }

    /// @notice Deployment A: a stability-pool deposit from an actor's stablecoin (P19). Sizes span the
    ///         minimum, so the pool's interest share switches on and off (P15-2).
    function poolDeposit(uint256 actorSeed, uint256 amountSeed) external action {
        if (variantB) return;
        address a = _actor(actorSeed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(a);
        try pool.deposit(amount) {
            ++ok["poolDeposit"];
        } catch (bytes memory err) {
            _allow(err, StabilityPool.DepositTooSmall.selector, InsufficientBalance.selector, "poolDeposit");
        }
    }

    /// @notice Deployment A: a partial or full (`type(uint256).max`) pool withdrawal. I3's entitlement
    ///      clause is checked exactly through `totalDeposits`: accrual inside the call can add interest
    ///      gain (paid in the same transfer), but never changes the compounded deposit, so the amount
    ///      withdrawn is `T before − T after − swept dust`, and must equal `min(x, compounded before)`.
    function poolWithdraw(uint256 actorSeed, uint256 amountSeed, bool all) external action {
        if (variantB) return;
        address a = _actor(actorSeed);
        (uint256 initial,,,,,) = pool.deposits(a);
        if (initial == 0) return;
        uint256 x = all ? type(uint256).max : bound(amountSeed, 1, 2 * initial);
        uint256 compounded = pool.compoundedDeposit(a);
        uint256 t0 = pool.totalDeposits();
        uint256 dust0 = ledger.poolDust();
        vm.prank(a);
        try pool.withdraw(x) {
            ++ok["poolWithdraw"];
            uint256 w = t0 - pool.totalDeposits() - (ledger.poolDust() - dust0);
            if (w != (x < compounded ? x : compounded)) ++poolEntitlementViolations;
        } catch (bytes memory err) {
            _allow(
                err, StabilityPool.DepositTooSmall.selector, StabilityPool.NoDeposit.selector, "poolWithdraw"
            );
        }
    }

    /// @notice Deployment A: claim pool gains.
    function poolClaim(uint256 actorSeed) external action {
        if (variantB) return;
        address a = _actor(actorSeed);
        (uint256 initial,,,,,) = pool.deposits(a);
        if (initial == 0) return;
        vm.prank(a);
        try pool.claimGains() {
            ++ok["poolClaim"];
        } catch (bytes memory err) {
            _allow(err, StabilityPool.NoDeposit.selector, StabilityPool.NoDeposit.selector, "poolClaim");
        }
    }

    function _allow(bytes memory err, bytes4 a, bytes4 b, string memory what) internal {
        bytes4 sel = bytes4(err);
        if (sel != a && sel != b) _unexpected(sel, what);
        _discardLogs();
    }

    /// @notice Test-only redistribution of one position (deployment A, live phase), standing in for a
    ///         liquidation: like one, it needs a usable price, so the oracle recovers first. With fewer
    ///         than two active positions it first opens one, so that every run can reach I13's
    ///         tolerance regime (CHG-005) even after the actors closed everything.
    function redistribute(uint256 idSeed) external action {
        if (variantB || v.shutdown()) return;
        // CHG-005 asks every run to check the exact order on a list the run has changed, so the first
        // redistribution waits for one exact step after an action. No state is lost: any action
        // before it reaches the same states (the list is exact until something redistributes).
        if (stepsAllExact == 0) return;
        // it stands in for a liquidation, which requires a usable price (§7): the oracle recovers first
        if (_oracleUnusable()) {
            oracleMode = 0;
            _applyOracleMode();
        }
        if (v.activeCount() < 2) {
            uint256 next = v.nextId();
            uint256 I = v.currentIndex();
            uint256 debtOf =
                Math.mulDiv(Math.mulDiv(MIN_DEBT, RAY, I, Math.Rounding.Ceil), I, RAY, Math.Rounding.Ceil);
            uint256 coll = 2 * Math.mulDiv(MCR, debtOf, price, Math.Rounding.Ceil); // ICR 2.2 at any price
            vm.prank(actors[idSeed % actors.length]);
            try v.openPosition(coll, MIN_DEBT, 0, 0) {
                ++gX;
                _placed(next);
            } catch (bytes memory err) {
                _discardLogs();
                _unexpected(bytes4(err), "redistribute: open");
            }
        }
        uint256 id = _pick(idSeed);
        if (id == 0 || v.totalStakes() <= v.positions(id).stake) return;
        try v.redistribute(id) { // its preconditions are checked above: any revert is a failure
            ++redistributions;
            ++ok["redistribute"];
            _forget(id);
        } catch (bytes memory err) {
            _discardLogs();
            _unexpected(bytes4(err), "redistribute");
        }
    }

    /// @notice Rarely, the wired shutdown address freezes the vault (as `check()` will: accrue first).
    function triggerShutdown(uint256 seed) external action {
        if (seed % 128 != 0 || v.shutdown()) return;
        // in A, only after this run reached I13's tolerance regime: once shut down, nothing can be
        // redistributed, and CHG-005 asks every run for both regimes (B covers the window with an
        // exact list, since it never redistributes)
        if (!variantB && stepsNonExact == 0) return;
        try v.accrue() {}
        catch (bytes memory err) {
            _discardLogs();
            _unexpected(bytes4(err), "shutdown: accrue");
            return;
        }
        vm.prank(address(gate));
        try v.onShutdown() {
            ++ok["shutdown"];
        } catch (bytes memory err) {
            _discardLogs();
            _unexpected(bytes4(err), "shutdown");
        }
    }

    /// @notice Rarely, after the trigger, settlement hands the collateral to the shutdown address.
    function settle(uint256 seed) external action {
        if (seed % 16 != 0 || !v.shutdown() || v.settled()) return;
        vm.prank(address(gate));
        try v.onSettlement() {
            ++ok["settle"];
        } catch (bytes memory err) {
            _discardLogs();
            _unexpected(bytes4(err), "settle");
        }
    }

    /// @notice Settled phase: an owner reclaims the gas reserve of a still-active position.
    function reclaimGasReserve(uint256 idSeed) external action {
        if (!v.settled()) return;
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        vm.prank(v.positions(id).owner);
        try v.reclaimGasReserve(id) {
            ++ok["reclaim"];
            ++gY; // §5.1.10 emits PositionUpdated(OP_CLOSE), which the event rule counts (I2 is not checked
            // once settled)
            _forget(id);
        } catch (bytes memory err) {
            _discardLogs();
            _unexpected(bytes4(err), "reclaim");
        }
    }

    // ================================================================== redemption analysis

    /// @dev What a redeem call saw before it ran: the first `maxIt` nodes from the tail, whether each
    ///      was below MCR at the call's price and index, and its stored state.
    struct Pre {
        uint256 amount;
        uint256 maxIt;
        uint256 up;
        uint256 lo;
        uint256 balance;
        uint256[] order;
        bool[] below;
        uint256[] coll;
        uint256[] norm;
        uint256[] debt; // debtOf at the call's index (this block: currentIndex = the post-accrual index)
        uint256[] allIds; // the whole list, from the tail
        bytes32[] allState; // each member's stored coll, normDebt, stake and snapshots
    }

    function _redeem(address who, uint256 amount, uint256 maxIt, uint8 hintMode) internal {
        _lastRedeemer = who;
        Pre memory c = _pre(who, amount, maxIt, hintMode);
        bool unusable = _oracleUnusable();
        // live phase only: once shut down, redeem reverts SystemShutdown first and the redemption
        // classifier does not apply to frozen or settled positions
        bool live = !unusable && !v.shutdown();
        bool gateShut = live && gate.belowCritical(price);
        bool nothingDue = live && _nothingRedeemable(c);
        vm.prank(who);
        try rm.redeem(c.amount, c.maxIt, WAD, c.up, c.lo) {
            if (unusable) ++i12Violations;
            ++ok["redeem"];
            _analyse(who, c);
        } catch (bytes memory err) {
            _discardLogs();
            bytes4 sel = bytes4(err);
            if (unusable && !v.shutdown()) {
                if (sel != PriceUnusable.selector) ++i12Violations;
            } else if (
                !(sel == RedemptionModule.TCRBelowCritical.selector && gateShut)
                    && !(sel == RedemptionModule.NothingRedeemed.selector && nothingDue && !gateShut)
                    && !(sel == SystemShutdown.selector && v.shutdown())
            ) {
                _unexpected(sel, "redeem"); // a revert the state before the call does not justify
            }
        }
    }

    /// @dev Whether §6.7.3's loop, run on the state before the call, redeems nothing: every node it
    ///      can visit is below MCR, or the first one that is not is a legitimately cancelled partial.
    function _nothingRedeemable(Pre memory c) internal view returns (bool) {
        for (uint256 k; k < c.order.length; ++k) {
            if (c.below[k]) continue;
            RedemptionLastVisit.Reason r = RedemptionLastVisit.classify(
                v,
                sorted,
                RedemptionLastVisit.Visit(
                    c.order[k], c.amount, rm.redemptionFeeRate(c.amount), price, c.up, c.lo
                )
            );
            return r != RedemptionLastVisit.Reason.None;
        }
        return true;
    }

    function _pre(address who, uint256 amount, uint256 maxIt, uint8 hintMode)
        internal
        view
        returns (Pre memory c)
    {
        (c.amount, c.maxIt, c.balance) = (amount, maxIt, token.balanceOf(who));
        uint256 n = Math.min(maxIt, sorted.getSize());
        c.order = new uint256[](n);
        c.below = new bool[](n);
        c.coll = new uint256[](n);
        c.norm = new uint256[](n);
        c.debt = new uint256[](n);
        uint256 cur = sorted.getLast();
        for (uint256 k; k < n; ++k) {
            c.order[k] = cur;
            c.below[k] = v.isLiquidatable(cur, price);
            VaultManager.Position memory p = v.positions(cur);
            (c.coll[k], c.norm[k], c.debt[k]) = (p.coll, p.normDebt, v.debtOf(cur));
            cur = sorted.getPrev(cur);
        }
        c.allIds = new uint256[](sorted.getSize());
        c.allState = new bytes32[](c.allIds.length);
        cur = sorted.getLast();
        for (uint256 k; cur != 0; (k, cur) = (k + 1, sorted.getPrev(cur))) {
            (c.allIds[k], c.allState[k]) = (cur, _stateHash(cur));
        }
        hintMode %= 3;
        if (hintMode == 1 && token.totalSupply() > 0) {
            (c.up, c.lo,,) =
                hints.getRedemptionHints(amount, price, maxIt, rm.redemptionFeeRate(amount), 15, amount);
        } else if (hintMode == 2) {
            (c.up, c.lo) = (sorted.getFirst(), sorted.getFirst());
        }
    }

    /// @dev I5 from state alone (Medusa has no logs). Full redemptions are the nodes now
    ///      ClosedByRedemption. A partial need not change any stored field — a few wei at an index
    ///      above RAY cancel 0 normalised debt for 0 collateral — so it is inferred from what was
    ///      burned: `d = burned − Σ debts closed`; if positive, the partial is the first node after the
    ///      last full one that is not below MCR. If stablecoin remained and there was no partial, the
    ///      loop went on through skipped nodes to a node it left as a cancelled partial (CHG-007).
    function _analyse(address who, Pre memory c) internal {
        uint256 burned = c.balance - token.balanceOf(who);
        (int256 lastFull, uint256 sumFull, uint256[] memory touched, uint256 nTouched) = _fulls(c);
        if (sumFull > burned) ++i5Violations; // burned less than the positions it closed
        uint256 d = burned - Math.min(sumFull, burned);
        uint256 visits = uint256(lastFull + 1);
        for (uint256 k; k < visits; ++k) {
            if (v.positions(c.order[k]).status != VaultManager.Status.ClosedByRedemption && !c.below[k]) {
                ++skipViolations; // a visit before the last that was neither redeemed nor below MCR
            }
        }
        if (d > 0) {
            uint256 k = visits;
            while (k < c.order.length && c.below[k]) ++k;
            if (k == c.order.length) {
                ++partialOrderViolations; // stablecoin burned that no visited node accounts for
            } else {
                visits = k + 1;
                touched[nTouched++] = c.order[k];
                ++gX;
                _placed(c.order[k]);
                uint256 debtNow = v.debtOf(c.order[k]);
                (uint256 coll,) = v.effective(c.order[k]);
                if (debtNow < MIN_DEBT || coll * price < MCR * debtNow) ++i5Violations;
            }
        } else if (burned < c.amount) {
            for (uint256 k = visits; k < c.order.length; ++k) {
                ++visits;
                if (c.below[k]) continue;
                _checkLastVisit(c, c.order[k], c.amount - burned);
                break;
            }
        }
        _noOtherChange(c, touched, nTouched);
        if (eventsAvailable) _crossCheck(c, visits, touched, nTouched);
    }

    /// @dev The full redemptions: closed nodes, in visit order; also counted for I2 (Y each).
    function _fulls(Pre memory c)
        internal
        returns (int256 lastFull, uint256 sumFull, uint256[] memory touched, uint256 nTouched)
    {
        lastFull = -1;
        touched = new uint256[](c.order.length);
        for (uint256 k; k < c.order.length; ++k) {
            if (v.positions(c.order[k]).status != VaultManager.Status.ClosedByRedemption) continue;
            if (c.below[k]) ++skipViolations; // a node below MCR must be skipped, never redeemed
            lastFull = int256(k);
            sumFull += c.debt[k];
            touched[nTouched++] = c.order[k];
            ++gY;
            _forget(c.order[k]);
        }
    }

    /// @dev No member other than the ones redeemed from may have changed, anywhere in the list.
    function _noOtherChange(Pre memory c, uint256[] memory touched, uint256 nTouched) internal {
        for (uint256 k; k < c.allIds.length; ++k) {
            bool isTouched;
            for (uint256 j; j < nTouched; ++j) {
                if (touched[j] == c.allIds[k]) isTouched = true;
            }
            if (!isTouched && _stateHash(c.allIds[k]) != c.allState[k]) ++partialOrderViolations;
        }
    }

    function _stateHash(uint256 id) internal view returns (bytes32) {
        VaultManager.Position memory p = v.positions(id);
        return keccak256(abi.encode(p.status, p.coll, p.normDebt, p.stake, p.snapLColl, p.snapLDebt));
    }

    /// @dev I5 (CHG-007): an untouched last visit at or above MCR needs a legitimate reason.
    function _checkLastVisit(Pre memory c, uint256 id, uint256 remaining) internal {
        uint256 fee = _feeRateOfLastCall(c);
        RedemptionLastVisit.Reason r = RedemptionLastVisit.classify(
            v, sorted, RedemptionLastVisit.Visit(id, remaining, fee, price, c.up, c.lo)
        );
        if (r == RedemptionLastVisit.Reason.None) ++lastVisitWithoutReason;
        else ++ok[keccak256(abi.encode("cancel", uint8(r)))];
    }

    /// @dev The fee rate the call charged, recomputed from the module's state after the call: the
    ///      stored base rate is decayed + increment(redeemed, S0) and the fee used the requested amount
    ///      with the same decayed rate and S0 (§6.7.2). S0 = supply after the call + redeemed.
    function _feeRateOfLastCall(Pre memory c) internal view returns (uint256) {
        uint256 burned = c.balance - token.balanceOf(_lastRedeemer);
        uint256 s0 = token.totalSupply() + burned;
        uint256 incRedeemed = Math.mulDiv(burned, WAD, s0 * BETA, Math.Rounding.Ceil);
        uint256 incRequested = Math.mulDiv(c.amount, WAD, s0 * BETA, Math.Rounding.Ceil);
        uint256 stored = rm.baseRate();
        // stored = min(decayed + incRedeemed, WAD): decayed is recoverable unless capped at WAD
        uint256 decayed = stored >= WAD ? WAD : stored - incRedeemed;
        return Math.min(FEE_FLOOR + Math.min(decayed + incRequested, WAD), WAD);
    }

    address internal _lastRedeemer;

    // ================================================================== bookkeeping

    /// @dev Logs are recorded from the start of every action, so every event an action causes —
    ///      including accruals inside redistribute or triggerShutdown — is counted.
    function _begin() internal {
        ++calls;
        _applyOracleMode(); // time may have moved outside the handler (Medusa advances blocks itself)
        if (eventsAvailable) vm.recordLogs();
    }

    /// @dev After every action: I2's accrual counter from state, I13's exactness, the regime count
    ///      and the tolerance the current list needs.
    function _end() internal {
        if (v.lastAccrual() != _lastAccrualSeen) {
            ++gN;
            _lastAccrualSeen = v.lastAccrual();
        }
        if (eventsAvailable) _countEvents();
        _refreshExactness();
        if (nonExact != 0) ++stepsNonExact;
        else if (sorted.getSize() >= 2) ++stepsAllExact; // an exact order needs a pair to order
        // measurements for docs/fuzzing.md only: Foundry runs them; Medusa skips them, since their
        // per-pair external calls would push long lists past its 12.5M transaction gas limit and the
        // dropped calls would cut its reach (the checks themselves run in both)
        if (eventsAvailable) {
            _measureK();
            _measureSlack();
        }
    }

    /// @dev Records the largest relative slack the derived bound grants and the smallest stake, for
    ///      docs/fuzzing.md (the check itself is checkI13).
    function _measureSlack() internal {
        uint256 a = sorted.getFirst();
        if (a == 0) return;
        for (uint256 b = sorted.getNext(a); b != 0; (a, b) = (b, sorted.getNext(b))) {
            (uint256 cA, uint256 nA) = v.sortKey(a);
            (uint256 cB, uint256 nB) = v.sortKey(b);
            _slack(a, cA, nA);
            _slack(b, cB, nB);
            _pairTolerances(a, b, cA, nA, cB, nB);
        }
    }

    /// @dev The tolerance each bound grants this pair on the observed keys, relative to the key.
    ///      Hidden-key (CHG-009): h_obs,A − h_obs,B ≤ (d_A − d_B) + ι_A + ι_B with d = h_obs − h,
    /// over
    ///      h_obs,B + LDebt. CHG-008: kc_A/c_A + kn_B/n_B (its cross-product form, to first order).
    function _pairTolerances(uint256 a, uint256 b, uint256 cA, uint256 nA, uint256 cB, uint256 nB) internal {
        (uint256 l, uint256 ld) = (v.LColl(), v.LDebt());
        int256 tol = I13HiddenKeys.ceilDiff(I13HiddenKeys.hObs(cA, nA, l, ld), hOf[a])
            + I13HiddenKeys.ceilDiff(hOf[b], I13HiddenKeys.hObs(cB, nB, l, ld)) + iotaOf[a] + iotaOf[b];
        if (tol > 0) {
            uint256 rel = Math.mulDiv(
                uint256(tol), 1e18, Math.max(1, Math.mulDiv(nB, 1e18 + l, cB)), Math.Rounding.Ceil
            );
            if (rel > maxPairTolRelE18) maxPairTolRelE18 = rel;
        }
        uint256 old = Math.mulDiv(_kColl(a), 1e18, cA, Math.Rounding.Ceil)
            + Math.mulDiv(_kNorm(b), 1e18, nB, Math.Rounding.Ceil);
        if (old > maxChg008PairRelE18) maxChg008PairRelE18 = old;
    }

    function _slack(uint256 id, uint256 c, uint256 n) internal {
        uint256 rel = Math.max(Math.mulDiv(_kColl(id), 1e18, c), Math.mulDiv(_kNorm(id), 1e18, n));
        if (rel > maxRelativeSlackE18) maxRelativeSlackE18 = rel;
        uint256 st = v.positions(id).stake;
        if (st < minMemberStake) minMemberStake = st;
    }

    function _kColl(uint256 id) internal view returns (uint256) {
        VaultManager.Position memory p = v.positions(id);
        uint256 m = redistributions - redistAtPlacement[id];
        return 1 + Math.mulDiv(v.LColl() - p.snapLColl + m + p.stake * m, 1, 1e18, Math.Rounding.Ceil);
    }

    function _kNorm(uint256 id) internal view returns (uint256) {
        VaultManager.Position memory p = v.positions(id);
        uint256 m = redistributions - redistAtPlacement[id];
        return 1 + Math.mulDiv(v.LDebt() - p.snapLDebt + m + p.stake * m, 1, 1e18, Math.Rounding.Ceil);
    }

    uint256 internal _lastAccrualSeen = START;

    /// @dev Foundry records the events of a call that later reverted; they never happened, so a
    ///      failed protocol call drops what was recorded in this action (only persisted events count).
    function _discardLogs() internal {
        if (eventsAvailable) vm.getRecordedLogs();
    }

    function _countEvents() internal {
        _countLogs(vm.getRecordedLogs());
    }

    function _countLogs(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(v)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.InterestAccrued.selector) {
                ++eN;
            } else if (t == VaultManager.PositionUpdated.selector) {
                (,,,,,, uint8 op) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint8));
                if (op == 1 || op == 4 || op == 5) ++eX;
                else if (op == 6) ++eY;
            } else if (t == VaultManager.PositionRedeemed.selector) {
                (,,, bool closed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                if (closed) ++eY;
                else ++eX;
            } else if (t == VaultManagerHarness.HarnessRedistributed.selector) {
                ++eRedistributions;
            }
        }
    }

    /// @dev Foundry only: the state reconstruction must agree with what the contracts emitted —
    ///      the visit count with `Redeemed.iterations`, the recomputed fee rate with `Redeemed.feeRate`,
    ///      and the touched positions with the `PositionRedeemed` ids. The logs are consumed here and
    ///      counted for I2 as `_end` would have.
    function _crossCheck(Pre memory c, uint256 visits, uint256[] memory touched, uint256 nTouched) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _countLogs(logs);
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.PositionRedeemed.selector) {
                if (seen >= nTouched || uint256(logs[i].topics[1]) != touched[seen]) ++eventMismatches;
                ++seen;
            } else if (t == RedemptionModule.Redeemed.selector) {
                (,,, uint256 feeRate, uint256 iterations,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                if (iterations != visits) ++eventMismatches;
                if (feeRate != _feeRateOfLastCall(c)) ++eventMismatches;
            }
        }
        if (seen != nTouched) ++eventMismatches;
    }

    function _unexpected(bytes4 sel, string memory action) internal {
        ++unexpectedReverts;
        lastUnexpected = sel;
        lastUnexpectedAction = action;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev An active position chosen by seed among ids 1 … nextId − 1 (0 if none is active).
    function _pick(uint256 seed) internal view returns (uint256) {
        uint256 count = v.nextId() - 1;
        if (count == 0) return 0;
        uint256 start = seed % count;
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (start + i) % count;
            if (v.positions(id).status == VaultManager.Status.Active) return id;
        }
        return 0;
    }

    /// @dev Exact hints for `id`'s new key, found on the list without `id` (§6.3.2).
    function _slot(uint256 id, uint256 c, uint256 n)
        internal
        view
        returns (bool found, uint256 up, uint256 lo)
    {
        (uint256 approx,,) = hints.getApproxHint(c, n, 10, c ^ n);
        if (approx == id) approx = sorted.getPrev(id); // `find` excludes the node itself
        (found, up, lo) = sorted.find(c, n, id, id, approx, approx);
        if (!found) (found, up, lo) = sorted.find(c, n, id, id, sorted.getPrev(id), sorted.getNext(id));
    }

    /// @dev Moves stablecoin from the other actors to `to` until it holds `amount` (if they can).
    function _topUp(address to, uint256 amount) internal {
        for (uint256 i; i < actors.length && token.balanceOf(to) < amount; ++i) {
            address from = actors[i];
            if (from == to) continue;
            uint256 give = Math.min(token.balanceOf(from), amount - token.balanceOf(to));
            if (give == 0) continue;
            vm.prank(from);
            token.transfer(to, give);
        }
    }

    // ------------------------------------------------------------------ oracle modes

    function _oracleUnusable() internal view returns (bool) {
        return oracleMode != 0;
    }

    function _applyOracleMode() internal {
        feed.setMode(MockAggregator.Mode.Normal);
        seq.setMode(MockAggregator.Mode.Normal);
        seq.setStatus(0, seqStart);
        feed.setRound(1, int256(price / 1e10), block.timestamp);
        uint256 m = oracleMode;
        if (m == 1) seq.setMode(MockAggregator.Mode.Revert); // SEQUENCER_CALL_FAILED
        else if (m == 2) seq.setStatus(1, seqStart); // SEQUENCER_DOWN
        else if (m == 3) seq.setStatus(0, 0); // SEQUENCER_INVALID
        else if (m == 4) seq.setStatus(0, block.timestamp - 1); // GRACE_PERIOD
        else if (m == 5) feed.setMode(MockAggregator.Mode.Revert); // PRICE_CALL_FAILED
        else if (m == 6) feed.setAnswer(0); // NON_POSITIVE
        else if (m == 7) feed.setUpdatedAt(0); // INVALID_TIMESTAMP
        else if (m == 8) feed.setUpdatedAt(block.timestamp - STALENESS - 1); // STALE
        else if (m == 9) feed.setAnswer(int256(MAX_PRICE / 1e10) + 1); // OUT_OF_BOUNDS
        (, bool usable, OracleAdapter.Reason r) = oracle.peek();
        if (usable != (m == 0) || uint256(r) != m) ++oracleModeMismatches;
    }

    // ------------------------------------------------------------------ I13 exactness (CHG-005)

    function _placed(uint256 id) internal {
        if (!exact[id] && keyColl[id] != 0) --nonExact; // it was a non-exact member
        exact[id] = false;
        (keyColl[id], keyNorm[id]) = v.sortKey(id);
        redistAtPlacement[id] = redistributions;
        _placeHidden(id);
        bool clean = nonExact == 0;
        exact[id] = clean;
        if (!clean) ++nonExact;
    }

    /// @dev CHG-009: the member's h (constant while it stays in the list) and its ι, the most its
    ///      place can sit off the hidden order given its neighbours' deviation now. Also checks that
    ///      the insertion is exact against the neighbours' keys (§6.3.1 `precedes`).
    function _placeHidden(uint256 id) internal {
        VaultManager.Position memory p = v.positions(id);
        hOf[id] = I13HiddenKeys.h(p.coll, p.normDebt, p.snapLColl, p.snapLDebt);
        uint256 prev = sorted.getPrev(id);
        uint256 nxt = sorted.getNext(id);
        iotaOf[id] = I13HiddenKeys.iota(_hiddenSide(prev), _hiddenSide(nxt));
        if (iotaOf[id] > 0) {
            ++insertionsWithIota;
            uint256 rel = Math.mulDiv(SafeCast.toUint256(iotaOf[id]), 1e18, _hScale(id), Math.Rounding.Ceil);
            if (rel > maxIotaRelE18) maxIotaRelE18 = rel;
        }
        if (prev != 0 && !_precedes(prev, id)) ++insertionViolations;
        if (nxt != 0 && !_precedes(id, nxt)) ++insertionViolations;
        // §6.5.4: every insertion recomputes the stake from the current snapshots (R10, down). The
        // hidden-key bound holds whatever the stakes, so a wrong stake is checked here, exactly.
        (uint256 S, uint256 C) = (v.totalStakesSnapshot(), v.totalCollateralSnapshot());
        if (p.stake != (S == 0 || C == 0 ? p.coll : Math.mulDiv(p.coll, S, C))) ++insertionViolations;
    }

    function _hiddenSide(uint256 id) internal view returns (I13HiddenKeys.Side memory s) {
        if (id == 0) return s;
        (uint256 c, uint256 n) = v.sortKey(id);
        s.obs = I13HiddenKeys.hObs(c, n, v.LColl(), v.LDebt());
        (s.h, s.iota, s.present) = (hOf[id], iotaOf[id], true);
    }

    /// @dev h + LDebt = DP · (hidden normalised debt per unit of ideal stake), the key's own scale:
    ///      a relative change in it is a relative change in the hidden NICR. Floor, at least 1.
    function _hScale(uint256 id) internal view returns (uint256) {
        I13HiddenKeys.Rat memory r = hOf[id];
        return Math.max(1, Math.mulDiv(r.x, r.y, r.den) + v.LDebt() - r.off);
    }

    function _precedes(uint256 a, uint256 b) internal view returns (bool) {
        (uint256 cA, uint256 nA) = v.sortKey(a);
        (uint256 cB, uint256 nB) = v.sortKey(b);
        return cA * nB > cB * nA || (cA * nB == cB * nA && a < b);
    }

    function _forget(uint256 id) internal {
        if (keyColl[id] == 0) return;
        if (!exact[id]) --nonExact;
        exact[id] = false;
        (keyColl[id], keyNorm[id]) = (0, 0);
    }

    /// @dev A member whose key changed without a reinsert (redistribution) stops being exact.
    function _refreshExactness() internal {
        for (uint256 id = sorted.getFirst(); id != 0; id = sorted.getNext(id)) {
            if (!exact[id]) continue;
            (uint256 c, uint256 n) = v.sortKey(id);
            if (c != keyColl[id] || n != keyNorm[id]) {
                exact[id] = false;
                ++nonExact;
            }
        }
    }

    /// @dev The smallest k with cA·nB + k(cA + nB) + k² ≥ cB·nA over the current list, maximised.
    function _measureK() internal {
        uint256 a = sorted.getFirst();
        if (a == 0) return;
        for (uint256 b = sorted.getNext(a); b != 0; (a, b) = (b, sorted.getNext(b))) {
            (uint256 cA, uint256 nA) = v.sortKey(a);
            (uint256 cB, uint256 nB) = v.sortKey(b);
            if (cA * nB >= cB * nA) continue;
            // the smallest k with k² + k·(cA + nB) ≥ deficit: the positive root, rounded up
            uint256 deficit = cB * nA - cA * nB;
            uint256 s = cA + nB;
            uint256 k = (Math.sqrt(s * s + 4 * deficit) - s) / 2;
            while (k * s + k * k < deficit) ++k; // at most one or two steps after the root
            if (k > maxNeededK) maxNeededK = k;
        }
    }

    // ================================================================== checks (Foundry + Medusa)

    function checkI1Holders() public view returns (bool, string memory) {
        uint256 bal = weth.balanceOf(address(v));
        uint256 want = v.settled()
            ? v.activeCount() * GAS_RESERVE + donatedWeth[address(v)]
            : v.totalCollateral() + v.pendingColl() + v.activeCount() * GAS_RESERVE + donatedWeth[address(v)];
        if (bal != want) return (false, "I1: VaultManager WETH");
        if (weth.balanceOf(address(rm)) != donatedWeth[address(rm)]) {
            return (false, "I1: RedemptionModule WETH");
        }
        if (token.balanceOf(address(rm)) != donatedToken[address(rm)]) {
            return (false, "I1: RedemptionModule token");
        }
        return (true, "");
    }

    /// @dev Deployment A's pool (P19): I1 (pool row, no donations to the pool in this handler), I3's
    ///      exact inequalities over the actors (the only depositors), the `P` range, the empty-epoch
    ///      clause (the mock ledger never settles), withdraw entitlement, and U4.
    function checkPool() public view returns (bool, string memory) {
        if (variantB) return (true, "");
        if (weth.balanceOf(address(pool)) != pool.collGainsBalance()) return (false, "I1: pool WETH");
        uint256 bal = token.balanceOf(address(pool));
        if (bal != pool.totalDeposits() + pool.interestGainsBalance()) return (false, "I1: pool stablecoin");
        (uint256 compounded, uint256 collGains, uint256 interestGains) = (0, 0, 0);
        for (uint256 i; i < 5; ++i) {
            compounded += pool.compoundedDeposit(actors[i]);
            (uint256 c, uint256 g) = pool.gains(actors[i]);
            (collGains, interestGains) = (collGains + c, interestGains + g);
        }
        if (compounded > pool.totalDeposits()) return (false, "I3: sum of compounded > totalDeposits");
        if (collGains > pool.collGainsBalance()) return (false, "I3: collateral gains > balance");
        if (interestGains > pool.interestGainsBalance()) return (false, "I3: interest gains > balance");
        if (pool.P() < pool.P_MIN() || pool.P() > pool.P_PRECISION()) return (false, "I3: P out of range");
        if (pool.depositorCount(pool.currentEpoch()) == 0 && pool.totalDeposits() != 0) {
            return (false, "I3: empty current epoch holds deposits");
        }
        if (poolEntitlementViolations != 0) return (false, "I3: withdraw entitlement");
        if (compounded + pool.interestGainsBalance() > bal) return (false, "U4: deposits not covered");
        return (true, "");
    }

    function checkI1Sums() public view returns (bool, string memory) {
        if (v.settled()) return (true, ""); // the supporting identities stop at settlement (I1)
        (uint256 stakes, uint256 norm, uint256 coll, uint256 active) = (0, 0, 0, 0);
        for (uint256 id = 1; id < v.nextId(); ++id) {
            VaultManager.Position memory p = v.positions(id);
            if (p.status != VaultManager.Status.Active) continue;
            (stakes, norm, coll, active) = (stakes + p.stake, norm + p.normDebt, coll + p.coll, active + 1);
        }
        if (stakes != v.totalStakes()) return (false, "I1: totalStakes = sum of stakes");
        if (norm + v.pendingNormDebt() != v.totalNormDebt()) return (false, "I1: totalNormDebt");
        if (coll != v.totalCollateral()) return (false, "I1: totalCollateral");
        if (active != v.activeCount() || active != sorted.getSize()) {
            return (false, "I1: activeCount = list size");
        }
        return (true, "");
    }

    /// @dev §10.2: −N·RAY ≤ E ≤ X·I + Y·RAY, strict once the counter is ≥ 1. Not defined after
    ///      settlement. A and F are read from the ledger.
    function checkI2() public view returns (bool, string memory) {
        if (v.settled()) return (true, "");
        uint256 I = v.index();
        uint256 lhs = v.totalNormDebt() * I;
        uint256 rhs = (token.totalSupply() - ledger.auctionDebt() - ledger.deficit()) * RAY;
        if (lhs >= rhs) {
            uint256 e = lhs - rhs;
            if (gX + gY == 0 ? e != 0 : e >= gX * I + gY * RAY) return (false, "I2 upper");
        } else {
            uint256 e = rhs - lhs;
            if (gN == 0 ? e != 0 : e >= gN * RAY) return (false, "I2 lower");
        }
        return (true, "");
    }

    function checkEventsAgree() public view returns (bool, string memory) {
        if (!eventsAvailable) return (true, "");
        if (eN != gN || eX != gX || eY != gY) return (false, "I2 counters: state reconstruction != events");
        if (eRedistributions != redistributions) return (false, "I13 m: redistribution count != events");
        if (eventMismatches != 0) return (false, "I5 reconstruction != events");
        return (true, "");
    }

    function checkI5() public view returns (bool, string memory) {
        if (i5Violations != 0) return (false, "I5: a redeemed position left below MIN_DEBT or MCR");
        if (partialOrderViolations != 0) return (false, "I5: more than one partial, or not the last");
        if (skipViolations != 0) return (false, "I5: a visit before the last was not below MCR");
        if (lastVisitWithoutReason != 0) {
            return (false, "I5: the last visit stopped without a legitimate reason");
        }
        return (true, "");
    }

    /// @dev §10.3, the parts that exist before P19: Σ_active pending ≤ the pending buckets.
    function checkI8() public view returns (bool, string memory) {
        if (v.settled()) return (true, "");
        (uint256 pc, uint256 pn) = (0, 0);
        for (uint256 id = 1; id < v.nextId(); ++id) {
            VaultManager.Position memory p = v.positions(id);
            if (p.status != VaultManager.Status.Active) continue;
            (uint256 c, uint256 n) = v.effective(id);
            (pc, pn) = (pc + c - p.coll, pn + n - p.normDebt);
        }
        if (pc > v.pendingColl()) return (false, "I8: sum of pending collateral > pendingColl");
        if (pn > v.pendingNormDebt()) return (false, "I8: sum of pending debt > pendingNormDebt");
        return (true, "");
    }

    function checkI9() public view returns (bool, string memory) {
        return i9Violations == 0 ? (true, "") : (false, "I9: a rescue path failed or read the oracle");
    }

    function checkI11() public view returns (bool, string memory) {
        return _paramsHash() == paramsHash ? (true, "") : (false, "I11: a parameter or wired address changed");
    }

    function checkI12() public view returns (bool, string memory) {
        if (oracleModeMismatches != 0) {
            return (false, "I12 harness: an oracle mode did not produce its reason");
        }
        return
            i12Violations == 0
                ? (true, "")
                : (false, "I12: a price-required operation ran on an unusable price");
    }

    /// @dev I13: exact order while every member is exact (CHG-005). In every regime: the key identity,
    ///      exact insertions (neighbours and stake) and the hidden-key pair condition (CHG-009, applied
    ///      2026-10-26). CHG-008's per-member bound is superseded and no longer asserted —
    ///      `I13BoundCounterexampleTest` shows a correct VaultManager can break it; it is still measured
    ///      on the same pairs for docs/fuzzing.md's comparison (`maxChg008PairRelE18`).
    function checkI13() public view returns (bool, string memory) {
        if (insertionViolations != 0) {
            return (false, "I13: an insertion was not exact (neighbours' keys or the stake of 6.5.4)");
        }
        uint256 a = sorted.getFirst();
        if (a == 0) return (true, "");
        if (!_keyIsSpec(a)) return (false, "I13: sortKey differs from the spec formula");
        bool exactRegime = nonExact == 0;
        for (uint256 b = sorted.getNext(a); b != 0; (a, b) = (b, sorted.getNext(b))) {
            if (!_keyIsSpec(b)) return (false, "I13: sortKey differs from the spec formula");
            if (!I13HiddenKeys.pairHolds(hOf[a], iotaOf[a], hOf[b], iotaOf[b])) {
                return (false, "I13: order beyond the hidden-key bound (CHG-009)");
            }
            (uint256 cA, uint256 nA) = v.sortKey(a);
            (uint256 cB, uint256 nB) = v.sortKey(b);
            if (exactRegime && !(cA * nB > cB * nA || (cA * nB == cB * nA && a < b))) {
                return (false, "I13: exact order");
            }
        }
        return (true, "");
    }

    /// @dev §5.1.12 / §6.5.3: the effective key is the stored value plus the floored pending reward.
    function _keyIsSpec(uint256 id) internal view returns (bool) {
        VaultManager.Position memory p = v.positions(id);
        (uint256 c, uint256 n) = v.sortKey(id);
        return c == p.coll + Math.mulDiv(p.stake, v.LColl() - p.snapLColl, 1e18)
            && n == p.normDebt + Math.mulDiv(p.stake, v.LDebt() - p.snapLDebt, 1e18);
    }

    function checkNoUnexpectedReverts() public view returns (bool, string memory) {
        return unexpectedReverts == 0 ? (true, "") : (false, "unexpected revert");
    }

    function _paramsHash() internal view returns (bytes32) {
        bytes memory a = abi.encode(
            v.MCR(),
            v.MIN_DEBT(),
            v.GAS_RESERVE(),
            v.RATE_PER_SECOND(),
            v.POOL_SHARE_BPS(),
            address(v.WETH()),
            address(v.token()),
            address(v.oracle()),
            address(v.sorted()),
            v.strategy(),
            v.stabilityPool(),
            v.redemptionModule()
        );
        bytes memory b = abi.encode(
            v.deficitLedger(),
            v.shutdownModule(),
            address(rm.token()),
            address(rm.oracle()),
            rm.REDEMPTION_FEE_FLOOR(),
            rm.BETA(),
            rm.BASE_RATE_DECAY(),
            address(rm.vaultManager()),
            address(rm.shutdownModule()),
            rm.auctionHouse()
        );
        bytes memory c = abi.encode(
            sorted.MAX_HINT_STEPS(),
            address(sorted.vaultManager()),
            token.vaultManager(),
            token.strategy(),
            token.deficitLedger(),
            token.shutdownModule(),
            oracle.priceFeed(),
            oracle.sequencerFeed(),
            oracle.STALENESS(),
            oracle.GRACE_PERIOD(),
            oracle.MIN_PRICE(),
            oracle.MAX_PRICE()
        );
        return keccak256(
            abi.encode(a, b, c, oracle.ORACLE_GAS(), oracle.ORACLE_POST_FAILURE_GAS(), oracle.FEED_DECIMALS())
        );
    }
}
