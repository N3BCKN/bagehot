// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {DeficitLedger} from "../../src/safety/DeficitLedger.sol";
import {VaultManagerHarness} from "./VaultManagerHarness.sol";
import {MockWETH} from "./VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Deployment A for the liquidation tests (P20): the VaultManager (harness, for P17-H1), the
///         real StabilityPool as strategy, the DeficitLedger stand-in, SortedPositions, StableToken and
///         the OracleAdapter over mock feeds. The redemption module and shutdown module are inert
///         addresses (liquidation calls neither). Start parameters of §3.1.
abstract contract LiquidationFixture is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MCR = 1.1e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant GAS_RESERVE = 0.0375e18;
    uint256 internal constant RATE = 1_547_125_957_863_212_449;
    uint256 internal constant PENALTY = 0.05e18;
    uint256 internal constant STALENESS = 3600;
    uint256 internal constant GRACE = 3600;
    address internal constant SHUTDOWN = address(0x5D);
    address internal constant REDEMPTION = address(0xDE11);

    MockWETH internal weth;
    StableToken internal token;
    MockAggregator internal feed;
    MockSequencerFeed internal seq;
    OracleAdapter internal oracle;
    SortedPositions internal sorted;
    VaultManagerHarness internal v;
    StabilityPool internal pool;
    DeficitLedger internal ledger;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal liq = makeAddr("liquidator");

    function _deploy(address strategyOverride) internal {
        vm.warp(10_000_000);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        seq = new MockSequencerFeed();
        seq.setStatus(0, block.timestamp - GRACE - 1);
        _setPrice(2000e18);
        oracle = new OracleAdapter(
            address(feed), address(seq), STALENESS, GRACE, 10e18, 1_000_000e18, 100_000, 3175
        );
        sorted = new SortedPositions(30);
        v = new VaultManagerHarness(
            address(weth), address(token), address(oracle), MCR, MIN_DEBT, GAS_RESERVE, RATE, 7500, 200_000
        );
        pool = new StabilityPool(address(weth), address(token), PENALTY, 1e18);
        ledger = new DeficitLedger(address(weth), address(token));
        address strategy = strategyOverride == address(0) ? address(pool) : strategyOverride;
        v.wire(address(sorted), strategy, strategy, REDEMPTION, address(ledger), SHUTDOWN);
        sorted.wire(address(v));
        token.wire(address(v), strategy, address(ledger), SHUTDOWN);
        pool.wire(address(v), address(ledger));
        ledger.wire(address(v), strategy, address(0), strategy, SHUTDOWN);
        address[4] memory who = [alice, bob, carol, liq];
        for (uint256 i; i < 4; ++i) {
            weth.mint(who[i], 1e27);
            vm.prank(who[i]);
            weth.approve(address(v), type(uint256).max);
        }
    }

    function _setPrice(uint256 priceWad) internal {
        feed.setRound(1, int256(priceWad / 1e10), block.timestamp);
    }

    function _open(address who, uint256 coll, uint256 debt) internal returns (uint256 id) {
        vm.prank(who);
        id = v.openPosition(coll, debt, 0, 0);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        pool.deposit(amount);
    }
}

/// @notice A strategy whose `onLiquidation` answers as configured (CHG-012 bounds, re-entry). It sends
///         back `collReturned` WETH (minted if it reports more than it received, so the VaultManager's
///         check, not a failed transfer, is what stops the violation).
contract ScriptedStrategy {
    MockWETH public weth;
    address public vaultManager;
    uint256 public extraDebt;
    uint256 public extraColl;
    bool public returnAll;
    int256 public sendDelta; // CHG-014: send collReturned + sendDelta instead of collReturned
    bytes public reenterCall;
    bytes public innerRevert;

    function setVault(address v, MockWETH weth_) external {
        (vaultManager, weth) = (v, weth_);
    }

    function script(uint256 extraDebt_, uint256 extraColl_, bool returnAll_) external {
        (extraDebt, extraColl, returnAll) = (extraDebt_, extraColl_, returnAll_);
    }

    function setSendDelta(int256 d) external {
        sendDelta = d;
    }

    function setReenter(bytes calldata data) external {
        reenterCall = data;
    }

    function onLiquidation(uint256, address, uint256 debt, uint256 coll, uint256)
        external
        returns (uint256 debtAbsorbed, uint256 collReturned)
    {
        if (reenterCall.length > 0) {
            (bool ok, bytes memory ret) = vaultManager.call(reenterCall);
            innerRevert = ok ? bytes("") : ret;
        }
        debtAbsorbed = returnAll ? 0 : debt + extraDebt;
        collReturned = returnAll ? coll + extraColl : extraColl;
        uint256 send = uint256(int256(collReturned) + sendDelta);
        if (send > weth.balanceOf(address(this))) {
            weth.mint(address(this), send - weth.balanceOf(address(this)));
        }
        if (send > 0) weth.transfer(vaultManager, send);
    }

    // the stand-in role reads these in accrual; an empty pool declines
    function acceptsInterest() external pure returns (bool) {
        return false;
    }

    function onInterest(uint256) external pure returns (bool) {
        return false;
    }
}
