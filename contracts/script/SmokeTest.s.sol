// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../src/core/VaultManager.sol";
import {BagehotFactory} from "../src/deploy/BagehotFactory.sol";
import {IDeficitLedgerViews} from "../src/interfaces/ISystemViews.sol";
import {StabilityPool} from "../src/liquidation/StabilityPool.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {StandInDeficitLedger} from "../src/mocks/StandInDeficitLedger.sol";
import {RedemptionModule} from "../src/redemption/RedemptionModule.sol";
import {Blueprints} from "./Blueprints.sol";
import {ConfigLoader, DeployConfig} from "./Config.s.sol";
import {DeploymentChecks} from "./DeploymentChecks.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Post-deploy smoke test, read from `deployments/<chainId>.json` (the variant's key). It
///         re-runs every deployment assertion of spec §3.3 against the live chain (ADR-0031), checks
///         the manifest against the factory, then — simulated, never broadcast — opens a position,
///         lets a day pass and accrues, redeems a little, and after each step checks the events and
///         view-based invariants: I1 (holder balances, list size), I2 (the step's drift within its
///         own bound, counters from the step's events), TCR. Everything is measured as a change
///         across the step, so prior activity on the chain or elapsed blocks do not matter.
contract SmokeTest is ConfigLoader {
    using stdJson for string;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint8 internal constant OP_OPEN = 1;
    uint8 internal constant OP_BORROW = 4;
    uint8 internal constant OP_REPAY = 5;
    uint8 internal constant OP_CLOSE = 6;

    error SmokeFailed(string what);

    /// @dev I2's counters for one step (invariants.md I2, counter rules).
    struct Counters {
        uint256 gN;
        uint256 gX;
        uint256 gY;
        uint256 redirected; // PoolInterestRedirected (CHG-006)
    }

    function manifestPath(uint256 chainId) public view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../deployments/", vm.toString(chainId), ".json");
    }

    /// @notice Smoke-tests the variant named in `config/<chainId>.toml`.
    function run() external {
        DeployConfig memory c = loadConfig(block.chainid);
        _runVariant(c.variantB ? "B" : "A");
    }

    /// @notice Smoke-tests variant "A" or "B".
    function runVariant(string calldata variant) external {
        _runVariant(variant);
    }

    function _runVariant(string memory variant) internal {
        (BagehotFactory f, DeployConfig memory c) = loadDeployment(manifestPath(block.chainid), variant);
        smoke(f, c, msg.sender);
    }

    /// @notice The deployment recorded under `variant` in the manifest at `path`, with every §3.3
    ///         assertion re-run on-chain. Off chain 31337 the feeds must equal `config/<chain>.toml`
    ///         (P11-1); on 31337 they are the mocks the deploy script created and recorded.
    function loadDeployment(string memory path, string memory variant)
        public
        view
        returns (BagehotFactory f, DeployConfig memory c)
    {
        string memory m = vm.readFile(path);
        string memory k = string.concat(".", variant);
        c = loadConfig(block.chainid);
        _req(m.readUint(string.concat(k, ".chainId")) == block.chainid, "manifest chainId");
        _req(
            keccak256(bytes(m.readString(string.concat(k, ".variant")))) == keccak256(bytes(variant)),
            "manifest variant"
        );
        if (keccak256(bytes(variant)) == keccak256("B")) {
            (c.variantB, c.poolShareBps) = (true, m.readUint(string.concat(k, ".params.POOL_SHARE_BPS")));
        } else {
            (c.variantB, c.poolShareBps) = (false, m.readUint(string.concat(k, ".params.POOL_SHARE_BPS")));
        }
        f = BagehotFactory(m.readAddress(string.concat(k, ".addresses.factory")));
        address weth = m.readAddress(string.concat(k, ".addresses.weth"));
        address feed = m.readAddress(string.concat(k, ".addresses.priceFeed"));
        address seq = m.readAddress(string.concat(k, ".addresses.sequencerFeed"));
        if (block.chainid == 31_337) {
            (c.weth, c.priceFeed, c.sequencerFeed) = (weth, feed, seq);
        } else {
            _req(
                weth == c.weth && feed == c.priceFeed && seq == c.sequencerFeed,
                "manifest feeds and WETH == config"
            );
        }
        _manifestMatchesFactory(m, k, f);
        _manifestBlueprints(m, k, c.variantB);
        _req(
            m.readUint(string.concat(k, ".block")) <= f.deployBlock(), "manifest block <= factory deployBlock"
        );
        DeploymentChecks.check(f, c);
    }

    /// @dev ADR-0035: every blueprint the manifest records holds today's build's code, under its hash.
    function _manifestBlueprints(string memory m, string memory k, bool variantB) internal view {
        string[9] memory n = Blueprints.names();
        bytes32[9] memory h = Blueprints.codehashes(variantB);
        for (uint256 i; i < 9; ++i) {
            string memory r = string.concat(k, ".blueprints.", n[i]);
            _req(
                m.readBytes32(string.concat(r, ".codehash")) == h[i],
                string.concat("manifest blueprint hash: ", n[i])
            );
            _req(
                m.readAddress(string.concat(r, ".address")).codehash == h[i],
                string.concat("blueprint holds today's code: ", n[i])
            );
        }
    }

    function _manifestMatchesFactory(string memory m, string memory k, BagehotFactory f) internal view {
        _req(m.readAddress(string.concat(k, ".addresses.token")) == address(f.token()), "manifest token");
        _req(m.readAddress(string.concat(k, ".addresses.oracle")) == address(f.oracle()), "manifest oracle");
        _req(
            m.readAddress(string.concat(k, ".addresses.vaultManager")) == address(f.vaultManager()),
            "manifest vaultManager"
        );
        _req(
            m.readAddress(string.concat(k, ".addresses.sortedPositions")) == address(f.sorted()),
            "manifest sortedPositions"
        );
        _req(
            m.readAddress(string.concat(k, ".addresses.redemptionModule")) == address(f.redemptionModule()),
            "manifest redemptionModule"
        );
        _req(
            m.readAddress(string.concat(k, ".addresses.hintHelpers")) == address(f.hintHelpers()),
            "manifest hintHelpers"
        );
        _req(m.readAddress(string.concat(k, ".addresses.strategy")) == f.strategy(), "manifest strategy");
        _req(
            m.readAddress(string.concat(k, ".addresses.deficitLedger")) == f.deficitLedger(),
            "manifest deficitLedger"
        );
        _req(
            m.readAddress(string.concat(k, ".addresses.shutdownModule")) == f.shutdownModule(),
            "manifest shutdownModule"
        );
    }

    /// @notice The functional smoke, as `who`. Uses the local mocks (mint, price rounds): chain 31337.
    function smoke(BagehotFactory f, DeployConfig memory c, address who) public {
        _req(block.chainid == 31_337, "functional smoke needs the local mocks (chain 31337)");
        VaultManager v = f.vaultManager();
        _checkViews(f, c);
        LocalWETH(c.weth).mint(who, 10 ether);
        vm.prank(who);
        LocalWETH(c.weth).approve(address(v), type(uint256).max);
        uint256 id = _open(f, c, who);
        if (!c.variantB) _poolDeposit(f, c, who);
        _accrue(f, c);
        _redeem(f, c, who, id);
        if (!c.variantB) _poolWithdraw(f, c, who);
    }

    /// @dev Deployment A (P19): deposit 1,000 into the StabilityPool, so the next accrual books the
    ///      pool's interest share through the guarded hook (§6.2).
    function _poolDeposit(BagehotFactory f, DeployConfig memory c, address who) internal {
        StabilityPool pool = StabilityPool(f.strategy());
        uint256 balance = f.token().balanceOf(who);
        vm.prank(who);
        pool.deposit(1000e18);
        _req(balance - f.token().balanceOf(who) == 1000e18, "pool deposit: 1,000 moved");
        _req(pool.compoundedDeposit(who) == 1000e18, "pool deposit: recorded");
        _req(pool.acceptsInterest(), "pool deposit: at or above MIN_DEPOSIT");
        _checkViews(f, c);
    }

    /// @dev Deployment A: withdraw everything; the deposit comes back with its interest gain.
    function _poolWithdraw(BagehotFactory f, DeployConfig memory c, address who) internal {
        StabilityPool pool = StabilityPool(f.strategy());
        (, uint256 interestGain) = pool.gains(who);
        _req(interestGain > 0, "pool: the accrual booked an interest gain");
        uint256 balance = f.token().balanceOf(who);
        vm.prank(who);
        pool.withdraw(type(uint256).max);
        _req(
            f.token().balanceOf(who) - balance >= 1000e18 + interestGain,
            "pool withdraw: deposit and interest gain paid"
        );
        _req(pool.totalDeposits() == 0, "pool withdraw: empty");
        _checkViews(f, c);
    }

    /// @dev Open 5 WETH against 5,000 (ICR 2 at 2,000).
    function _open(BagehotFactory f, DeployConfig memory c, address who) internal returns (uint256 id) {
        VaultManager v = f.vaultManager();
        _freshPrice(c);
        uint256 debtBefore = f.token().balanceOf(who);
        int256 eBefore = _e(f);
        vm.recordLogs();
        vm.prank(who);
        id = v.openPosition(5 ether, 5000e18, 0, 0);
        Counters memory g = _count(vm.getRecordedLogs(), address(v));
        _req(g.gX == 1, "open: exactly one PositionUpdated(OP_OPEN)");
        _req(f.token().balanceOf(who) - debtBefore == 5000e18, "open: debt minted to the owner");
        _checkI2Step(f, eBefore, g);
        _checkViews(f, c);
    }

    /// @dev A day later, accrue: interest to the reserve, and in A the pool's share to the pool.
    function _accrue(BagehotFactory f, DeployConfig memory c) internal {
        VaultManager v = f.vaultManager();
        vm.warp(block.timestamp + 1 days);
        _freshPrice(c);
        uint256 indexBefore = v.index();
        uint256 reserveBefore = f.token().balanceOf(f.deficitLedger());
        uint256 poolBefore = f.token().balanceOf(f.strategy());
        int256 eBefore = _e(f);
        vm.recordLogs();
        v.accrue();
        Counters memory g = _count(vm.getRecordedLogs(), address(v));
        _req(g.gN == 1, "accrue: exactly one InterestAccrued");
        _req(v.index() > indexBefore, "accrue: index rose");
        _req(
            f.token().balanceOf(f.deficitLedger()) > reserveBefore,
            "accrue: reserve share minted to the ledger"
        );
        _req(
            StandInDeficitLedger(f.deficitLedger()).reserve() == f.token().balanceOf(f.deficitLedger()),
            "accrue: reserve recorded"
        );
        if (!c.variantB) {
            _req(f.token().balanceOf(f.strategy()) > poolBefore, "accrue: pool share minted to the pool");
            _req(g.redirected == 0, "accrue: the pool booked, nothing redirected");
        }
        _checkI2Step(f, eBefore, g);
        _checkViews(f, c);
    }

    /// @dev Redeem 100: a partial on the position just opened (the only one, or the riskiest).
    function _redeem(BagehotFactory f, DeployConfig memory c, address who, uint256 id) internal {
        VaultManager v = f.vaultManager();
        RedemptionModule rm = f.redemptionModule(); // fetched before the prank: a call would consume it
        uint256 tokenBefore = f.token().balanceOf(who);
        uint256 wethBefore = LocalWETH(c.weth).balanceOf(who);
        int256 eBefore = _e(f);
        vm.recordLogs();
        vm.prank(who);
        rm.redeem(100e18, 5, WAD, 0, 0);
        Counters memory g = _count(vm.getRecordedLogs(), address(v));
        _req(g.gX + g.gY >= 1, "redeem: a PositionRedeemed");
        _req(tokenBefore - f.token().balanceOf(who) == 100e18, "redeem: 100 burned");
        _req(LocalWETH(c.weth).balanceOf(who) > wethBefore, "redeem: collateral paid out");
        _req(v.positions(id).status == VaultManager.Status.Active, "redeem: the position is still active");
        _checkI2Step(f, eBefore, g);
        _checkViews(f, c);
    }

    function _freshPrice(DeployConfig memory c) internal {
        MockAggregator feed = MockAggregator(c.priceFeed);
        (uint80 roundId, int256 answer,,,) = feed.latestRoundData();
        feed.setRound(roundId + 1, answer, block.timestamp);
    }

    /// @dev I2's counters from the VaultManager's events of one step.
    function _count(Vm.Log[] memory logs, address v) internal pure returns (Counters memory g) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != v) continue;
            bytes32 t = logs[i].topics[0];
            if (t == VaultManager.InterestAccrued.selector) {
                ++g.gN;
            } else if (t == VaultManager.PositionUpdated.selector) {
                (,,,,,, uint8 op) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint8, uint8));
                if (op == OP_OPEN || op == OP_BORROW || op == OP_REPAY) ++g.gX;
                else if (op == OP_CLOSE) ++g.gY;
            } else if (t == VaultManager.PoolInterestRedirected.selector) {
                ++g.redirected;
            } else if (t == VaultManager.PositionRedeemed.selector) {
                (,,, bool closed) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
                if (closed) ++g.gY;
                else ++g.gX;
            }
        }
    }

    /// @dev I2's E = n·I − (S − A − F)·RAY, with A and F read from the ledger.
    function _e(BagehotFactory f) internal view returns (int256) {
        VaultManager v = f.vaultManager();
        IDeficitLedgerViews l = IDeficitLedgerViews(f.deficitLedger());
        uint256 backed = f.token().totalSupply() - l.auctionDebt() - l.deficit();
        return int256(v.totalNormDebt() * v.index()) - int256(backed * RAY);
    }

    /// @dev I2's bound is a sum of per-sub-effect bounds, so one step's change of E lies within the
    ///      step's own: −ΔgN·RAY ≤ ΔE ≤ ΔgX·I + ΔgY·RAY.
    function _checkI2Step(BagehotFactory f, int256 eBefore, Counters memory g) internal view {
        int256 dE = _e(f) - eBefore;
        _req(dE >= -int256(g.gN * RAY), "I2: the step's lower bound");
        _req(dE <= int256(g.gX * f.vaultManager().index() + g.gY * RAY), "I2: the step's upper bound");
    }

    /// @dev View-based invariants after every step.
    function _checkViews(BagehotFactory f, DeployConfig memory c) internal view {
        VaultManager v = f.vaultManager();
        LocalWETH weth = LocalWETH(c.weth);
        // I1 holders: the VaultManager holds exactly its claims; the RedemptionModule and the stand-ins
        // hold no WETH (nothing donated in a smoke run)
        _req(
            weth.balanceOf(address(v))
                == v.totalCollateral() + v.pendingColl() + v.activeCount() * c.gasReserve,
            "I1: VaultManager WETH"
        );
        _req(weth.balanceOf(address(f.redemptionModule())) == 0, "I1: RedemptionModule WETH");
        _req(f.token().balanceOf(address(f.redemptionModule())) == 0, "I1: RedemptionModule token");
        if (c.variantB) {
            _req(weth.balanceOf(f.strategy()) == 0, "I1: strategy WETH");
        } else {
            StabilityPool pool = StabilityPool(f.strategy());
            _req(weth.balanceOf(address(pool)) == pool.collGainsBalance(), "I1: pool WETH");
            _req(
                f.token().balanceOf(address(pool)) == pool.totalDeposits() + pool.interestGainsBalance(),
                "I1: pool stablecoin"
            );
        }
        _req(
            weth.balanceOf(f.deficitLedger()) == IDeficitLedgerViews(f.deficitLedger()).recoveredColl(),
            "I1: ledger WETH"
        );
        // I1 supporting sums: the list holds every active position
        _req(f.sorted().getSize() == v.activeCount(), "I1: activeCount = list size");
        // TCR at or above the critical gate (redemption must be open)
        (, int256 answer,,,) = MockAggregator(c.priceFeed).latestRoundData();
        uint256 price = uint256(answer) * 10 ** (18 - c.mockFeedDecimals);
        _req(v.systemDebt() == 0 || v.tcr(price) >= c.criticalTcr, "TCR at or above CRITICAL_TCR");
    }

    function _req(bool ok, string memory what) internal pure {
        if (!ok) revert SmokeFailed(what);
    }
}
