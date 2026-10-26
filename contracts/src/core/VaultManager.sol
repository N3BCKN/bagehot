// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {ISortKeySource} from "../interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../interfaces/ISortedPositions.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {
    IAuctionHouseViews,
    IDeficitLedgerDeficit,
    IDeficitLedgerInterest,
    IDeficitLedgerViews,
    ILiquidationStrategy,
    IStabilityPoolInterest
} from "../interfaces/ISystemViews.sol";
import {
    AlreadySettled,
    InsufficientBalance,
    InvalidParameter,
    NotSettled,
    NotTriggered,
    PriceUnusable,
    SystemSettled,
    SystemShutdown,
    Unauthorized,
    ZeroAmount
} from "../lib/Errors.sol";
import {Rounding} from "../lib/Rounding.sol";
import {WadRayMath} from "../lib/WadRayMath.sol";
import {WiredBase} from "../lib/Wired.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultManager
/// @notice Holds every position's WETH collateral and gas reserve and mints the stablecoin against
///         it (docs/spec.md §4.2, §5.1). Positions — open, add / withdraw collateral, borrow, repay,
///         close (P14); interest accrual and its routing to the pool and the reserve (P15, §6.2,
///         ADR-0033); the redemption loop (P16, §6.7.3); liquidation through the strategy with
///         redistribution of the remainder or, with no stakes left, a deficit (P20, §6.4, §6.5); the
///         shutdown hooks and the views.
///      Every operation follows the spec's order: checks (in pseudocode order), fetch price where
///      required (§7), accrue, apply pending, act, update stake, reinsert, token transfers, events.
///      One transient lock guards every state-changing external function (§2.5, §5.10).
///      Every ratio decision is an exact cross-multiplication (§2.2); divisions use `Rounding` with
///      the direction of the rounding table (§8).
contract VaultManager is ISortKeySource, WiredBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types, errors, events

    enum Status {
        None,
        Active,
        ClosedByOwner,
        ClosedByRedemption,
        ClosedByLiquidation,
        ClosedByShutdown
    }

    /// @dev The arguments of one `redeemCollateral` call, kept together to bound the stack.
    struct Redemption {
        uint256 amount;
        uint256 feeRate;
        uint256 price;
        uint256 maxIterations;
        uint256 upperHint;
        uint256 lowerHint;
    }

    struct Position {
        address owner;
        uint256 coll;
        uint256 normDebt;
        uint256 stake;
        uint256 snapLColl;
        uint256 snapLDebt;
        Status status;
    }

    error NotOwner();
    error PositionNotActive();
    error DebtBelowMinimum();
    error IcrBelowMcr();
    error InsufficientCollateral();
    error RepayExceedsMaximum();
    error CollateralTooLarge();
    /// @notice The pool's `onInterest` call failed and less than `ceil(2·POOL_HOOK_GAS / 63)` gas is
    ///         left: the caller may have starved it on purpose (§6.2, ADR-0033).
    error InsufficientGasForPoolHook();
    error NotLiquidatable();
    /// @notice The strategy reported absorbing more debt than the position had (§6.4.1, CHG-012).
    error DebtAbsorbedExceedsDebt();
    /// @notice The strategy reported returning more collateral than it received (§6.4.1, CHG-012).
    error CollReturnedExceedsColl();

    event PositionOpened(uint256 indexed id, address indexed owner, uint256 debtMinted);
    event PositionUpdated(
        uint256 indexed id,
        uint256 coll,
        uint256 normDebt,
        uint256 stake,
        uint256 snapLColl,
        uint256 snapLDebt,
        uint8 status,
        uint8 op
    );
    event RewardsApplied(uint256 indexed id, uint256 collReward, uint256 normReward);
    event CollateralAdded(uint256 indexed id, address indexed from, uint256 amount);
    event CollateralWithdrawn(uint256 indexed id, uint256 amount);
    event Borrowed(uint256 indexed id, uint256 amount, uint256 normDelta);
    event Repaid(uint256 indexed id, address indexed from, uint256 amount, uint256 normDelta);
    event PositionClosed(
        uint256 indexed id, uint256 debtBurned, uint256 collReturned, uint256 gasReserveReturned
    );
    event PositionRedeemed(
        uint256 indexed id, uint256 debtRedeemed, uint256 collToRedeemer, uint256 surplusToOwner, bool closed
    );
    event GasReserveReclaimed(uint256 indexed id, address indexed owner, uint256 amount);
    event VaultShutdown(uint256 index);
    event VaultSettled(uint256 collToClaimPool, uint256 activePositions);
    event InterestAccrued(
        uint256 index, uint256 interest, uint256 toPool, uint256 toReserve, uint256 timestamp
    );
    /// @notice The pool's offered interest share went to the reserve because its `onInterest` call
    ///         failed (§6.2, ADR-0033).
    event PoolInterestRedirected(uint256 amount);
    event Liquidated(
        uint256 indexed id,
        address indexed owner,
        address indexed liquidator,
        uint256 debt,
        uint256 coll,
        uint256 debtAbsorbed,
        uint256 collRemainder,
        uint256 normRemainder,
        uint8 remainderPath,
        uint256 gasCompensation
    );
    event Redistributed(
        uint256 coll,
        uint256 normDebt,
        uint256 LColl,
        uint256 LDebt,
        uint256 errorColl,
        uint256 errorDebt,
        uint256 totalStakes
    );
    event SystemSnapshotsUpdated(uint256 totalStakesSnapshot, uint256 totalCollateralSnapshot);

    // ------------------------------------------------------------------ constants

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    /// @notice Precision of the redistribution accumulators (§2.1).
    uint256 public constant DECIMAL_PRECISION = 1e18;
    /// @notice Display precision of the `nicr` view only (§2.1).
    uint256 public constant NICR_PRECISION = 1e20;
    /// @notice A position's stored collateral never exceeds this (§6.3.1, `CollateralTooLarge`).
    uint256 public constant COLL_CAP = type(uint128).max;
    /// @notice Ranges of spec §3.1 / §3.4 checked by the constructor.
    uint256 public constant MAX_MCR = 2 * WAD;
    uint256 public constant MIN_MIN_DEBT = 1e18;
    uint256 public constant MAX_RATE_PER_SECOND = 21_979_553_151_239_153_028; // ANNUAL_RATE = 1.0
    /// @notice ≥ 2 × the pool's measured worst-case `onInterest` (86,981 gas), CHG-006's rule (CHG-013).
    uint256 public constant MIN_POOL_HOOK_GAS = 175_000;
    uint256 public constant MAX_POOL_HOOK_GAS = 1_000_000;

    uint8 internal constant OP_OPEN = 1;
    uint8 internal constant OP_ADD_COLLATERAL = 2;
    uint8 internal constant OP_WITHDRAW_COLLATERAL = 3;
    uint8 internal constant OP_BORROW = 4;
    uint8 internal constant OP_REPAY = 5;
    uint8 internal constant OP_CLOSE = 6;
    uint8 internal constant OP_REDEEM = 7;
    uint8 internal constant OP_LIQUIDATE = 8;
    /// @notice `Liquidated.remainderPath` (§11.1).
    uint8 internal constant PATH_NONE = 0;
    uint8 internal constant PATH_REDISTRIBUTED = 1;
    uint8 internal constant PATH_DEFICIT = 2;

    // ------------------------------------------------------------------ immutables

    IERC20 public immutable WETH;
    IStableToken public immutable token;
    IOracleAdapter public immutable oracle;
    uint256 public immutable MCR;
    uint256 public immutable MIN_DEBT;
    uint256 public immutable GAS_RESERVE;
    uint256 public immutable RATE_PER_SECOND;
    uint256 public immutable POOL_SHARE_BPS;
    /// @notice Gas forwarded to the pool's `onInterest` (§3.1, ADR-0033).
    uint256 public immutable POOL_HOOK_GAS;
    /// @notice `ceil(2·POOL_HOOK_GAS / 63)`: the least `gasleft()` after a failed pool call (§6.2).
    uint256 public immutable POOL_HOOK_FLOOR;

    // ------------------------------------------------------------------ storage (§4.2)

    mapping(uint256 => Position) internal _positions;
    uint256 public nextId = 1;
    uint256 public activeCount;
    uint256 public index = RAY;
    uint256 public lastAccrual;
    uint256 public totalNormDebt;
    uint256 public totalCollateral;
    uint256 public totalStakes;
    uint256 public totalStakesSnapshot;
    uint256 public totalCollateralSnapshot;
    uint256 public LColl;
    uint256 public LDebt;
    uint256 public pendingColl;
    uint256 public pendingNormDebt;
    /// @notice §6.5.2's error carries of the redistribution accumulators (R9).
    uint256 public lastErrorColl;
    uint256 public lastErrorDebt;
    bool public shutdown;
    bool public settled;

    // wired (§4.2)
    ISortedPositions public sorted;
    address public strategy;
    address public stabilityPool; // A: = strategy; B: address(0)
    address public redemptionModule;
    address public deficitLedger;
    address public shutdownModule;

    constructor(
        address weth_,
        address token_,
        address oracle_,
        uint256 mcr,
        uint256 minDebt,
        uint256 gasReserve,
        uint256 ratePerSecond,
        uint256 poolShareBps,
        uint256 poolHookGas
    ) {
        if (weth_ == address(0)) revert InvalidParameter(0);
        if (token_ == address(0)) revert InvalidParameter(1);
        if (oracle_ == address(0)) revert InvalidParameter(2);
        if (mcr <= WAD || mcr > MAX_MCR) revert InvalidParameter(3);
        if (minDebt < MIN_MIN_DEBT) revert InvalidParameter(4);
        if (gasReserve == 0) revert InvalidParameter(5);
        if (ratePerSecond > MAX_RATE_PER_SECOND) revert InvalidParameter(6);
        if (poolShareBps > BPS) revert InvalidParameter(7);
        if (poolHookGas < MIN_POOL_HOOK_GAS || poolHookGas > MAX_POOL_HOOK_GAS) revert InvalidParameter(8);
        WETH = IERC20(weth_);
        token = IStableToken(token_);
        oracle = IOracleAdapter(oracle_);
        MCR = mcr;
        MIN_DEBT = minDebt;
        GAS_RESERVE = gasReserve;
        RATE_PER_SECOND = ratePerSecond;
        POOL_SHARE_BPS = poolShareBps;
        POOL_HOOK_GAS = poolHookGas;
        POOL_HOOK_FLOOR = Rounding.divUp(2 * poolHookGas, 63);
        lastAccrual = block.timestamp;
    }

    /// @notice One-shot wiring (§3.4). `stabilityPool` is the strategy in deployment A and
    ///         `address(0)` in B, where `POOL_SHARE_BPS` must be 0 (§3.3 constraint 3).
    function wire(
        address sorted_,
        address strategy_,
        address stabilityPool_,
        address redemptionModule_,
        address deficitLedger_,
        address shutdownModule_
    ) external onlyWiring {
        _requireNonZero(sorted_, 0);
        _requireNonZero(strategy_, 1);
        if (stabilityPool_ != address(0) && stabilityPool_ != strategy_) revert InvalidParameter(2);
        if (stabilityPool_ == address(0) && POOL_SHARE_BPS != 0) revert InvalidParameter(2);
        _requireNonZero(redemptionModule_, 3);
        _requireNonZero(deficitLedger_, 4);
        _requireNonZero(shutdownModule_, 5);
        sorted = ISortedPositions(sorted_);
        strategy = strategy_;
        stabilityPool = stabilityPool_;
        redemptionModule = redemptionModule_;
        deficitLedger = deficitLedger_;
        shutdownModule = shutdownModule_;
        address[] memory addresses = new address[](6);
        (addresses[0], addresses[1], addresses[2]) = (sorted_, strategy_, stabilityPool_);
        (addresses[3], addresses[4], addresses[5]) = (redemptionModule_, deficitLedger_, shutdownModule_);
        _markWired(addresses);
    }

    // ------------------------------------------------------------------ positions (§5.1.1–5.1.6)

    /// @notice Opens a position for the caller: `coll` WETH plus `GAS_RESERVE` in, `debt` minted out.
    ///         Anyone; normal mode; price required (§5.1.1).
    /// @dev rounding: normalised debt R2 (up); debt R1 (up).
    function openPosition(uint256 coll, uint256 debt, uint256 upperHint, uint256 lowerHint)
        external
        whenWired
        nonReentrant
        returns (uint256 id)
    {
        if (shutdown) revert SystemShutdown();
        if (debt < MIN_DEBT) revert DebtBelowMinimum();
        if (coll > COLL_CAP) revert CollateralTooLarge();
        uint256 price = _fetchRequiredPrice();
        _accrue();
        uint256 n = Rounding.mulDivUp(debt, RAY, index);
        if (coll * price < MCR * _debtOf(n)) revert IcrBelowMcr();
        id = nextId;
        nextId = id + 1;
        uint256 stake = _computeStake(coll);
        _positions[id] = Position(msg.sender, coll, n, stake, LColl, LDebt, Status.Active);
        totalStakes += stake;
        totalCollateral += coll;
        totalNormDebt += n;
        activeCount += 1;
        sorted.insert(id, upperHint, lowerHint);
        WETH.safeTransferFrom(msg.sender, address(this), coll + GAS_RESERVE);
        token.mint(msg.sender, debt);
        emit PositionOpened(id, msg.sender, debt);
        _emitUpdated(id, OP_OPEN);
    }

    /// @notice Adds collateral to any position, paid by the caller. Anyone; normal or window mode;
    ///         no price (§5.1.2, I9).
    function addCollateral(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)
        external
        whenWired
        nonReentrant
    {
        if (settled) revert SystemSettled();
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        _accrue();
        _applyPending(id);
        if (p.coll + amount > COLL_CAP) revert CollateralTooLarge();
        p.coll += amount;
        totalCollateral += amount;
        _updateStake(id);
        sorted.reinsert(id, upperHint, lowerHint);
        WETH.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralAdded(id, msg.sender, amount);
        _emitUpdated(id, OP_ADD_COLLATERAL);
    }

    /// @notice Withdraws collateral to the owner, keeping ICR ≥ MCR. Owner; normal mode; price
    ///         required (§5.1.3).
    function withdrawCollateral(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)
        external
        whenWired
        nonReentrant
    {
        if (shutdown) revert SystemShutdown();
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        if (msg.sender != p.owner) revert NotOwner();
        uint256 price = _fetchRequiredPrice();
        _accrue();
        _applyPending(id);
        if (amount > p.coll) revert InsufficientCollateral();
        if ((p.coll - amount) * price < MCR * _debtOf(p.normDebt)) revert IcrBelowMcr();
        p.coll -= amount;
        totalCollateral -= amount;
        _updateStake(id);
        sorted.reinsert(id, upperHint, lowerHint);
        WETH.safeTransfer(p.owner, amount);
        emit CollateralWithdrawn(id, amount);
        _emitUpdated(id, OP_WITHDRAW_COLLATERAL);
    }

    /// @notice Mints `amount` more debt to the owner, keeping ICR ≥ MCR. Owner; normal mode; price
    ///         required (§5.1.4).
    /// @dev rounding: normalised debt added R2 (up).
    function borrow(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)
        external
        whenWired
        nonReentrant
    {
        if (shutdown) revert SystemShutdown();
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        if (msg.sender != p.owner) revert NotOwner();
        uint256 price = _fetchRequiredPrice();
        _accrue();
        _applyPending(id);
        uint256 dn = Rounding.mulDivUp(amount, RAY, index);
        if (p.coll * price < MCR * _debtOf(p.normDebt + dn)) revert IcrBelowMcr();
        p.normDebt += dn;
        totalNormDebt += dn;
        _updateStake(id);
        sorted.reinsert(id, upperHint, lowerHint);
        token.mint(p.owner, amount);
        emit Borrowed(id, amount, dn);
        _emitUpdated(id, OP_BORROW);
    }

    /// @notice Repays part of any position's debt from the caller's balance, never below
    ///         `MIN_DEBT` (full repayment is `close`). Anyone; normal or window mode; no price (§5.1.5).
    /// @dev rounding: normalised debt removed R3 (down) — may be 0 for a tiny amount, which favours
    ///      the protocol. `amount ≤ debt − MIN_DEBT` keeps `debtOf(normDebt − dn) ≥ MIN_DEBT`.
    function repay(uint256 id, uint256 amount, uint256 upperHint, uint256 lowerHint)
        external
        whenWired
        nonReentrant
    {
        if (settled) revert SystemSettled();
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        _accrue();
        _applyPending(id);
        // no underflow: an active position's debt is ≥ MIN_DEBT
        if (amount > _debtOf(p.normDebt) - MIN_DEBT) revert RepayExceedsMaximum();
        if (token.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        uint256 dn = Rounding.mulDivDown(amount, RAY, index);
        p.normDebt -= dn;
        totalNormDebt -= dn;
        _updateStake(id);
        sorted.reinsert(id, upperHint, lowerHint);
        token.burnFrom(msg.sender, amount);
        emit Repaid(id, msg.sender, amount, dn);
        _emitUpdated(id, OP_REPAY);
    }

    /// @notice Repays the whole debt from the owner's balance and returns collateral plus gas
    ///         reserve. Owner; normal or window mode; no price; allowed at any ICR (§5.1.6).
    /// @dev rounding: debt burned R1 (up) — exactly `debtOf(normDebt)`, so no dust can remain.
    function close(uint256 id) external whenWired nonReentrant {
        if (settled) revert SystemSettled();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        if (msg.sender != p.owner) revert NotOwner();
        _accrue();
        _applyPending(id);
        uint256 debt = _debtOf(p.normDebt);
        if (token.balanceOf(msg.sender) < debt) revert InsufficientBalance();
        sorted.remove(id);
        totalStakes -= p.stake;
        totalCollateral -= p.coll;
        totalNormDebt -= p.normDebt;
        activeCount -= 1;
        uint256 coll = p.coll;
        p.coll = 0;
        p.normDebt = 0;
        p.stake = 0;
        p.status = Status.ClosedByOwner;
        token.burnFrom(msg.sender, debt);
        WETH.safeTransfer(msg.sender, coll + GAS_RESERVE);
        emit PositionClosed(id, debt, coll, GAS_RESERVE);
        _emitUpdated(id, OP_CLOSE);
    }

    /// @notice Liquidates a position below MCR (§5.1.7, §6.4.1). Anyone; normal mode; price required.
    ///         The caller receives the gas reserve; the strategy absorbs what it can (A: the pool
    ///         offsets up to `totalDeposits` and pushes the surplus to the owner); the remainder is
    ///         redistributed to the other positions (§6.5.2) or, if none is staked, recorded as a deficit
    ///         with its collateral (§6.4.4). rounding: R1 (debt, up), R34 (normalised debt absorbed,
    ///         down), R27 (deficit, up).
    function liquidate(uint256 id) external whenWired nonReentrant {
        if (shutdown) revert SystemShutdown();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        uint256 price = _fetchRequiredPrice();
        _accrue();
        _applyPending(id);
        uint256 debt = _debtOf(p.normDebt);
        if (p.coll * price >= MCR * debt) revert NotLiquidatable();
        sorted.remove(id);
        totalStakes -= p.stake;
        totalCollateral -= p.coll;
        activeCount -= 1;
        (uint256 n, uint256 coll, address owner) = (p.normDebt, p.coll, p.owner);
        p.coll = 0;
        p.normDebt = 0;
        p.stake = 0;
        p.status = Status.ClosedByLiquidation;
        WETH.safeTransfer(msg.sender, GAS_RESERVE); // gas compensation
        WETH.safeTransfer(strategy, coll);
        (uint256 debtAbsorbed, uint256 collReturned) =
            ILiquidationStrategy(strategy).onLiquidation(id, owner, debt, coll, price);
        // defence in depth (CHG-012): the strategy contract guarantees both; a violation reverts
        if (debtAbsorbed > debt) revert DebtAbsorbedExceedsDebt();
        if (collReturned > coll) revert CollReturnedExceedsColl();
        uint256 normAbsorbed = debtAbsorbed == debt ? n : Rounding.mulDivDown(debtAbsorbed, RAY, index); // R34
        uint256 normRest = n - normAbsorbed;
        totalNormDebt -= normAbsorbed;
        uint8 path = PATH_NONE;
        if (collReturned > 0 || normRest > 0) {
            if (totalStakes > 0) {
                _redistribute(collReturned, normRest);
                path = PATH_REDISTRIBUTED;
            } else {
                uint256 debtRest = _debtOf(normRest); // R27 (up)
                totalNormDebt -= normRest;
                WETH.safeTransfer(deficitLedger, collReturned);
                IDeficitLedgerDeficit(deficitLedger).recordDeficit(debtRest, collReturned);
                path = PATH_DEFICIT;
            }
        }
        _updateSystemSnapshots();
        emit Liquidated(
            id, owner, msg.sender, debt, coll, debtAbsorbed, collReturned, normRest, path, GAS_RESERVE
        );
        _emitUpdated(id, OP_LIQUIDATE);
    }

    /// @notice Accrues interest to now (§5.1.8, §6.2). Anyone; any mode (a no-op once shut down);
    ///         no price. The pool and the ledger call it before reading state that interest changes.
    function accrue() external whenWired nonReentrant {
        _accrue();
    }

    /// @notice The redemption loop (§5.1.9, §6.7.3): walks from the tail, skips positions below MCR,
    ///         redeems whole positions while `amount` covers them (closing each and pushing its surplus
    ///         plus gas reserve to its owner), and ends with at most one partial. Burns what was
    ///         redeemed from `redeemer` and sends the collateral bought to it. RedemptionModule only,
    ///         which has fetched the price, accrued, applied the gate and checked the balance (§6.7.2);
    ///         no price is fetched and nothing accrues here.
    /// @dev rounding: collateral to the redeemer R18 (down: the fee's share and the rounding stay in
    ///      the position); normalised debt removed by a partial R3 (down). Every visited node counts as
    ///      an iteration. A partial that would leave ICR < MCR (CHG-002) or whose hints are stale is
    ///      cancelled with no state change and ends the loop.
    /// @param redeemer the RedemptionModule's `msg.sender` (§2.5); its stablecoin is burned
    /// @param amount the most stablecoin to redeem
    /// @param feeRate WAD, `≤ WAD`, computed by the RedemptionModule (§6.7.1)
    /// @param price the price the RedemptionModule fetched (WAD)
    /// @param maxIterations the most list nodes to visit; bounds the loop
    /// @return redeemed stablecoin burned; collSent WETH sent to `redeemer`; iterations nodes visited
    function redeemCollateral(
        address redeemer,
        uint256 amount,
        uint256 feeRate,
        uint256 price,
        uint256 maxIterations,
        uint256 upperHint,
        uint256 lowerHint
    ) external whenWired nonReentrant returns (uint256 redeemed, uint256 collSent, uint256 iterations) {
        if (msg.sender != redemptionModule) revert Unauthorized();
        (redeemed, collSent, iterations) =
            _redeemLoop(Redemption(amount, feeRate, price, maxIterations, upperHint, lowerHint));
        token.burnFrom(redeemer, redeemed);
        WETH.safeTransfer(redeemer, collSent);
    }

    /// @notice Returns the gas reserve of a position still active at settlement. Owner; settled
    ///         mode (§5.1.10).
    function reclaimGasReserve(uint256 id) external whenWired nonReentrant {
        if (!settled) revert NotSettled();
        Position storage p = _positions[id];
        if (p.status != Status.Active) revert PositionNotActive();
        if (msg.sender != p.owner) revert NotOwner();
        p.status = Status.ClosedByShutdown;
        activeCount -= 1;
        WETH.safeTransfer(p.owner, GAS_RESERVE);
        emit GasReserveReclaimed(id, p.owner, GAS_RESERVE);
        _emitUpdated(id, OP_CLOSE);
    }

    // ------------------------------------------------------------------ hooks (§5.1.11)

    /// @notice Freezes the vault at the shutdown trigger. ShutdownModule only; it accrued just before.
    function onShutdown() external whenWired nonReentrant {
        if (msg.sender != shutdownModule) revert Unauthorized();
        if (shutdown) revert SystemShutdown();
        shutdown = true;
        emit VaultShutdown(index);
    }

    /// @notice Hands all collateral to the claim pool at settlement. ShutdownModule only. Positions
    ///         keep their stored fields but are void; only `reclaimGasReserve` remains.
    function onSettlement() external whenWired nonReentrant returns (uint256 coll) {
        if (msg.sender != shutdownModule) revert Unauthorized();
        if (!shutdown) revert NotTriggered();
        if (settled) revert AlreadySettled();
        coll = totalCollateral + pendingColl;
        totalCollateral = 0;
        pendingColl = 0;
        settled = true;
        WETH.safeTransfer(shutdownModule, coll);
        emit VaultSettled(coll, activeCount);
    }

    // ------------------------------------------------------------------ views (§5.1.12)

    function positions(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @notice The index accrued to now, without writing (§5.1.12); frozen after shutdown.
    /// @dev rounding: R33 (as R4, up).
    function currentIndex() public view returns (uint256) {
        if (shutdown) return index;
        return
            Rounding.mulDivUp(
                index, WadRayMath.rpow(RAY + RATE_PER_SECOND, block.timestamp - lastAccrual), RAY
            );
    }

    /// @notice Effective collateral and normalised debt, pending redistribution included (§2.4).
    function effective(uint256 id) public view returns (uint256 effColl, uint256 effNorm) {
        Position storage p = _positions[id];
        effColl = p.coll + _pendingCollOf(p);
        effNorm = p.normDebt + _pendingNormOf(p);
    }

    /// @notice The key SortedPositions orders by (§6.3.1).
    function sortKey(uint256 id) external view returns (uint256 effColl, uint256 effNorm) {
        return effective(id);
    }

    /// @notice Effective debt at the current index. rounding: R1 (up).
    function debtOf(uint256 id) public view returns (uint256) {
        (, uint256 effNorm) = effective(id);
        return Rounding.mulDivUp(effNorm, currentIndex(), RAY);
    }

    /// @notice Display only (R30, down); max when the debt is 0.
    function icr(uint256 id, uint256 price) external view returns (uint256) {
        uint256 debt = debtOf(id);
        if (debt == 0) return type(uint256).max;
        (uint256 effColl,) = effective(id);
        return Rounding.mulDivDown(effColl, price, debt);
    }

    /// @notice Display only (R30, down).
    function nicr(uint256 id) external view returns (uint256) {
        (uint256 effColl, uint256 effNorm) = effective(id);
        return Rounding.mulDivDown(effColl, NICR_PRECISION, effNorm);
    }

    /// @notice All collateral that would join the claim pool at settlement (§5.1.12).
    function systemColl() public view returns (uint256 c) {
        c = totalCollateral + pendingColl + IDeficitLedgerViews(deficitLedger).recoveredColl();
        if (stabilityPool == address(0)) c += IAuctionHouseViews(strategy).totalLot(); // B
    }

    /// @notice All debt the stablecoin supply stands for (§5.1.12). rounding: R28 (up).
    function systemDebt() public view returns (uint256) {
        IDeficitLedgerViews ledger = IDeficitLedgerViews(deficitLedger);
        return Rounding.mulDivUp(totalNormDebt, currentIndex(), RAY) + ledger.auctionDebt() + ledger.deficit();
    }

    /// @notice Display only (R30, down); max when the system has no debt.
    function tcr(uint256 price) external view returns (uint256) {
        uint256 d = systemDebt();
        if (d == 0) return type(uint256).max;
        return Rounding.mulDivDown(systemColl(), price, d);
    }

    /// @notice Active and `effColl · price < MCR · debtOf(id)` (exact cross-multiplication).
    function isLiquidatable(uint256 id, uint256 price) external view returns (bool) {
        if (_positions[id].status != Status.Active) return false;
        (uint256 effColl,) = effective(id);
        return effColl * price < MCR * debtOf(id);
    }

    // ------------------------------------------------------------------ internal

    function _fetchRequiredPrice() internal returns (uint256 price) {
        bool usable;
        (price, usable) = oracle.fetchPrice();
        if (!usable) revert PriceUnusable();
    }

    /// @dev Interest accrual (§6.2). Runs at the start of every operation (inside the lock) and from
    ///      `accrue()`. The index grows even when `totalNormDebt == 0` (interest is then 0); position
    ///      debts are never written — `debtOf` reads the index. State is written before the mints.
    ///      rounding: new index R4 (up), interest R6 (up: supply never lags debt growth), pool share
    ///      R7 (down; the remainder goes to the reserve).
    ///      Overflow: `rpow(RAY + RATE_PER_SECOND, dt)` and the new index must fit in 256 bits, or the
    ///      call panics 0x11 (spec §2.2). The limit is on the *cumulative* index growth since
    ///      deployment — accruing more often does not extend it. From index RAY: 74,509,693,419 s
    ///      (≈ 2,362.7 years) at the start rate (5 %) and 5,244,687,241 s (≈ 166.3 years) at the
    ///      maximum RATE_PER_SECOND (ANNUAL_RATE = 1.0), tested at the exact boundary
    ///      (`VaultManagerInterestTest.test_maxDt_*`). With no debt nothing is minted and that bound
    ///      is the one that applies; then every operation and the debt views panic. With debt, the
    ///      minted interest reaches the token's 2^128 − 1 supply cap (`SupplyCapExceeded`, §5.9)
    ///      sooner — at 100 %/yr about 48 years from a 1M-token supply (38 from 1B), at 5 %/yr about
    ///      500–640 years. Both are far outside any experiment horizon; the spec accepts them.
    function _accrue() internal {
        if (shutdown) return; // index frozen at the trigger
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        uint256 oldIndex = index;
        uint256 newIndex = Rounding.mulDivUp(oldIndex, WadRayMath.rpow(RAY + RATE_PER_SECOND, dt), RAY);
        uint256 interest = Rounding.mulDivUp(totalNormDebt, newIndex - oldIndex, RAY);
        index = newIndex;
        lastAccrual = block.timestamp;
        address pool = stabilityPool;
        uint256 toPool = 0;
        if (pool != address(0)) {
            uint256 offered = Rounding.mulDivDown(interest, POOL_SHARE_BPS, BPS); // R7 (down)
            if (offered > 0) {
                (bool ok, bool booked) = _poolOnInterest(pool, offered);
                if (ok && booked) {
                    toPool = offered;
                } else if (!ok) {
                    _requirePoolHookGas(gasleft());
                    emit PoolInterestRedirected(offered);
                }
            }
        }
        uint256 toReserve = interest - toPool;
        if (toPool > 0) token.mint(pool, toPool); // after the pool booked it
        if (toReserve > 0) {
            token.mint(deficitLedger, toReserve);
            IDeficitLedgerInterest(deficitLedger).onInterest(toReserve);
        }
        emit InterestAccrued(newIndex, interest, toPool, toReserve, block.timestamp);
    }

    /// @dev After a failed pool call: a starved call leaves `< 2·POOL_HOOK_GAS/63`, so revert rather
    ///      than redirect (§6.2, ADR-0033). Takes `gasleft()` as an argument so the boundary is
    ///      testable exactly.
    function _requirePoolHookGas(uint256 left) internal view {
        if (left < POOL_HOOK_FLOOR) revert InsufficientGasForPoolHook();
    }

    /// @dev The guarded pool call of §6.2 (ADR-0033, the ADR-0029 pattern): `onInterest(amount)` with
    ///      `POOL_HOOK_GAS`, at most 32 bytes of return data copied, and only an exactly-32-byte answer
    ///      of 0 or 1 decoded. `ok` is false when the call reverts, runs out of gas, or answers any
    ///      other size or word; the pool's own state is then rolled back by the revert.
    function _poolOnInterest(address pool, uint256 amount) internal returns (bool ok, bool booked) {
        bytes4 selector = IStabilityPoolInterest.onInterest.selector;
        uint256 gasCap = POOL_HOOK_GAS;
        uint256 word;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), amount)
            ok := call(gasCap, pool, 0, ptr, 0x24, ptr, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            if ok { word := mload(ptr) }
        }
        ok = ok && word <= 1;
        booked = word == 1;
    }

    /// @dev The loop of §6.7.3. The node's predecessor is read before the node is touched.
    function _redeemLoop(Redemption memory r)
        internal
        returns (uint256 redeemed, uint256 collSent, uint256 iterations)
    {
        uint256 remaining = r.amount;
        uint256 cur = sorted.getLast();
        while (remaining > 0 && cur != 0 && iterations < r.maxIterations) {
            ++iterations;
            uint256 prevId = sorted.getPrev(cur);
            (uint256 d, uint256 out, bool last) = _redeemOne(cur, remaining, r);
            redeemed += d;
            collSent += out;
            remaining -= d;
            if (last) break; // a partial — done or cancelled — is always the last step
            cur = prevId;
        }
    }

    /// @dev One visited node: skip below MCR, full redemption, or the (last) partial.
    function _redeemOne(uint256 id, uint256 remaining, Redemption memory r)
        internal
        returns (uint256 d, uint256 out, bool last)
    {
        (uint256 c, uint256 n) = effective(id);
        uint256 debt = _debtOf(n);
        if (c * r.price < MCR * debt) return (0, 0, false); // below MCR: liquidate, don't redeem
        if (remaining >= debt) return (debt, _redeemFull(id, debt, r.feeRate, r.price), false);
        (d, out) = _redeemPartial(id, c, n, debt, remaining, r);
        last = true;
    }

    /// @dev A full redemption (§6.7.3): closes `id`, pushes surplus plus gas reserve to its owner.
    ///      `out < coll`: ICR ≥ MCR > 1 gives `coll · price > debt · WAD ≥ debt · (WAD − feeRate)`.
    ///      rounding: R18 (down).
    function _redeemFull(uint256 id, uint256 debt, uint256 feeRate, uint256 price)
        internal
        returns (uint256 out)
    {
        _applyPending(id);
        Position storage p = _positions[id];
        out = Rounding.mulDivDown(debt, WAD - feeRate, price);
        uint256 surplus = p.coll - out;
        sorted.remove(id);
        totalStakes -= p.stake;
        totalCollateral -= p.coll;
        totalNormDebt -= p.normDebt;
        activeCount -= 1;
        p.coll = 0;
        p.normDebt = 0;
        p.stake = 0;
        p.status = Status.ClosedByRedemption;
        WETH.safeTransfer(p.owner, surplus + GAS_RESERVE);
        emit PositionRedeemed(id, debt, out, surplus, true);
        _emitUpdated(id, OP_REDEEM);
    }

    /// @dev The partial step (§6.7.3), on the effective `(c, n)` read before `_applyPending` (which
    ///      leaves them unchanged). Returns `(0, 0)` without changing state when the position sits at
    ///      exactly `MIN_DEBT`, when the remainder would fall below MCR (CHG-002, ADR-0027), or when
    ///      the hints are stale.
    function _redeemPartial(
        uint256 id,
        uint256 c,
        uint256 n,
        uint256 debt,
        uint256 remaining,
        Redemption memory r
    ) internal returns (uint256 d, uint256 out) {
        uint256 dn;
        (d, dn, out) = _partialAmounts(c, n, debt, remaining, r);
        if (d == 0) return (0, 0);
        (bool found, uint256 prv, uint256 nxt) = _partialSlot(id, c - out, n - dn, r);
        if (!found) return (0, 0); // stale hint: cancelled, no state change
        _applyPending(id);
        Position storage p = _positions[id];
        p.coll -= out;
        p.normDebt -= dn;
        totalCollateral -= out;
        totalNormDebt -= dn;
        _updateStake(id);
        sorted.reinsert(id, prv, nxt); // exact hints: succeeds without walking
        emit PositionRedeemed(id, d, out, 0, false);
        _emitUpdated(id, OP_REDEEM);
    }

    /// @dev The partial's amounts, or `d = 0` when it is cancelled before the list is probed.
    ///      `d ≤ debt − MIN_DEBT` keeps `debtOf(n − dn) ≥ MIN_DEBT` (as in `repay`); `dn ≤ n`
    ///      because `d < debt`, and `out < c` as in `_redeemFull`.
    ///      rounding: normalised debt removed R3 (down), collateral to the redeemer R18 (down).
    function _partialAmounts(uint256 c, uint256 n, uint256 debt, uint256 remaining, Redemption memory r)
        internal
        view
        returns (uint256 d, uint256 dn, uint256 out)
    {
        d = Math.min(remaining, debt - MIN_DEBT);
        if (d == 0) return (0, 0, 0); // position at exactly MIN_DEBT
        dn = Rounding.mulDivDown(d, RAY, index);
        out = Rounding.mulDivDown(d, WAD - r.feeRate, r.price);
        // CHG-002: dn rounds down and the remaining debt up, which can leave ICR < MCR — cancel
        if ((c - out) * r.price < MCR * _debtOf(n - dn)) return (0, 0, 0);
    }

    /// @dev Where the partial's new key goes, with the node itself treated as absent (§6.3.2).
    function _partialSlot(uint256 id, uint256 newColl, uint256 newNorm, Redemption memory r)
        internal
        view
        returns (bool, uint256, uint256)
    {
        return sorted.find(newColl, newNorm, id, id, r.upperHint, r.lowerHint);
    }

    /// @dev rounding: R1 (up).
    function _debtOf(uint256 n) internal view returns (uint256) {
        return Rounding.mulDivUp(n, index, RAY);
    }

    /// @dev §2.4, rounding R8 (down).
    function _pendingCollOf(Position storage p) internal view returns (uint256) {
        return Rounding.mulDivDown(p.stake, LColl - p.snapLColl, DECIMAL_PRECISION);
    }

    function _pendingNormOf(Position storage p) internal view returns (uint256) {
        return Rounding.mulDivDown(p.stake, LDebt - p.snapLDebt, DECIMAL_PRECISION);
    }

    /// @dev §6.5.3, rounding R8 (down); truncation dust stays in the pending buckets.
    function _applyPending(uint256 id) internal {
        Position storage p = _positions[id];
        uint256 pc = _pendingCollOf(p);
        uint256 pn = _pendingNormOf(p);
        if (pc > 0 || pn > 0) {
            p.coll += pc;
            p.normDebt += pn;
            pendingColl -= pc;
            pendingNormDebt -= pn;
            totalCollateral += pc; // totalNormDebt unchanged: pending debt was already in it
            emit RewardsApplied(id, pc, pn);
        }
        p.snapLColl = LColl;
        p.snapLDebt = LDebt;
    }

    /// @dev §6.5.4, rounding R10 (down). Stake = coll until the first liquidation sets snapshots.
    function _computeStake(uint256 coll) internal view returns (uint256) {
        if (totalStakesSnapshot == 0 || totalCollateralSnapshot == 0) return coll;
        return Rounding.mulDivDown(coll, totalStakesSnapshot, totalCollateralSnapshot);
    }

    function _updateStake(uint256 id) internal {
        Position storage p = _positions[id];
        uint256 newStake = _computeStake(p.coll);
        totalStakes = totalStakes - p.stake + newStake;
        p.stake = newStake;
    }

    /// @dev §6.5.2, with the liquidated position already removed. Precondition `totalStakes > 0`.
    ///      rounding: R9 — floor division with error carry (§2.2).
    function _redistribute(uint256 collR, uint256 normR) internal {
        uint256 stakes = totalStakes;
        uint256 collNumerator = collR * DECIMAL_PRECISION + lastErrorColl;
        uint256 normNumerator = normR * DECIMAL_PRECISION + lastErrorDebt;
        uint256 dLColl = collNumerator / stakes; // R9: floor with carry
        uint256 dLDebt = normNumerator / stakes; // R9: floor with carry
        lastErrorColl = collNumerator - dLColl * stakes;
        lastErrorDebt = normNumerator - dLDebt * stakes;
        LColl += dLColl;
        LDebt += dLDebt;
        pendingColl += collR;
        pendingNormDebt += normR;
        emit Redistributed(collR, normR, LColl, LDebt, lastErrorColl, lastErrorDebt, stakes);
    }

    /// @dev §6.5.4, at the end of every liquidation. With no stake left the snapshots reset, so the
    ///      next position is staked 1:1 instead of 0 against leftover pending dust.
    function _updateSystemSnapshots() internal {
        if (totalStakes == 0) {
            totalStakesSnapshot = 0;
            totalCollateralSnapshot = 0;
        } else {
            totalStakesSnapshot = totalStakes;
            totalCollateralSnapshot = totalCollateral + pendingColl;
        }
        emit SystemSnapshotsUpdated(totalStakesSnapshot, totalCollateralSnapshot);
    }

    function _emitUpdated(uint256 id, uint8 op) internal {
        Position storage p = _positions[id];
        emit PositionUpdated(id, p.coll, p.normDebt, p.stake, p.snapLColl, p.snapLDebt, uint8(p.status), op);
    }
}
