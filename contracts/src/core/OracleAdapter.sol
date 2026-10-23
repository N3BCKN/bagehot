// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {InvalidParameter} from "../lib/Errors.sol";
import {Rounding} from "../lib/Rounding.sol";

/// @title OracleAdapter
/// @notice Turns one Chainlink price feed plus the L2 sequencer uptime feed into a WAD price and a
///         `usable` flag (docs/spec.md §4.8, §5.7, §6.10). It fails safe: any doubt — a failed
///         call, sequencer down or restarting, a non-positive, future, stale or out-of-bounds
///         answer — reports "unusable", and operations that need a price revert `PriceUnusable`
///         in their own contract (§7). A caller cannot fake a failure by starving a feed call of
///         gas, even through a proxy: that reverts `InsufficientGasForOracle` instead (§6.10.3,
///         threat T-03, ADR-0030).
/// @dev No `wire`, no owner, no lock: the adapter holds no tokens and only `staticcall`s the two
///      immutable feeds, each with gas `ORACLE_GAS`. The single assembly block is the feed read,
///      approved by ADR-0029. Nothing else in this contract is privileged or mutable except the
///      two informational fields below.
contract OracleAdapter {
    /// @notice Decision reasons; numeric values are part of the ABI (spec §11.1). `OK` = 0.
    enum Reason {
        OK,
        SEQUENCER_CALL_FAILED,
        SEQUENCER_DOWN,
        SEQUENCER_INVALID,
        GRACE_PERIOD,
        PRICE_CALL_FAILED,
        NON_POSITIVE,
        INVALID_TIMESTAMP,
        STALE,
        OUT_OF_BOUNDS
    }

    /// @notice `priceFeed.decimals()` failed, returned fewer than 32 bytes, or exceeds 18.
    error InvalidFeedDecimals();
    /// @notice A feed call failed and less than `ORACLE_POST_FAILURE_GAS` gas is left (§6.10.3).
    error InsufficientGasForOracle();

    event LastGoodPriceUpdated(uint256 price);
    event OracleFailure(uint8 reason, uint256 timestamp);
    event OracleRecovered(uint256 timestamp);

    /// @notice Ranges of spec §3.1 / §3.4 checked by the constructor.
    uint256 public constant MIN_PRICE_FLOOR = 2e18;
    uint256 public constant MAX_PRICE_CEILING = 1e30;
    uint256 public constant MIN_ORACLE_GAS = 50_000;
    uint256 public constant MAX_ORACLE_GAS = 1_000_000;
    /// @notice A WAD has 18 decimals; a feed may have at most as many (spec §3.3, constraint 4).
    uint256 public constant MAX_FEED_DECIMALS = 18;
    /// @dev EIP-150: a call forwards at most 63/64 of the gas left. A feed call starved by its caller
    ///      leaves the adapter less than ORACLE_GAS/63 of its own, plus less than ORACLE_GAS/63
    ///      handed back by any chain of bubbling calls inside the feed (a Chainlink proxy returns the
    ///      1/64 it kept) — so the floor is ceil(2·ORACLE_GAS/63) (spec §6.10.3, ADR-0030).
    uint256 internal constant CALL_GAS_DIVISOR = 63;

    AggregatorV3Interface public immutable priceFeed;
    AggregatorV3Interface public immutable sequencerFeed;
    uint8 public immutable FEED_DECIMALS;
    uint256 public immutable STALENESS;
    uint256 public immutable GRACE_PERIOD;
    uint256 public immutable MIN_PRICE;
    uint256 public immutable MAX_PRICE;
    uint256 public immutable ORACLE_GAS;
    uint256 public immutable ORACLE_POST_FAILURE_GAS;

    /// @dev 10^(18 − FEED_DECIMALS): feed answer → WAD.
    uint256 internal immutable _scale;
    /// @dev floor(MAX_PRICE / _scale): the largest answer whose scaled value is ≤ MAX_PRICE, so the
    ///      upper bound is tested before scaling and the multiplication cannot overflow (§6.10.1).
    uint256 internal immutable _maxAnswer;

    /// @notice WAD; the last usable price, 0 until the first. Informational — never used in a
    ///         state-changing decision (§4.8).
    uint256 public lastGoodPrice;
    /// @notice Timestamp of the first unusable `fetchPrice` since the last usable one; 0 while the
    ///         last read was usable. ShutdownModule's oracle-failure clock (§6.11.1).
    uint256 public failureStart;

    /// @dev Arguments are checked in order, first failure wins (§3.4); then `decimals()` is read.
    constructor(
        address priceFeed_,
        address sequencerFeed_,
        uint256 staleness,
        uint256 gracePeriod,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 oracleGas,
        uint256 oraclePostFailureGas
    ) {
        if (priceFeed_ == address(0)) revert InvalidParameter(0);
        if (sequencerFeed_ == address(0)) revert InvalidParameter(1);
        if (staleness == 0) revert InvalidParameter(2);
        // 3: GRACE_PERIOD — any value
        if (minPrice < MIN_PRICE_FLOOR) revert InvalidParameter(4);
        if (maxPrice <= minPrice || maxPrice > MAX_PRICE_CEILING) revert InvalidParameter(5);
        if (oracleGas < MIN_ORACLE_GAS || oracleGas > MAX_ORACLE_GAS) revert InvalidParameter(6);
        if (
            oraclePostFailureGas < Rounding.divUp(2 * oracleGas, CALL_GAS_DIVISOR)
                || oraclePostFailureGas > oracleGas
        ) {
            revert InvalidParameter(7);
        }

        (bool ok, bytes memory ret) =
            priceFeed_.staticcall(abi.encodeCall(AggregatorV3Interface.decimals, ()));
        if (!ok || ret.length < 32) revert InvalidFeedDecimals();
        uint256 decimals = abi.decode(ret, (uint256)); // full word: junk above 18 is rejected, not decoded
        if (decimals > MAX_FEED_DECIMALS) revert InvalidFeedDecimals();

        priceFeed = AggregatorV3Interface(priceFeed_);
        sequencerFeed = AggregatorV3Interface(sequencerFeed_);
        FEED_DECIMALS = uint8(decimals);
        STALENESS = staleness;
        GRACE_PERIOD = gracePeriod;
        MIN_PRICE = minPrice;
        MAX_PRICE = maxPrice;
        ORACLE_GAS = oracleGas;
        ORACLE_POST_FAILURE_GAS = oraclePostFailureGas;
        uint256 scale = 10 ** (MAX_FEED_DECIMALS - decimals);
        _scale = scale;
        _maxAnswer = Rounding.mulDivDown(maxPrice, 1, scale); // floor, exact for the bound test
    }

    /// @notice The current price decision, recording it (§6.10.2). Callable by anyone.
    /// @return price the WAD price if usable, else `lastGoodPrice`
    /// @return usable whether `price` may be used for a decision
    /// @dev Updates `lastGoodPrice` and the failure clock and emits on each change only. Reverts
    ///      `InsufficientGasForOracle` if a feed call failed with too little gas left (§6.10.3).
    function fetchPrice() external returns (uint256 price, bool usable) {
        (bool ok, uint256 p, Reason reason) = _decide(true);
        if (ok) {
            if (p != lastGoodPrice) {
                lastGoodPrice = p;
                emit LastGoodPriceUpdated(p);
            }
            if (failureStart != 0) {
                failureStart = 0;
                emit OracleRecovered(block.timestamp);
            }
            return (p, true);
        }
        if (failureStart == 0) {
            failureStart = block.timestamp;
            emit OracleFailure(uint8(reason), block.timestamp);
        }
        return (lastGoodPrice, false);
    }

    /// @notice The same decision as `fetchPrice` without writing state and without the gas rule,
    ///         for bots and UIs (§5.7). `price = lastGoodPrice` when not usable.
    function peek() external view returns (uint256 price, bool usable, Reason reason) {
        uint256 p;
        (usable, p, reason) = _decide(false);
        price = usable ? p : lastGoodPrice;
    }

    /// @dev The decision table of §6.10.1, first matching row wins. Feeds are read lazily: the
    ///      price feed only once rows 1–4 did not decide (§6.10.2).
    function _decide(bool gasRule) internal view returns (bool usable, uint256 price, Reason reason) {
        (bool ok, int256 answer, uint256 startedAt, uint256 updatedAt) = _readFeed(sequencerFeed, gasRule);
        if (!ok) return (false, 0, Reason.SEQUENCER_CALL_FAILED);
        if (answer != 0) return (false, 0, Reason.SEQUENCER_DOWN);
        if (startedAt == 0 || startedAt > block.timestamp) return (false, 0, Reason.SEQUENCER_INVALID);
        if (block.timestamp - startedAt <= GRACE_PERIOD) return (false, 0, Reason.GRACE_PERIOD);

        (ok, answer,, updatedAt) = _readFeed(priceFeed, gasRule);
        if (!ok) return (false, 0, Reason.PRICE_CALL_FAILED);
        if (answer <= 0) return (false, 0, Reason.NON_POSITIVE);
        if (updatedAt == 0 || updatedAt > block.timestamp) return (false, 0, Reason.INVALID_TIMESTAMP);
        if (block.timestamp - updatedAt > STALENESS) return (false, 0, Reason.STALE);
        uint256 a = uint256(answer); // answer > 0
        if (a > _maxAnswer) return (false, 0, Reason.OUT_OF_BOUNDS);
        price = a * _scale; // a ≤ MAX_PRICE / _scale, so price ≤ MAX_PRICE ≤ 1e30: no overflow
        if (price < MIN_PRICE) return (false, 0, Reason.OUT_OF_BOUNDS);
        return (true, price, Reason.OK);
    }

    /// @dev One `latestRoundData()` read (ADR-0029). `staticcall` with gas `ORACLE_GAS` into a fixed
    ///      160-byte buffer at the free-memory pointer, which is used as scratch and not advanced.
    ///      `ok` requires success and `returndatasize() ≥ 160` (§6.10.1). Return or revert data
    ///      beyond 160 bytes is never copied, so a feed cannot make the caller pay for it, and the
    ///      code between the call and the gas rule does not depend on anything the feed returns.
    ///      Words 1–3 (answer, startedAt, updatedAt) are read as full 256-bit values; words 0 and 4
    ///      (`roundId`, `answeredInRound`) are never read, so junk in them is harmless.
    ///      After a failed call, with `gasRule`, too little gas left means the caller starved the
    ///      call: revert rather than report a failure that did not happen (§6.10.3).
    function _readFeed(AggregatorV3Interface feed, bool gasRule)
        internal
        view
        returns (bool ok, int256 answer, uint256 startedAt, uint256 updatedAt)
    {
        uint256 gasCap = ORACLE_GAS;
        bytes4 selector = AggregatorV3Interface.latestRoundData.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gasCap, feed, ptr, 4, ptr, 160)
            ok := and(ok, iszero(lt(returndatasize(), 160)))
            if ok {
                answer := mload(add(ptr, 0x20))
                startedAt := mload(add(ptr, 0x40))
                updatedAt := mload(add(ptr, 0x60))
            }
        }
        if (!ok && gasRule && gasleft() < ORACLE_POST_FAILURE_GAS) revert InsufficientGasForOracle();
    }
}
