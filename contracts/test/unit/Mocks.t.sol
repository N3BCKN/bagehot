// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../../src/mocks/MockSequencerFeed.sol";
import {RawFeed} from "../../src/mocks/RawFeed.sol";
import {ReplayAggregator} from "../../src/mocks/ReplayAggregator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The test feeds behave as P12's oracle tests will rely on: each failure mode produces
///         exactly the kind of failed call spec §6.10.1 names (revert, out of gas, < 160 bytes).
contract MockAggregatorTest is Test {
    MockAggregator internal feed;

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockAggregator(8);
    }

    /// @dev A capped staticcall of latestRoundData, as OracleAdapter will make it.
    function _read(address f, uint256 gasCap) internal view returns (bool ok, uint256 len) {
        bytes memory ret;
        (ok, ret) = f.staticcall{gas: gasCap}(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        len = ret.length;
    }

    function test_normal_returnsTheStoredRound() public {
        feed.setRound(7, 3000e8, 1_699_999_000);
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) = feed.latestRoundData();
        assertEq(r, 7);
        assertEq(a, 3000e8);
        assertEq(s, 1_699_999_000);
        assertEq(u, 1_699_999_000);
        assertEq(air, 7);
        assertEq(feed.decimals(), 8);
        (r,,,,) = feed.getRoundData(123); // any id: the mock has one round
        assertEq(r, 7);
        assertEq(feed.version(), 0);
        assertEq(feed.description(), "MockAggregator (test only)");
    }

    function test_setters() public {
        feed.setAnswer(-5);
        (uint80 r, int256 a, uint256 s, uint256 u,) = feed.latestRoundData();
        assertEq(r, 1);
        assertEq(a, -5);
        assertEq(s, block.timestamp);
        assertEq(u, block.timestamp);
        feed.setUpdatedAt(0);
        feed.setStartedAt(type(uint256).max);
        (,, s, u,) = feed.latestRoundData();
        assertEq(s, type(uint256).max);
        assertEq(u, 0);
        (bool ok, uint256 len) = _read(address(feed), 100_000);
        assertTrue(ok);
        assertEq(len, 160);
    }

    function test_revertMode_revertsEveryRead() public {
        feed.setMode(MockAggregator.Mode.Revert);
        vm.expectRevert(MockAggregator.MockFeedReverted.selector);
        feed.latestRoundData();
        vm.expectRevert(MockAggregator.MockFeedReverted.selector);
        feed.getRoundData(1);
        vm.expectRevert(MockAggregator.MockFeedReverted.selector);
        feed.decimals();
        (bool ok,) = _read(address(feed), 100_000);
        assertFalse(ok);
    }

    /// @dev Burning more than the cap fails the call; burning less succeeds with full data.
    function test_burnGasMode_failsOnlyWhenTheBurnExceedsTheCap() public {
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(200_000);
        (bool ok,) = _read(address(feed), 100_000);
        assertFalse(ok);
        (bool ok2, uint256 len) = _read(address(feed), 400_000);
        assertTrue(ok2);
        assertEq(len, 160);
    }

    /// @dev The burn is real: the capped call consumes at least the configured amount.
    function test_burnGasMode_consumesTheConfiguredGas() public {
        feed.setMode(MockAggregator.Mode.BurnGas);
        feed.setGasToBurn(150_000);
        uint256 before = gasleft();
        (bool ok,) = _read(address(feed), 300_000);
        uint256 used = before - gasleft();
        assertTrue(ok);
        assertGe(used, 150_000);
    }
}

contract RawFeedTest is Test {
    RawFeed internal raw;

    function setUp() public {
        raw = new RawFeed();
    }

    function _call(bytes memory data) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(raw).staticcall(data);
    }

    function test_returnsThePayloadUnencodedForAnySelector() public {
        raw.setPayload(abi.encode(uint256(7)));
        (bool ok, bytes memory ret) = _call(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 7);
        (ok, ret) = _call(abi.encodeCall(AggregatorV3Interface.decimals, ()));
        assertTrue(ok);
        assertEq(ret.length, 32);
        raw.setPayload(hex"");
        (ok, ret) = _call(hex"feaf968c");
        assertTrue(ok);
        assertEq(ret.length, 0);
    }

    function test_oddLengthsAndJunkWordsAreReturnedVerbatim() public {
        raw.setPayload(new bytes(159));
        (, bytes memory ret) = _call(hex"feaf968c");
        assertEq(ret.length, 159);
        bytes memory junk =
            abi.encode(type(uint256).max, int256(2000e8), uint256(1), uint256(2), type(uint256).max);
        raw.setPayload(junk);
        (, ret) = _call(hex"feaf968c");
        assertEq(keccak256(ret), keccak256(junk));
    }

    function test_zeroPayloadAndRevertMode() public {
        raw.setZeroPayload(150_000);
        assertEq(raw.payload().length, 150_000);
        (bool ok, bytes memory ret) = _call(hex"feaf968c");
        assertTrue(ok);
        assertEq(ret.length, 150_000);
        raw.setPayload(hex"aa");
        raw.setReverts(true);
        assertTrue(raw.reverts());
        (ok, ret) = _call(hex"feaf968c");
        assertFalse(ok);
        assertEq(keccak256(ret), keccak256(abi.encodeWithSelector(RawFeed.RawFeedReverted.selector, hex"aa")));
    }
}

contract MockSequencerFeedTest is Test {
    MockSequencerFeed internal seq;

    function setUp() public {
        vm.warp(1_700_000_000);
        seq = new MockSequencerFeed();
    }

    function test_statusAndStartedAt() public {
        assertEq(seq.decimals(), 0);
        seq.setStatus(0, 1_699_990_000);
        (uint80 r, int256 a, uint256 s, uint256 u,) = seq.latestRoundData();
        assertEq(r, 1);
        assertEq(a, 0);
        assertEq(s, 1_699_990_000);
        assertEq(u, 1_699_990_000);
        seq.setStatus(1, 1_700_000_000);
        (r, a, s,,) = seq.latestRoundData();
        assertEq(r, 2);
        assertEq(a, 1);
        assertEq(s, 1_700_000_000);
        seq.setStatus(2, 0); // values outside {0,1} and a zero startedAt are allowed on purpose
        (, a, s,,) = seq.latestRoundData();
        assertEq(a, 2);
        assertEq(s, 0);
    }

    function test_inheritsTheFailureModes() public {
        seq.setMode(MockAggregator.Mode.Revert);
        vm.expectRevert(MockAggregator.MockFeedReverted.selector);
        seq.latestRoundData();
    }
}

contract ReplayAggregatorTest is Test {
    ReplayAggregator internal feed;

    address internal constant OPERATOR = address(0x0FE);
    uint256 internal constant BPS = 15; // Base ETH/USD: 0.15 %
    uint256 internal constant HEARTBEAT = 1200;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new ReplayAggregator(OPERATOR, 8, BPS, HEARTBEAT);
    }

    function _push(int256 answer) internal returns (bool) {
        vm.prank(OPERATOR);
        return feed.push(answer);
    }

    function test_constructor() public view {
        assertEq(feed.operator(), OPERATOR);
        assertEq(feed.decimals(), 8);
        assertEq(feed.DEVIATION_BPS(), BPS);
        assertEq(feed.HEARTBEAT(), HEARTBEAT);
        assertEq(feed.latestRound(), 0);
        assertEq(feed.version(), 0);
        assertEq(feed.description(), "ReplayAggregator (demo/test oracle, not a real price source)");
    }

    function test_constructor_rejectsEachBadArgument() public {
        vm.expectRevert(abi.encodeWithSelector(ReplayAggregator.InvalidReplayParameter.selector, uint8(0)));
        new ReplayAggregator(address(0), 8, BPS, HEARTBEAT);
        vm.expectRevert(abi.encodeWithSelector(ReplayAggregator.InvalidReplayParameter.selector, uint8(1)));
        new ReplayAggregator(OPERATOR, 19, BPS, HEARTBEAT);
        vm.expectRevert(abi.encodeWithSelector(ReplayAggregator.InvalidReplayParameter.selector, uint8(2)));
        new ReplayAggregator(OPERATOR, 8, 0, HEARTBEAT);
        vm.expectRevert(abi.encodeWithSelector(ReplayAggregator.InvalidReplayParameter.selector, uint8(2)));
        new ReplayAggregator(OPERATOR, 8, 10_001, HEARTBEAT);
        vm.expectRevert(abi.encodeWithSelector(ReplayAggregator.InvalidReplayParameter.selector, uint8(3)));
        new ReplayAggregator(OPERATOR, 8, BPS, 0);
        // the boundaries are accepted
        new ReplayAggregator(OPERATOR, 18, 10_000, 1);
        new ReplayAggregator(OPERATOR, 0, 1, 1);
    }

    function test_noDataBeforeTheFirstPush() public {
        vm.expectRevert(ReplayAggregator.NoDataPresent.selector);
        feed.latestRoundData();
        vm.expectRevert(ReplayAggregator.NoDataPresent.selector);
        feed.getRoundData(1);
    }

    function testFuzz_onlyOperatorPushes(address caller) public {
        vm.prank(caller);
        if (caller == OPERATOR) {
            assertTrue(feed.push(1));
            return;
        }
        vm.expectRevert(ReplayAggregator.NotOperator.selector);
        feed.push(1);
    }

    function test_nonPositiveAnswerReverts() public {
        vm.startPrank(OPERATOR);
        vm.expectRevert(ReplayAggregator.NonPositiveAnswer.selector);
        feed.push(0);
        vm.expectRevert(ReplayAggregator.NonPositiveAnswer.selector);
        feed.push(-1);
        vm.stopPrank();
    }

    function test_firstPushRecordsAndEmits() public {
        vm.expectEmit(address(feed));
        emit AnswerUpdated(3000e8, 1, block.timestamp);
        assertTrue(_push(3000e8));
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) = feed.latestRoundData();
        assertEq(r, 1);
        assertEq(a, 3000e8);
        assertEq(s, block.timestamp);
        assertEq(u, block.timestamp);
        assertEq(air, 1);
    }

    /// @dev 0.15 % of 3,000e8 is exactly 4.5e8: a move of 4.5e8 records, 4.5e8 − 1 does not, both ways.
    function test_deviationThresholdIsExactAtTheBoundary() public {
        _push(3000e8);
        assertFalse(_push(3000e8 + 4.5e8 - 1));
        assertFalse(_push(3000e8 - 4.5e8 + 1));
        assertEq(feed.latestRound(), 1);
        assertTrue(_push(3000e8 + 4.5e8));
        assertEq(feed.latestRound(), 2);
        // threshold is relative to the last *recorded* answer (3,004.5e8): 0.15 % = 4.50675e8
        assertFalse(_push(3004.5e8 - 4.50675e8 + 1));
        assertTrue(_push(3004.5e8 - 4.50675e8));
        assertEq(feed.latestRound(), 3);
    }

    function test_ignoredPushLeavesTheLastRoundAndEmitsNothing() public {
        _push(3000e8);
        vm.warp(block.timestamp + 60);
        vm.recordLogs();
        assertFalse(_push(3000e8 + 1));
        assertEq(vm.getRecordedLogs().length, 0);
        (, int256 a,, uint256 u,) = feed.latestRoundData();
        assertEq(a, 3000e8);
        assertEq(u, block.timestamp - 60);
    }

    function test_heartbeatRecordsAnUnchangedAnswerExactlyWhenDue() public {
        _push(3000e8);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + HEARTBEAT - 1);
        assertFalse(_push(3000e8));
        vm.warp(t0 + HEARTBEAT);
        assertTrue(_push(3000e8));
        (uint80 r,,, uint256 u,) = feed.latestRoundData();
        assertEq(r, 2);
        assertEq(u, t0 + HEARTBEAT);
    }

    function test_getRoundDataKeepsHistory() public {
        _push(3000e8);
        vm.warp(block.timestamp + 10);
        _push(2000e8);
        (uint80 r, int256 a,, uint256 u,) = feed.getRoundData(1);
        assertEq(r, 1);
        assertEq(a, 3000e8);
        assertEq(u, block.timestamp - 10);
        (r, a,,,) = feed.getRoundData(2);
        assertEq(r, 2);
        assertEq(a, 2000e8);
        vm.expectRevert(ReplayAggregator.NoDataPresent.selector);
        feed.getRoundData(0);
        vm.expectRevert(ReplayAggregator.NoDataPresent.selector);
        feed.getRoundData(3);
    }

    /// @dev For integers, |Δ|/last ≥ bps/10_000 ⟺ |Δ| ≥ ceil(bps·last / 10_000): an independent
    ///      statement of the rule the contract evaluates by cross-multiplication. Large answers
    ///      cannot overflow it.
    function testFuzz_deviationRuleMatchesTheRationalDefinition(uint128 last, uint128 next) public {
        last = uint128(bound(last, 1, type(uint128).max));
        next = uint128(bound(next, 1, type(uint128).max));
        _push(int256(uint256(last)));
        uint256 d = next > last ? next - last : last - next;
        bool expected = d >= Math.ceilDiv(BPS * uint256(last), 10_000);
        assertEq(_push(int256(uint256(next))), expected);
    }
}
