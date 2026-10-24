// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../../src/core/HintHelpers.sol";
import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {ISortKeySource} from "../../src/interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../../src/interfaces/ISortedPositions.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {MockPurchaseHouse, MockShutdownGate} from "./RedemptionMocks.sol";
import {VaultManagerHarness} from "./VaultManagerHarness.sol";
import {MockLedgerViews, MockPool, MockWETH} from "./VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice A RedemptionModule wired to a VaultManager (the test harness, so a test can set a
///         non-round index or pending rewards), real StableToken / SortedPositions / OracleAdapter
///         (mock feeds), HintHelpers, §5.8's gate (`MockShutdownGate`), mock WETH / ledger / pool or
///         house. Start parameters of spec §3.1; deployment A unless `variantB` is set before `setUp`.
abstract contract RedemptionFixture is Test {
    uint256 internal constant NOW = 10_000_000;
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
    uint256 internal constant PRICE = 2000e18;

    MockWETH internal weth;
    StableToken internal token;
    OracleAdapter internal oracle;
    MockAggregator internal feed;
    MockSequencerFeed internal seq;
    SortedPositions internal sorted;
    VaultManagerHarness internal v;
    MockLedgerViews internal ledger;
    MockPool internal pool;
    MockPurchaseHouse internal house;
    MockShutdownGate internal gate;
    RedemptionModule internal rm;
    HintHelpers internal hints;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

    bool internal variantB;
    uint256 internal maxHintSteps = 30;

    function setUp() public virtual {
        vm.warp(NOW);
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        feed = new MockAggregator(8);
        seq = new MockSequencerFeed();
        seq.setStatus(0, NOW - 100_000);
        _setPrice(PRICE);
        oracle =
            new OracleAdapter(address(feed), address(seq), 3600, 3600, 10e18, 1_000_000e18, 100_000, 3175);
        sorted = new SortedPositions(maxHintSteps);
        ledger = new MockLedgerViews();
        pool = new MockPool();
        house = new MockPurchaseHouse();
        address strategy = variantB ? address(house) : address(pool);
        v = new VaultManagerHarness(
            address(weth),
            address(token),
            address(oracle),
            MCR,
            MIN_DEBT,
            GAS_RESERVE,
            RATE,
            variantB ? 0 : POOL_SHARE_BPS
        );
        rm = new RedemptionModule(address(token), address(oracle), FEE_FLOOR, BETA, DECAY);
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
        address[5] memory actors = [alice, bob, carol, dave, erin];
        for (uint256 i; i < actors.length; ++i) {
            weth.mint(actors[i], 1e30);
            vm.prank(actors[i]);
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

    function _redeem(address who, uint256 amount) internal {
        vm.prank(who);
        rm.redeem(amount, 50, WAD, 0, 0);
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(address(v));
        token.mint(to, amount);
    }
}
