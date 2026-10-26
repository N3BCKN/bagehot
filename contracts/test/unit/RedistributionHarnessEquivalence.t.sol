// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {LiquidationFixture} from "../utils/LiquidationFixture.sol";

/// @notice P17-H1: the test-only `VaultManagerHarness.redistribute` that P17's I13 campaign ran on must
///         produce exactly what the real `liquidate` produces on the same inputs. With an empty pool and
///         ICR ≤ 1 + penalty the pool seizes the whole collateral and returns it (`debtAbsorbed = 0`,
///         `collReturned = coll`), which is the harness's case. Compared after each: both accumulators,
///         both error carries, the pending buckets, the totals, the snapshots, every member's effective
///         key and the list order — over fuzzed position sets and repeated liquidations.
contract RedistributionHarnessEquivalenceTest is LiquidationFixture {
    struct Out {
        uint256 lColl;
        uint256 lDebt;
        uint256 eColl;
        uint256 eDebt;
        uint256 pColl;
        uint256 pNorm;
        uint256 stakes;
        uint256 coll;
        uint256 norm;
        uint256 sSnap;
        uint256 cSnap;
        bytes32 keys;
    }

    function setUp() public {
        _deploy(address(0));
    }

    function testFuzz_harnessRedistribute_equalsRealLiquidate(uint256[6] memory seeds, uint8 rounds) public {
        // six positions with collateral 3–30 WETH and ICR 1.5–3 at 2,000
        for (uint256 i; i < 6; ++i) {
            uint256 coll = bound(seeds[i], 3e18, 30e18);
            uint256 icr = 1.5e18 + (seeds[i] >> 128) % 1.5e18;
            uint256 debt = coll * 2000e18 / icr;
            if (debt < MIN_DEBT) debt = MIN_DEBT;
            _open(i % 2 == 0 ? alice : bob, coll, debt);
        }
        rounds = uint8(bound(rounds, 1, 4));
        for (uint256 r; r < rounds; ++r) {
            uint256 id = sorted.getLast(); // the lowest NICR
            if (sorted.getSize() < 2) break;
            // a price at which this position is at ICR ≤ 1.05: the pool would seize all of it
            (uint256 c,) = v.effective(id);
            uint256 debt = v.debtOf(id);
            uint256 price = debt * 1.04e18 / c / 1e10 * 1e10;
            if (price < 10e18) break; // below MIN_PRICE: out of the oracle's range
            _setPrice(price);
            assertTrue(c * price < MCR * debt, "liquidatable");
            uint256 snap = vm.snapshotState();
            vm.prank(liq);
            v.redistribute(id);
            Out memory h = _out();
            vm.revertToState(snap);
            vm.prank(liq);
            v.liquidate(id);
            Out memory real = _out();
            _eq(h, real);
        }
    }

    function _out() internal view returns (Out memory o) {
        (o.lColl, o.lDebt, o.eColl, o.eDebt) = (v.LColl(), v.LDebt(), v.lastErrorColl(), v.lastErrorDebt());
        (o.pColl, o.pNorm) = (v.pendingColl(), v.pendingNormDebt());
        (o.stakes, o.coll, o.norm) = (v.totalStakes(), v.totalCollateral(), v.totalNormDebt());
        (o.sSnap, o.cSnap) = (v.totalStakesSnapshot(), v.totalCollateralSnapshot());
        bytes memory k;
        for (uint256 id = sorted.getFirst(); id != 0; id = sorted.getNext(id)) {
            (uint256 c, uint256 n) = v.effective(id);
            k = abi.encodePacked(k, id, c, n);
        }
        o.keys = keccak256(k);
    }

    function _eq(Out memory a, Out memory b) internal pure {
        assertEq(a.lColl, b.lColl, "LColl");
        assertEq(a.lDebt, b.lDebt, "LDebt");
        assertEq(a.eColl, b.eColl, "lastErrorColl");
        assertEq(a.eDebt, b.eDebt, "lastErrorDebt");
        assertEq(a.pColl, b.pColl, "pendingColl");
        assertEq(a.pNorm, b.pNorm, "pendingNormDebt");
        assertEq(a.stakes, b.stakes, "totalStakes");
        assertEq(a.coll, b.coll, "totalCollateral");
        assertEq(a.norm, b.norm, "totalNormDebt");
        assertEq(a.sSnap, b.sSnap, "totalStakesSnapshot");
        assertEq(a.cSnap, b.cSnap, "totalCollateralSnapshot");
        assertEq(a.keys, b.keys, "every effective key and the list order");
    }
}
