// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {InvalidParameter} from "../../src/lib/Errors.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {RawFeed} from "../../src/mocks/RawFeed.sol";
import {OracleAdapterHarness} from "../utils/OracleAdapterHarness.sol";
import {OracleFixture} from "../utils/OracleFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice OracleAdapter: constructor checks, every row of the §6.10.1 decision table, malformed
///         feed output (ADR-0029), events and the failure clock (§6.10.2), and boundaries.
contract OracleAdapterTest is OracleFixture {
    bytes internal constant READ = abi.encodeCall(AggregatorV3Interface.latestRoundData, ());
    /// @dev The raw price feed reports 18 decimals (scale 1), so its answer is already WAD.
    int256 internal constant RAW_ANSWER = 2000e18;
    /// @dev Largest revert payload a feed can deliver inside ORACLE_GAS (it encodes the bytes
    ///      twice: building them, then `revert RawFeedReverted(out)`), and the measured copy cost
    ///      a copying reader pays for it, rounded down.
    uint256 internal constant REVERT_BOMB = 60_000;
    uint256 internal constant REVERT_MARGIN = 10_000;

    function _assertUnusable(OracleAdapter.Reason expected) internal {
        (uint256 p, bool usable, OracleAdapter.Reason r) = oracle.peek();
        assertFalse(usable, "peek usable");
        assertEq(_reason(r), _reason(expected), "reason");
        assertEq(p, oracle.lastGoodPrice(), "peek price is lastGoodPrice");
        (uint256 fp, bool fu) = oracle.fetchPrice();
        assertFalse(fu, "fetch usable");
        assertEq(fp, oracle.lastGoodPrice(), "fetch price is lastGoodPrice");
        assertEq(oracle.failureStart(), block.timestamp, "failure clock started");
    }

    function _assertUsable(uint256 expectedPrice) internal {
        (uint256 p, bool usable, OracleAdapter.Reason r) = oracle.peek();
        assertTrue(usable, "peek usable");
        assertEq(_reason(r), 0, "reason OK");
        assertEq(p, expectedPrice, "peek price");
        (uint256 fp, bool fu) = oracle.fetchPrice();
        assertTrue(fu, "fetch usable");
        assertEq(fp, expectedPrice, "fetch price");
        assertEq(oracle.lastGoodPrice(), expectedPrice);
        assertEq(oracle.failureStart(), 0);
    }

    // ------------------------------------------------------------------ reason codes by value

    /// @dev Values are ABI (spec §11.1) and must equal model/protocol/oracle.py's IntEnum.
    function test_reasonCodes_matchTheSpecByValue() public pure {
        assertEq(uint8(OracleAdapter.Reason.OK), 0);
        assertEq(uint8(OracleAdapter.Reason.SEQUENCER_CALL_FAILED), 1);
        assertEq(uint8(OracleAdapter.Reason.SEQUENCER_DOWN), 2);
        assertEq(uint8(OracleAdapter.Reason.SEQUENCER_INVALID), 3);
        assertEq(uint8(OracleAdapter.Reason.GRACE_PERIOD), 4);
        assertEq(uint8(OracleAdapter.Reason.PRICE_CALL_FAILED), 5);
        assertEq(uint8(OracleAdapter.Reason.NON_POSITIVE), 6);
        assertEq(uint8(OracleAdapter.Reason.INVALID_TIMESTAMP), 7);
        assertEq(uint8(OracleAdapter.Reason.STALE), 8);
        assertEq(uint8(OracleAdapter.Reason.OUT_OF_BOUNDS), 9);
    }

    // ------------------------------------------------------------------ constructor

    function test_constructor_setsEverything() public view {
        assertEq(address(oracle.priceFeed()), address(feed));
        assertEq(address(oracle.sequencerFeed()), address(seq));
        assertEq(oracle.FEED_DECIMALS(), 8);
        assertEq(oracle.STALENESS(), STALENESS);
        assertEq(oracle.GRACE_PERIOD(), GRACE);
        assertEq(oracle.MIN_PRICE(), MIN_PRICE);
        assertEq(oracle.MAX_PRICE(), MAX_PRICE);
        assertEq(oracle.ORACLE_GAS(), ORACLE_GAS);
        assertEq(oracle.ORACLE_POST_FAILURE_GAS(), POST_GAS);
        assertEq(oracle.lastGoodPrice(), 0);
        assertEq(oracle.failureStart(), 0);
    }

    /// @dev Deploys expecting exactly `err`. try/catch instead of vm.expectRevert: forge coverage
    ///      does not attribute a constructor's revert branches under expectRevert (checked at P12),
    ///      and matching the full revert bytes is the same assertion.
    function _deployReverts(
        bytes memory err,
        address f,
        address s,
        uint256 st,
        uint256 gr,
        uint256 mn,
        uint256 mx,
        uint256 og,
        uint256 pg
    ) internal {
        try this.deployAdapter(f, s, st, gr, mn, mx, og, pg) returns (OracleAdapter) {
            fail("constructor did not revert");
        } catch (bytes memory got) {
            assertEq(got, err);
        }
    }

    /// @dev External so the `try` above catches the constructor's revert as a call failure: forge
    ///      may compile `new` in tests to a deployCode cheatcode, whose revert a same-frame `try`
    ///      cannot catch.
    function deployAdapter(
        address f,
        address s,
        uint256 st,
        uint256 gr,
        uint256 mn,
        uint256 mx,
        uint256 og,
        uint256 pg
    ) external returns (OracleAdapter) {
        return new OracleAdapter(f, s, st, gr, mn, mx, og, pg);
    }

    function _invalid(uint8 index) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(InvalidParameter.selector, index);
    }

    function _badDecimals() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OracleAdapter.InvalidFeedDecimals.selector);
    }

    function _deployRevertsDefaults(bytes memory err, address f) internal {
        _deployReverts(err, f, address(seq), STALENESS, GRACE, MIN_PRICE, MAX_PRICE, ORACLE_GAS, POST_GAS);
    }

    function test_constructor_rejectsEachArgumentAtItsBoundary() public {
        address f = address(feed);
        address s = address(seq);
        _deployReverts(_invalid(0), address(0), s, 1, 0, 2e18, 3e18, 50_000, 794);
        _deployReverts(_invalid(1), f, address(0), 1, 0, 2e18, 3e18, 50_000, 794);
        _deployReverts(_invalid(2), f, s, 0, 0, 2e18, 3e18, 50_000, 794);
        _deployReverts(_invalid(4), f, s, 1, 0, 2e18 - 1, 3e18, 50_000, 794);
        _deployReverts(_invalid(5), f, s, 1, 0, 2e18, 2e18, 50_000, 794); // MAX == MIN
        _deployReverts(_invalid(5), f, s, 1, 0, 2e18, 1e30 + 1, 50_000, 794);
        _deployReverts(_invalid(6), f, s, 1, 0, 2e18, 3e18, 49_999, 794);
        _deployReverts(_invalid(6), f, s, 1, 0, 2e18, 3e18, 1_000_001, 15_874);
        _deployReverts(_invalid(7), f, s, 1, 0, 2e18, 3e18, 50_000, 793); // ceil(50_000 / 63) = 794
        // every boundary value itself is accepted, and GRACE_PERIOD takes any value
        new OracleAdapter(f, s, 1, 0, 2e18, 2e18 + 1, 50_000, 794);
        new OracleAdapter(f, s, 1, type(uint256).max, 2e18, 1e30, 1_000_000, 15_874); // ceil(1e6/63)
    }

    function test_constructor_firstFailingArgumentWins() public {
        _deployReverts(_invalid(0), address(0), address(0), 0, 0, 0, 0, 0, 0);
        _deployReverts(_invalid(2), address(feed), address(seq), 0, 0, 0, 0, 0, 0);
        _deployReverts(_invalid(4), address(feed), address(seq), 1, 0, 0, 0, 0, 0);
    }

    function test_constructor_invalidFeedDecimals_reverts() public {
        feed.setMode(MockAggregator.Mode.Revert);
        _deployRevertsDefaults(_badDecimals(), address(feed));
    }

    function test_constructor_invalidFeedDecimals_shortOrEmptyOrNoCode() public {
        RawFeed raw = new RawFeed();
        raw.setPayload(new bytes(31));
        _deployRevertsDefaults(_badDecimals(), address(raw));
        raw.setPayload(hex"");
        _deployRevertsDefaults(_badDecimals(), address(raw));
        _deployRevertsDefaults(_badDecimals(), address(0xDEAD)); // no code: call succeeds with empty return
        // data
    }

    function test_constructor_invalidFeedDecimals_above18OrJunkWord() public {
        MockAggregator f19 = new MockAggregator(19);
        _deployRevertsDefaults(_badDecimals(), address(f19));
        RawFeed raw = new RawFeed();
        raw.setPayload(abi.encode(uint256(1) << 255)); // not a uint8: rejected, never decoded as one
        _deployRevertsDefaults(_badDecimals(), address(raw));
        raw.setPayload(abi.encode(uint256(18)));
        assertEq(_deploy(address(raw), address(seq)).FEED_DECIMALS(), 18);
        assertEq(_deploy(address(new MockAggregator(0)), address(seq)).FEED_DECIMALS(), 0);
    }

    // ------------------------------------------------------------------ decision table, row by row

    function test_row1_sequencerCallFailed() public {
        seq.setMode(MockAggregator.Mode.Revert);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_CALL_FAILED);
    }

    function test_row2_sequencerDown_anyNonZeroAnswer() public {
        seq.setStatus(1, NOW - 100_000);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_DOWN);
        seq.setStatus(-1, NOW - 100_000);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_DOWN);
    }

    function test_row3_sequencerStartedAtZeroOrFuture() public {
        seq.setStatus(0, 0);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_INVALID);
        seq.setStatus(0, NOW + 1);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_INVALID);
    }

    function test_row4_gracePeriodBoundary() public {
        seq.setStatus(0, NOW - GRACE); // now − startedAt == GRACE: still in grace (≤)
        _assertUnusable(OracleAdapter.Reason.GRACE_PERIOD);
        seq.setStatus(0, NOW); // just restarted
        _assertUnusable(OracleAdapter.Reason.GRACE_PERIOD);
        seq.setStatus(0, NOW - GRACE - 1);
        _assertUsable(2000e18);
    }

    function test_row5_priceCallFailed() public {
        feed.setMode(MockAggregator.Mode.Revert);
        _assertUnusable(OracleAdapter.Reason.PRICE_CALL_FAILED);
    }

    function test_row6_nonPositive() public {
        feed.setRound(1, 0, NOW - 60);
        _assertUnusable(OracleAdapter.Reason.NON_POSITIVE);
        feed.setRound(1, type(int256).min, NOW - 60);
        _assertUnusable(OracleAdapter.Reason.NON_POSITIVE);
    }

    function test_row7_updatedAtZeroOrFuture() public {
        feed.setRound(1, ANSWER, 0);
        _assertUnusable(OracleAdapter.Reason.INVALID_TIMESTAMP);
        feed.setRound(1, ANSWER, NOW + 1);
        _assertUnusable(OracleAdapter.Reason.INVALID_TIMESTAMP);
        feed.setRound(1, ANSWER, NOW); // updated this very second: fine
        _assertUsable(2000e18);
    }

    function test_row8_stalenessBoundary() public {
        feed.setRound(1, ANSWER, NOW - STALENESS); // exactly STALENESS old: usable (>)
        _assertUsable(2000e18);
        feed.setRound(1, ANSWER, NOW - STALENESS - 1);
        _assertUnusable(OracleAdapter.Reason.STALE);
    }

    function test_row10_scalesToWad() public {
        _assertUsable(2000e18);
        feed.setRound(2, 123_456_789_012, NOW - 60);
        _assertUsable(1_234_567_890_120_000_000_000);
    }

    /// @dev §6.10.1 row 9 at the two bounds, on the real 8-decimal shape: the scaled price moves
    ///      in steps of 1e10 wei, so the neighbours of a bound are one answer unit away.
    function test_row9_boundaries_8decimals() public {
        int256 minA = int256(MIN_PRICE / 1e10);
        int256 maxA = int256(MAX_PRICE / 1e10);
        feed.setRound(1, minA - 1, NOW - 60);
        _assertUnusable(OracleAdapter.Reason.OUT_OF_BOUNDS);
        feed.setRound(1, minA, NOW - 60);
        _assertUsable(MIN_PRICE);
        feed.setRound(1, minA + 1, NOW - 60);
        _assertUsable(MIN_PRICE + 1e10);
        feed.setRound(1, maxA - 1, NOW - 60);
        _assertUsable(MAX_PRICE - 1e10);
        feed.setRound(1, maxA, NOW - 60);
        _assertUsable(MAX_PRICE);
        feed.setRound(1, maxA + 1, NOW - 60);
        _assertUnusable(OracleAdapter.Reason.OUT_OF_BOUNDS);
    }

    /// @dev The same bounds at wei resolution, with an 18-decimal feed (scale 1).
    function test_row9_boundaries_18decimals_weiExact() public {
        MockAggregator f18 = new MockAggregator(18);
        oracle = _deploy(address(f18), address(seq));
        uint256[6] memory answers =
            [MIN_PRICE - 1, MIN_PRICE, MIN_PRICE + 1, MAX_PRICE - 1, MAX_PRICE, MAX_PRICE + 1];
        bool[6] memory ok = [false, true, true, true, true, false];
        for (uint256 i; i < 6; ++i) {
            f18.setRound(1, int256(answers[i]), NOW - 60);
            if (ok[i]) _assertUsable(answers[i]);
            else _assertUnusable(OracleAdapter.Reason.OUT_OF_BOUNDS);
        }
    }

    function test_row9_hugeAnswerDoesNotOverflow() public {
        feed.setRound(1, type(int256).max, NOW - 60);
        _assertUnusable(OracleAdapter.Reason.OUT_OF_BOUNDS);
        MockAggregator f0 = new MockAggregator(0); // scale 1e18: the largest multiplier
        oracle = _deploy(address(f0), address(seq));
        f0.setRound(1, type(int256).max, NOW - 60);
        _assertUnusable(OracleAdapter.Reason.OUT_OF_BOUNDS);
        f0.setRound(1, 1_000_000, NOW - 60);
        _assertUsable(1_000_000e18);
    }

    // ------------------------------------------------------------------ lazy reads (§6.10.2)

    function test_lazy_priceFeedNeverCalledWhenTheSequencerDecides() public {
        feed.setMode(MockAggregator.Mode.Revert); // would be PRICE_CALL_FAILED if reached
        int256[4] memory answers = [int256(1), 0, 0, 0];
        uint256[4] memory started = [NOW - 100_000, 0, NOW + 1, NOW - 10];
        OracleAdapter.Reason[4] memory reasons = [
            OracleAdapter.Reason.SEQUENCER_DOWN,
            OracleAdapter.Reason.SEQUENCER_INVALID,
            OracleAdapter.Reason.SEQUENCER_INVALID,
            OracleAdapter.Reason.GRACE_PERIOD
        ];
        vm.expectCall(address(feed), READ, 0); // counts every call for the rest of the test
        for (uint256 i; i < 4; ++i) {
            seq.setStatus(answers[i], started[i]);
            _assertUnusable(reasons[i]);
        }
        seq.setMode(MockAggregator.Mode.Revert);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_CALL_FAILED);
    }

    function test_lazy_eachFeedReadExactlyOncePerDecision() public {
        vm.expectCall(address(seq), READ, 1);
        vm.expectCall(address(feed), READ, 1);
        oracle.fetchPrice();
    }

    // ------------------------------------------------------------------ malformed output (ADR-0029)

    function _rawPrice() internal returns (RawFeed raw) {
        raw = new RawFeed();
        raw.setPayload(abi.encode(uint256(18))); // decimals() reply
        oracle = new OracleAdapter(
            address(raw), address(seq), STALENESS, GRACE, MIN_PRICE, MAX_PRICE, ORACLE_GAS, POST_GAS
        );
        raw.setPayload(abi.encode(uint80(1), RAW_ANSWER, NOW - 60, NOW - 60, uint80(1)));
    }

    function _rawSequencer() internal returns (RawFeed raw) {
        raw = new RawFeed();
        oracle = _deploy(address(feed), address(raw));
        raw.setPayload(abi.encode(uint80(1), int256(0), NOW - 100_000, NOW - 100_000, uint80(1)));
    }

    function test_malformed_shortReturnsAreFailedCalls_priceFeed() public {
        RawFeed raw = _rawPrice();
        _assertUsable(2000e18); // the well-formed 160-byte answer of an 18-decimal raw feed
        raw.setPayload(new bytes(159));
        _assertUnusable(OracleAdapter.Reason.PRICE_CALL_FAILED);
        raw.setPayload(abi.encode(RAW_ANSWER));
        _assertUnusable(OracleAdapter.Reason.PRICE_CALL_FAILED);
        raw.setPayload(hex"");
        _assertUnusable(OracleAdapter.Reason.PRICE_CALL_FAILED);
    }

    function test_malformed_shortReturnsAreFailedCalls_sequencer() public {
        RawFeed raw = _rawSequencer();
        _assertUsable(2000e18);
        raw.setPayload(new bytes(159));
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_CALL_FAILED);
        raw.setPayload(abi.encode(int256(0)));
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_CALL_FAILED);
    }

    function test_malformed_noCodeAtTheFeedIsAFailedCall() public {
        oracle = _deploy(address(feed), address(0xC0DE)); // sequencer address without code
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_CALL_FAILED);
    }

    /// @dev Junk above bit 80 in roundId and answeredInRound must neither revert nor matter.
    function test_malformed_junkInTheUint80WordsIsIgnored() public {
        RawFeed raw = _rawPrice();
        raw.setPayload(abi.encode(type(uint256).max, RAW_ANSWER, NOW - 60, NOW - 60, type(uint256).max));
        _assertUsable(2000e18);
        RawFeed rs = _rawSequencer();
        rs.setPayload(
            abi.encode(type(uint256).max, int256(0), NOW - 100_000, NOW - 100_000, type(uint256).max)
        );
        _assertUsable(2000e18);
    }

    function test_malformed_longerThan160BytesUsesTheFirstFiveWords() public {
        RawFeed raw = _rawPrice();
        raw.setPadding(64);
        _assertUsable(2000e18);
    }

    // ------------------------------------------------------------------ return and revert bombs

    function _gasOfFetch() internal returns (uint256 used, bool usable) {
        uint256 g = gasleft();
        (, usable) = oracle.fetchPrice();
        used = g - gasleft();
    }

    /// @dev A 100 KB reply costs the adapter no copy: its extra cost over the 160-byte reply is
    ///      at least 20k gas below what a reader that copies return data pays for the same reply.
    ///      (Measured at P12: a copying reader pays ~38k more for 100 KB; ADR-0029.)
    function test_bomb_hugeReturnDataIsNeverCopied() public {
        RawFeed raw = _rawPrice();
        (uint256 honest, bool u1) = _gasOfFetch();
        uint256 probeHonest = _copyingRead(address(raw));
        raw.setPadding(100_000);
        (uint256 bombed, bool u2) = _gasOfFetch();
        uint256 probeBombed = _copyingRead(address(raw));
        assertTrue(u1 && u2, "a valid prefix with padding is still a valid answer");
        assertLe(bombed - honest + 20_000, probeBombed - probeHonest, "no copy cost");
    }

    /// @dev Gas of a capped high-level staticcall, which copies all return data into memory.
    function _copyingRead(address f) internal view returns (uint256 used) {
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = f.staticcall{gas: ORACLE_GAS}(READ);
        used = g - gasleft();
        assertTrue(ok && ret.length >= 160);
    }

    /// @dev Revert data is not copied either, so feed-chosen revert data costs the adapter nothing
    ///      between the failed call and the gas rule. The discriminating assertion is the gas margin:
    ///      the adapter's extra cost for a 60 KB revert is at least 10k below a copying reader's
    ///      (ADR-0029). The "recorded" assertion runs with ample gas and would also hold for a
    ///      copying implementation; it checks only that the failure is recorded at all.
    function test_bomb_hugeRevertDataIsNeverCopiedAndTheFailureIsRecorded() public {
        RawFeed raw = _rawPrice();
        raw.setReverts(true);
        oracle.fetchPrice(); // warm the slots, first failure recorded
        (uint256 small, bool u1) = _gasOfFetch();
        uint256 probeSmall = _copyingFailedRead(address(raw), 0);
        raw.setPadding(REVERT_BOMB);
        (uint256 bombed, bool u2) = _gasOfFetch();
        uint256 probeBombed = _copyingFailedRead(address(raw), REVERT_BOMB);
        assertFalse(u1 || u2);
        assertEq(oracle.failureStart(), block.timestamp, "failure recorded, not InsufficientGasForOracle");
        assertLe(bombed - small + REVERT_MARGIN, probeBombed - probeSmall, "no copy cost");
    }

    /// @dev Gas of a capped high-level staticcall that fails, copying all revert data into memory.
    function _copyingFailedRead(address f, uint256 minLength) internal view returns (uint256 used) {
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = f.staticcall{gas: ORACLE_GAS}(READ); // `ret` forces the copy
        used = g - gasleft();
        assertFalse(ok);
        assertGe(ret.length, minLength, "the feed delivered the whole revert payload");
    }

    /// @dev ADR-0029 property 1 (memory-safe): memory allocated before the read is intact after
    ///      it, and memory allocated after it is usable — for an honest reply, a 100 KB reply, a
    ///      100 KB revert and a feed without code.
    function test_readFeed_isMemorySafe() public {
        OracleAdapterHarness h = new OracleAdapterHarness(address(feed), address(seq));
        RawFeed raw = new RawFeed();
        raw.setPayload(abi.encode(uint80(1), ANSWER, NOW - 60, NOW - 60, uint80(1)));
        (bool ok, int256 a, bool before, bool afterwards) = h.readFeedKeepsMemory(feed);
        assertTrue(ok && a == ANSWER && before && afterwards, "honest");
        raw.setPadding(100_000);
        (ok, a, before, afterwards) = h.readFeedKeepsMemory(AggregatorV3Interface(address(raw)));
        assertTrue(ok && a == ANSWER && before && afterwards, "100 KB reply");
        raw.setReverts(true);
        (ok,, before, afterwards) = h.readFeedKeepsMemory(AggregatorV3Interface(address(raw)));
        assertTrue(!ok && before && afterwards, "100 KB revert");
        (ok,, before, afterwards) = h.readFeedKeepsMemory(AggregatorV3Interface(address(0xC0DE)));
        assertTrue(!ok && before && afterwards, "no code");
    }

    // ------------------------------------------------------------------ events and failure clock

    function _countLogs(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == topic) ++n;
        }
    }

    function test_events_lastGoodPriceOnlyOnChange() public {
        vm.expectEmit(address(oracle));
        emit OracleAdapter.LastGoodPriceUpdated(2000e18);
        oracle.fetchPrice();
        vm.recordLogs();
        oracle.fetchPrice(); // same price: no event
        assertEq(vm.getRecordedLogs().length, 0);
        feed.setRound(2, 2001e8, NOW - 30);
        vm.expectEmit(address(oracle));
        emit OracleAdapter.LastGoodPriceUpdated(2001e18);
        oracle.fetchPrice();
    }

    function test_failureClock_startsOnceKeepsThroughReasonChangesAndClearsOnRecovery() public {
        oracle.fetchPrice();
        feed.setRound(2, ANSWER, NOW - STALENESS - 1);
        vm.expectEmit(address(oracle));
        emit OracleAdapter.OracleFailure(uint8(OracleAdapter.Reason.STALE), NOW);
        (uint256 p, bool u) = oracle.fetchPrice();
        assertFalse(u);
        assertEq(p, 2000e18, "returns lastGoodPrice");
        assertEq(oracle.failureStart(), NOW);

        // later, a different reason: the clock keeps its start and no new OracleFailure is emitted
        vm.warp(NOW + 500);
        seq.setStatus(1, NOW);
        vm.recordLogs();
        oracle.fetchPrice();
        assertEq(_countLogs(vm.getRecordedLogs(), OracleAdapter.OracleFailure.selector), 0);
        assertEq(oracle.failureStart(), NOW);

        // recovery clears it, once
        vm.warp(NOW + 10_000);
        seq.setStatus(0, NOW - 100_000);
        feed.setRound(3, ANSWER, NOW + 10_000 - 1);
        vm.expectEmit(address(oracle));
        emit OracleAdapter.OracleRecovered(NOW + 10_000);
        (, u) = oracle.fetchPrice();
        assertTrue(u);
        assertEq(oracle.failureStart(), 0);
        vm.recordLogs();
        oracle.fetchPrice();
        assertEq(_countLogs(vm.getRecordedLogs(), OracleAdapter.OracleRecovered.selector), 0);
    }

    function test_failureBeforeAnyGoodPriceReturnsZero() public {
        feed.setMode(MockAggregator.Mode.Revert);
        (uint256 p, bool u) = oracle.fetchPrice();
        assertFalse(u);
        assertEq(p, 0);
        assertEq(oracle.lastGoodPrice(), 0);
    }

    function test_peek_writesNothingAndEmitsNothing() public {
        feed.setMode(MockAggregator.Mode.Revert);
        vm.recordLogs();
        vm.record();
        oracle.peek();
        (, bytes32[] memory writes) = vm.accesses(address(oracle));
        assertEq(writes.length, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(oracle.failureStart(), 0);
    }

    // ------------------------------------------------------------------ gas rule, direct

    /// @dev A feed that burns more than ORACLE_GAS fails for every caller: a genuine failure, recorded.
    function test_gasRule_genuineOutOfGasIsRecordedWithEnoughCallerGas() public {
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(ORACLE_GAS * 2);
        _assertUnusable(OracleAdapter.Reason.PRICE_CALL_FAILED);
        seq.setMode(MockAggregator.Mode.BurnGas);
        seq.setGasToBurn(ORACLE_GAS * 2);
        _assertUnusable(OracleAdapter.Reason.SEQUENCER_CALL_FAILED);
    }

    function test_gasRule_starvedCallReverts() public {
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(60_000);
        // enough for the sequencer read, not for the price feed's 60k
        vm.expectRevert(OracleAdapter.InsufficientGasForOracle.selector);
        oracle.fetchPrice{gas: 55_000}();
        assertEq(oracle.failureStart(), 0);
    }

    /// @dev peek has no gas rule (§5.7). With a high ORACLE_POST_FAILURE_GAS and a feed that
    ///      genuinely fails (it needs more than ORACLE_GAS), there is a caller gas limit at which
    ///      fetchPrice refuses — the rule is conservative: it cannot tell a genuine failure from a
    ///      starved one, so it asks for more gas — while peek at the same limit still answers.
    function test_gasRule_peekHasNone() public {
        oracle = new OracleAdapter(
            address(feed), address(seq), STALENESS, GRACE, MIN_PRICE, MAX_PRICE, ORACLE_GAS, 40_000
        );
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(ORACLE_GAS * 2);
        // the largest limit at which fetchPrice still refuses: peek gets the most headroom there
        // (it must also hold without the optimizer, as under `forge coverage`)
        uint256 last;
        for (uint256 g = 100_000; g < 250_000; g += 250) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) =
                address(oracle).call{gas: g}(abi.encodeCall(OracleAdapter.fetchPrice, ()));
            vm.revertToState(snap); // a successful probe records the (genuine) failure: undo it
            if (ok) break; // enough gas from here on
            if (ret.length == 4 && bytes4(ret) == OracleAdapter.InsufficientGasForOracle.selector) last = g;
        }
        assertGt(last, 0, "a limit where only the gas rule differs");
        (, bool usable, OracleAdapter.Reason r) = oracle.peek{gas: last}();
        assertFalse(usable);
        assertEq(_reason(r), _reason(OracleAdapter.Reason.PRICE_CALL_FAILED));
        assertEq(oracle.failureStart(), 0);
    }
}
