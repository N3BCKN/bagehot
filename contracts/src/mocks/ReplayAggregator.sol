// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title ReplayAggregator
/// @notice DEMO / TEST ORACLE — never a source of real prices. A Chainlink-shaped feed for the
///         `fork_replay` environment (docs/preregistration.md): an immutable `operator` pushes a
///         recorded or simulated price path, and a push becomes a new round only under Chainlink's
///         own update rule — the answer moved by at least the deviation threshold, or the heartbeat
///         has elapsed since the last round. Otherwise the push is ignored and the feed keeps
///         reporting the previous round, exactly as the real feed would.
/// @dev Deviation test by exact cross-multiplication, no division:
///      `|answer − last| · 10_000 ≥ DEVIATION_BPS · last`. Answers must be positive (a recorded
///      ETH/USD path always is), which keeps the subtraction and products far from overflow.
///      `updatedAt = startedAt = block.timestamp` of the push: the replay driver warps time to the
///      recorded update times. The first push always records.
contract ReplayAggregator is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    address public immutable operator;
    uint8 internal immutable _decimals;
    uint256 public immutable DEVIATION_BPS;
    uint256 public immutable HEARTBEAT;

    uint80 public latestRound;
    mapping(uint80 => Round) internal _rounds;

    /// @notice Chainlink's AggregatorInterface event, emitted for every recorded round.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    error NotOperator();
    error NonPositiveAnswer();
    error NoDataPresent();
    error InvalidReplayParameter(uint8 index);

    /// @param operator_ the only address allowed to push.
    /// @param decimals_ feed decimals (8 for ETH/USD); at most 18, as spec §3.3 requires of a feed.
    /// @param deviationBps_ deviation threshold in basis points, 1 ≤ x ≤ 10_000.
    /// @param heartbeat_ seconds after which any push records, > 0.
    constructor(address operator_, uint8 decimals_, uint256 deviationBps_, uint256 heartbeat_) {
        if (operator_ == address(0)) revert InvalidReplayParameter(0);
        if (decimals_ > 18) revert InvalidReplayParameter(1);
        if (deviationBps_ == 0 || deviationBps_ > 10_000) revert InvalidReplayParameter(2);
        if (heartbeat_ == 0) revert InvalidReplayParameter(3);
        operator = operator_;
        _decimals = decimals_;
        DEVIATION_BPS = deviationBps_;
        HEARTBEAT = heartbeat_;
    }

    /// @notice Offers a new answer. Returns whether it was recorded as a new round.
    function push(int256 answer) external returns (bool recorded) {
        if (msg.sender != operator) revert NotOperator();
        if (answer <= 0) revert NonPositiveAnswer();
        uint80 r = latestRound;
        if (r != 0) {
            Round memory last = _rounds[r];
            uint256 a = uint256(answer);
            uint256 l = uint256(last.answer);
            uint256 delta = a > l ? a - l : l - a;
            bool deviated = delta * 10_000 >= DEVIATION_BPS * l;
            bool heartbeat = block.timestamp - last.updatedAt >= HEARTBEAT;
            if (!deviated && !heartbeat) return false;
        }
        r += 1;
        latestRound = r;
        _rounds[r] = Round(answer, block.timestamp);
        emit AnswerUpdated(answer, r, block.timestamp);
        return true;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "ReplayAggregator (demo/test oracle, not a real price source)";
    }

    function version() external pure override returns (uint256) {
        return 0;
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        if (roundId == 0 || roundId > latestRound) revert NoDataPresent();
        return _round(roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (latestRound == 0) revert NoDataPresent();
        return _round(latestRound);
    }

    function _round(uint80 r) internal view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory x = _rounds[r];
        return (r, x.answer, x.updatedAt, x.updatedAt, r);
    }
}
