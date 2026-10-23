// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice OracleAdapter against an independent reimplementation of the whole §6.10.1 table.
/// @dev The reference shares no code with the contract and deliberately uses different forms:
///      bounds by the exact 512-bit product answer·10^(18−d) compared with MIN/MAX (the contract
///      tests `answer > floor(MAX/scale)` before scaling); staleness as `updatedAt + STALENESS < now`
///      and grace as `startedAt + GRACE ≥ now`, both widened so no addition can overflow (the
///      contract subtracts). Rows are evaluated in the spec's order and the reason is compared, not
///      only the price.
contract OracleAdapterFuzzTest is Test {
    struct Case {
        bool seqFails;
        int256 seqAnswer;
        uint256 startedAt;
        bool priceFails;
        int256 answer;
        uint256 updatedAt;
        uint256 nowTs;
        uint8 decimals;
        uint256 staleness;
        uint256 grace;
        uint256 minPrice;
        uint256 maxPrice;
    }

    function _reference(Case memory c) internal pure returns (bool usable, uint256 price, uint8 reason) {
        if (c.seqFails) return (false, 0, 1);
        if (c.seqAnswer != 0) return (false, 0, 2);
        if (c.startedAt == 0 || c.startedAt > c.nowTs) return (false, 0, 3);
        // grace: now − startedAt ≤ GRACE  ⟺  startedAt + GRACE ≥ now   (sum taken in 257 bits)
        (bool graceOverflow, uint256 graceEnd) = _add(c.startedAt, c.grace);
        if (graceOverflow || graceEnd >= c.nowTs) return (false, 0, 4);
        if (c.priceFails) return (false, 0, 5);
        if (c.answer <= 0) return (false, 0, 6);
        if (c.updatedAt == 0 || c.updatedAt > c.nowTs) return (false, 0, 7);
        // stale: now − updatedAt > STALENESS  ⟺  updatedAt + STALENESS < now
        (bool staleOverflow, uint256 freshUntil) = _add(c.updatedAt, c.staleness);
        if (!staleOverflow && freshUntil < c.nowTs) return (false, 0, 8);
        (uint256 hi, uint256 lo) = Math.mul512(uint256(c.answer), 10 ** (18 - uint256(c.decimals)));
        if (hi != 0 || lo > c.maxPrice || lo < c.minPrice) return (false, 0, 9);
        return (true, lo, 0);
    }

    function _add(uint256 a, uint256 b) internal pure returns (bool overflow, uint256 sum) {
        unchecked {
            sum = a + b;
            overflow = sum < a; // carry out of 256 bits
        }
    }

    function _run(Case memory c) internal {
        vm.warp(c.nowTs);
        MockAggregator feed = new MockAggregator(c.decimals);
        MockSequencerFeed seq = new MockSequencerFeed();
        OracleAdapter oracle = new OracleAdapter(
            address(feed), address(seq), c.staleness, c.grace, c.minPrice, c.maxPrice, 100_000, 3175
        );
        seq.setStatus(c.seqAnswer, c.startedAt);
        if (c.seqFails) seq.setMode(MockAggregator.Mode.Revert);
        feed.setRound(1, c.answer, c.updatedAt);
        if (c.priceFails) feed.setMode(MockAggregator.Mode.Revert);

        (bool rUsable, uint256 rPrice, uint8 rReason) = _reference(c);
        (uint256 p, bool usable, OracleAdapter.Reason reason) = oracle.peek();
        assertEq(usable, rUsable, "usable");
        assertEq(uint8(reason), rReason, "reason");
        assertEq(p, rUsable ? rPrice : 0, "peek price (lastGoodPrice is 0 on a fresh adapter)");
        assertEq(oracle.failureStart(), 0, "peek wrote nothing");

        (uint256 fp, bool fu) = oracle.fetchPrice();
        assertEq(fu, rUsable, "fetchPrice agrees with peek");
        assertEq(fp, rUsable ? rPrice : 0);
        assertEq(oracle.lastGoodPrice(), rUsable ? rPrice : 0);
        assertEq(oracle.failureStart(), rUsable ? 0 : c.nowTs);
    }

    function _params(Case memory c, uint256 seed) internal pure {
        c.decimals = uint8(seed % 19);
        c.staleness = 1 + (seed >> 8) % 100_000;
        c.grace = (seed >> 32) % 100_000;
        c.minPrice = 2e18 + (seed >> 64) % 1e21;
        c.maxPrice = c.minPrice + 1 + (seed >> 128) % (1e30 - c.minPrice); // up to the 1e30 ceiling
    }

    /// @dev Every input over its full range: mostly unusable, which exercises rows 1–9 broadly.
    function testFuzz_fullRange_matchesTheReference(
        bool seqFails,
        int256 seqAnswer,
        uint256 startedAt,
        bool priceFails,
        int256 answer,
        uint256 updatedAt,
        uint256 nowTs,
        uint256 seed
    ) public {
        Case memory c;
        _params(c, seed);
        c.seqFails = seqFails;
        c.seqAnswer = seqAnswer;
        c.startedAt = startedAt;
        c.priceFails = priceFails;
        c.answer = answer;
        c.updatedAt = updatedAt;
        c.nowTs = bound(nowTs, 1, type(uint64).max); // a block timestamp
        _run(c);
    }

    /// @dev Biased into the neighbourhood where decisions flip: sequencer up, timestamps around the
    ///      grace and staleness edges, answers around both price bounds in feed units.
    function testFuzz_nearTheEdges_matchesTheReference(
        uint256 seed,
        int256 startOffset,
        int256 updateOffset,
        int256 answerOffset,
        bool nearMax
    ) public {
        Case memory c;
        _params(c, seed);
        c.nowTs = 1_000_000_000;
        int256 so = int256(bound(startOffset, -3, 3));
        int256 uo = int256(bound(updateOffset, -3, 3));
        c.startedAt = uint256(int256(c.nowTs) - int256(c.grace) + so - 1);
        c.updatedAt = uint256(int256(c.nowTs) - int256(c.staleness) + uo);
        uint256 scale = 10 ** (18 - uint256(c.decimals));
        uint256 edge = nearMax ? c.maxPrice / scale : Math.ceilDiv(c.minPrice, scale);
        int256 ao = int256(bound(answerOffset, -2, 2));
        c.answer = int256(edge) + ao;
        _run(c);
    }
}
