// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {MockHouseViews, MockLedgerViews, MockPool, MockWETH} from "./VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice A VaultManager wired to a real StableToken, SortedPositions and OracleAdapter (with
///         mock feeds), a mock WETH and mock ledger / house views. Start parameters of spec §3.1;
///         deployment A unless `_variantB` is set before `setUp`.
abstract contract VaultFixture is Test {
    uint256 internal constant NOW = 10_000_000;
    uint256 internal constant MCR = 1.1e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant GAS_RESERVE = 0.0375e18;
    uint256 internal constant RATE = 1_547_125_957_863_212_449;
    uint256 internal constant POOL_SHARE_BPS = 7500;
    uint256 internal constant PRICE = 2000e18;

    MockWETH internal weth;
    StableToken internal token;
    OracleAdapter internal oracle;
    MockAggregator internal feed;
    MockSequencerFeed internal seq;
    SortedPositions internal sorted;
    VaultManager internal vm_;
    MockLedgerViews internal ledger;
    MockHouseViews internal house;
    MockPool internal pool;

    address internal strategy;
    address internal constant REDEMPTION = address(0xDE11);
    address internal constant SHUTDOWN = address(0x5D);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bool internal variantB;

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
        sorted = new SortedPositions(30);
        ledger = new MockLedgerViews();
        house = new MockHouseViews();
        pool = new MockPool();
        strategy = variantB ? address(house) : address(pool);
        vm_ = new VaultManager(
            address(weth),
            address(token),
            address(oracle),
            MCR,
            MIN_DEBT,
            GAS_RESERVE,
            RATE,
            variantB ? 0 : POOL_SHARE_BPS
        );
        vm_.wire(
            address(sorted), strategy, variantB ? address(0) : strategy, REDEMPTION, address(ledger), SHUTDOWN
        );
        sorted.wire(address(vm_));
        token.wire(address(vm_), strategy, address(ledger), SHUTDOWN);
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            weth.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            weth.approve(address(vm_), type(uint256).max);
        }
    }

    function _setPrice(uint256 priceWad) internal {
        feed.setRound(1, int256(priceWad / 1e10), block.timestamp - 60);
    }

    function _open(address who, uint256 coll, uint256 debt) internal returns (uint256 id) {
        vm.prank(who);
        id = vm_.openPosition(coll, debt, 0, 0);
    }

    /// @dev The smallest collateral with ICR ≥ MCR at PRICE for `debt` at index RAY:
    ///      ceil(MCR · debt / PRICE).
    function _minColl(uint256 debt) internal pure returns (uint256) {
        return (MCR * debt + PRICE - 1) / PRICE;
    }
}
