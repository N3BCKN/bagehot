// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StableToken} from "../../../src/core/StableToken.sol";
import {InsufficientBalance, ZeroAmount} from "../../../src/lib/Errors.sol";
import {StabilityPool} from "../../../src/liquidation/StabilityPool.sol";
import {DeficitLedger} from "../../../src/safety/DeficitLedger.sol";
import {PoolTestVault, StabilityPoolHarness} from "../../utils/PoolMocks.sol";
import {MockWETH} from "../../utils/VaultMocks.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Drives the real StabilityPool behind the test VaultManager (P19): deposits, withdrawals
///         (partial and `type(uint256).max`), claims, offsets (random, exactly `T`, `T − 1`, near-
///         emptying), interest, liquidations through `onLiquidation`, and donations. The real
///         `liquidate` arrives at P20; until then offsets come from the test VaultManager, within
///         §6.6.3's `c ≤ 0.75·d + 1`. Every protocol call is caught and classified.
contract StabilityPoolHandler is CommonBase, StdUtils {
    uint256 internal constant MIN_DEPOSIT = 1e18;
    uint256 internal constant PENALTY = 0.05e18;
    uint256 internal constant MIN_PRICE = 10e18;

    MockWETH public weth;
    StableToken public token;
    PoolTestVault public tv;
    StabilityPoolHarness public pool;
    DeficitLedger public ledger;
    address[5] public actors;

    // ghosts
    uint256 public donatedWeth;
    uint256 public donatedToken;
    uint256 public entitlementViolations; // withdraw paid something other than min(x, compounded)
    uint256 public unexpectedReverts;
    bytes4 public lastUnexpected;
    uint256 public epochChanges;
    uint256 public scaleChanges;
    uint256 public sweeps;
    mapping(bytes32 => uint256) public ok;

    constructor(address[5] memory actors_) {
        actors = actors_;
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        tv = new PoolTestVault(weth, token);
        pool = new StabilityPoolHarness(address(weth), address(token), PENALTY, MIN_DEPOSIT);
        ledger = new DeficitLedger(address(weth), address(token));
        tv.setPool(pool);
        token.wire(address(tv), address(pool), address(ledger), address(0x5D));
        pool.wire(address(tv), address(ledger));
        ledger.wire(address(tv), address(pool), address(0), address(pool), address(0x5D));
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint256 who, uint256 amount, uint256 sizeMode) external {
        address a = actors[who % 5];
        // sizes from below the minimum to 1e30, so DepositTooSmall and large pools both occur
        uint256[4] memory caps = [uint256(2e18), 1e21, 1e27, 1e30];
        amount = bound(amount, 1, caps[sizeMode % 4]);
        if (token.balanceOf(a) < amount) tv.mintTo(a, amount);
        vm.prank(a);
        try pool.deposit(amount) {
            ++ok["deposit"];
        } catch (bytes memory err) {
            _expect(err, StabilityPool.DepositTooSmall.selector, InsufficientBalance.selector);
        }
    }

    function withdraw(uint256 who, uint256 amount, bool all) external {
        address a = actors[who % 5];
        (uint256 initial,,,,,) = pool.deposits(a);
        if (initial == 0) return;
        uint256 x = all ? type(uint256).max : bound(amount, 1, 2 * initial);
        uint256 compounded = pool.compoundedDeposit(a);
        (, uint256 interestGain) = pool.gains(a);
        uint256 before = token.balanceOf(a);
        uint256 reserveBefore = ledger.reserve();
        vm.prank(a);
        try pool.withdraw(x) {
            ++ok["withdraw"];
            uint256 want = x < compounded ? x : compounded;
            if (token.balanceOf(a) - before != want + interestGain) ++entitlementViolations;
            if (ledger.reserve() > reserveBefore) ++sweeps; // PoolDustSwept: the residual reached the ledger
        } catch (bytes memory err) {
            _expect(err, StabilityPool.DepositTooSmall.selector, ZeroAmount.selector);
        }
    }

    /// @notice Every actor withdraws everything in turn — I3's targeted sequence "two depositors, one
    ///         offset, both withdraw": the last current-epoch leaver sweeps the rounding residual.
    function exitAll() external {
        for (uint256 i; i < 5; ++i) {
            address a = actors[i];
            (uint256 initial,,,,,) = pool.deposits(a);
            if (initial == 0) continue;
            uint256 compounded = pool.compoundedDeposit(a);
            (, uint256 interestGain) = pool.gains(a);
            uint256 before = token.balanceOf(a);
            uint256 reserveBefore = ledger.reserve();
            vm.prank(a);
            try pool.withdraw(type(uint256).max) {
                ++ok["withdraw"];
                if (token.balanceOf(a) - before != compounded + interestGain) ++entitlementViolations;
                if (ledger.reserve() > reserveBefore) ++sweeps;
            } catch (bytes memory err) {
                _unexpected(err);
            }
        }
    }

    function claim(uint256 who) external {
        address a = actors[who % 5];
        (uint256 initial,,,,,) = pool.deposits(a);
        if (initial == 0) return;
        vm.prank(a);
        try pool.claimGains() {
            ++ok["claim"];
        } catch (bytes memory err) {
            _unexpected(err);
        }
    }

    /// @dev mode 0: random d; 1: d = T (epoch change); 2: d = T − 1 (scale change pressure);
    ///      3: d leaves T/1e10.
    function offset(uint256 dSeed, uint256 cSeed, uint256 mode) external {
        uint256 t = pool.totalDeposits();
        if (t == 0) return;
        uint256 d;
        mode %= 4;
        if (mode == 1) d = t;
        else if (mode == 2) d = t > 1 ? t - 1 : t;
        else if (mode == 3) d = t - t / 1e10;
        else d = bound(dSeed, 1, t);
        if (d == 0) return;
        uint256 c = bound(cSeed, 0, d * 3 / 4 + 1); // §6.6.3: c ≤ 0.75·d + 1
        (uint256 e0, uint256 s0) = (pool.currentEpoch(), pool.currentScale());
        try tv.offset(d, c) {
            ++ok["offset"];
            if (pool.currentEpoch() != e0) ++epochChanges;
            else if (pool.currentScale() != s0) ++scaleChanges;
        } catch (bytes memory err) {
            _unexpected(err);
        }
    }

    function interest(uint256 g) external {
        g = bound(g, 0, 1e24);
        try tv.interest(g) {
            ++ok["interest"];
        } catch (bytes memory err) {
            _unexpected(err);
        }
    }

    function liquidate(uint256 debt, uint256 coll, uint256 price) external {
        debt = bound(debt, 1, 1e27);
        price = bound(price, MIN_PRICE, 1e24);
        coll = bound(coll, 1, 2 * debt * 1e18 / price + 1);
        try tv.liquidate(1, address(0x0E), debt, coll, price) {
            ++ok["liquidate"];
        } catch (bytes memory err) {
            _unexpected(err);
        }
    }

    /// @dev Donations are inert (I1's D_w / D_t).
    function donate(uint256 w, uint256 t) external {
        w = bound(w, 0, 1e20);
        t = bound(t, 0, 1e20);
        weth.mint(address(pool), w);
        tv.mintTo(address(pool), t);
        donatedWeth += w;
        donatedToken += t;
    }

    // ------------------------------------------------------------------ classification

    function _expect(bytes memory err, bytes4 a, bytes4 b) internal {
        bytes4 sel = bytes4(err);
        if (sel != a && sel != b) _unexpected(err);
    }

    function _unexpected(bytes memory err) internal {
        ++unexpectedReverts;
        lastUnexpected = bytes4(err);
    }

    // ------------------------------------------------------------------ views for the invariants

    function actorCount() external pure returns (uint256) {
        return 5;
    }
}
