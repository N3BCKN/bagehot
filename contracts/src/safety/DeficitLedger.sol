// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStableToken} from "../interfaces/IStableToken.sol";
import {
    IDeficitLedgerDeficit,
    IDeficitLedgerInterest,
    IDeficitLedgerPoolDust,
    IDeficitLedgerViews
} from "../interfaces/ISystemViews.sol";
import {AlreadySettled, InvalidParameter, SystemSettled, Unauthorized} from "../lib/Errors.sol";
import {WiredBase} from "../lib/Wired.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title DeficitLedger
/// @notice The protocol's own books outside positions and the pool (docs/spec.md §4.7, §5.6, §6.9,
///         §6.11.3): `reserve` — protocol-owned stablecoin from the interest share, B's auction
///         penalties and the pool's swept dust; `auctionDebt` — debt in active auctions (B); `deficit` —
///         stablecoin in circulation that no position or auction owes; `recoveredColl` — WETH from a
///         no-stakes liquidation (A), held until settlement. `cover()` burns reserve against deficit,
///         permissionlessly. Recording never auto-covers (§6.9.2).
/// @dev The bookkeeping hooks (`onInterest`, `onPoolDust`, `recordDeficit`, `addAuctionDebt`,
///      `onAuctionPayment`, `onAuctionShortfall`) are lock-free callbacks restricted to one caller each
///      and make no external call (§5.10); `onInterest` must stay call-free and lock-free because the
///      VaultManager's accrual depends on it never reverting (ADR-0033 §3). `payTip`, `cover` and
///      `onSettlement` move or burn tokens and take the lock. Every hook checks, in order, `wired`, the
///      caller, `!settled` (§5.6). There is no socialization-mode parameter: the spec has none.
contract DeficitLedger is
    WiredBase,
    ReentrancyGuardTransient,
    IDeficitLedgerViews,
    IDeficitLedgerInterest,
    IDeficitLedgerPoolDust,
    IDeficitLedgerDeficit
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IStableToken;

    // ------------------------------------------------------------------ events (§11.1)

    uint8 internal constant SOURCE_INTEREST = 1;
    uint8 internal constant SOURCE_AUCTION_PENALTY = 2;
    uint8 internal constant SOURCE_POOL_DUST = 3;
    uint8 internal constant REASON_RESET_TIP = 1;
    uint8 internal constant DEFICIT_AUCTION = 1;
    uint8 internal constant DEFICIT_NO_STAKES = 2;

    event ReserveIncreased(uint256 amount, uint8 source);
    event ReserveDecreased(uint256 amount, uint8 reason);
    event AuctionDebtChanged(int256 delta, uint256 auctionDebt);
    event DeficitRecorded(uint256 amount, uint256 coll, uint8 source);
    event DeficitCovered(uint256 amount, uint256 reserve, uint256 deficit);
    event LedgerSettled(uint256 reserveBurned, uint256 deficit, uint256 recoveredColl);

    // ------------------------------------------------------------------ immutables

    IERC20 public immutable WETH;
    IStableToken public immutable token;

    // ------------------------------------------------------------------ storage (§4.7)

    uint256 public reserve;
    /// @notice `A`: exact Σ of active auctions' `debtRemaining` (B).
    uint256 public auctionDebt;
    /// @notice `F`: stablecoin in circulation backed by no position or auction.
    uint256 public deficit;
    uint256 public recoveredColl;
    bool public settled;

    // wired
    address public vaultManager;
    address public strategy;
    address public auctionHouse; // B; address(0) in A
    address public stabilityPool; // A; address(0) in B
    address public shutdownModule;

    // ------------------------------------------------------------------ modifiers

    /// @dev §5.6: `wired` (whenWired), then the caller, then `!settled`.
    modifier hook(address caller) {
        if (msg.sender != caller) revert Unauthorized();
        if (settled) revert SystemSettled();
        _;
    }

    // ------------------------------------------------------------------ constructor, wiring (§3.4)

    constructor(address weth_, address token_) {
        if (weth_ == address(0)) revert InvalidParameter(0);
        if (token_ == address(0)) revert InvalidParameter(1);
        WETH = IERC20(weth_);
        token = IStableToken(token_);
    }

    /// @notice One-shot wiring (§3.4): `auctionHouse ∈ {0, strategy}` (index 2), `stabilityPool ∈ {0,
    ///         strategy}` and exactly one of the two non-zero (index 3).
    function wire(
        address vaultManager_,
        address strategy_,
        address auctionHouse_,
        address stabilityPool_,
        address shutdownModule_
    ) external onlyWiring {
        _requireNonZero(vaultManager_, 0);
        _requireNonZero(strategy_, 1);
        if (auctionHouse_ != address(0) && auctionHouse_ != strategy_) revert InvalidParameter(2);
        if (stabilityPool_ != address(0) && stabilityPool_ != strategy_) revert InvalidParameter(3);
        if ((auctionHouse_ == address(0)) == (stabilityPool_ == address(0))) revert InvalidParameter(3);
        _requireNonZero(shutdownModule_, 4);
        (vaultManager, strategy, auctionHouse, stabilityPool, shutdownModule) =
        (vaultManager_, strategy_, auctionHouse_, stabilityPool_, shutdownModule_);
        address[] memory addresses = new address[](5);
        (addresses[0], addresses[1], addresses[2], addresses[3], addresses[4]) =
        (vaultManager_, strategy_, auctionHouse_, stabilityPool_, shutdownModule_);
        _markWired(addresses);
    }

    // ------------------------------------------------------------------ hooks (§5.6)

    /// @notice The reserve share of accrued interest; the VaultManager minted `amount` here. Lock-free
    ///         and call-free: accrual relies on it (ADR-0033 §3).
    function onInterest(uint256 amount) external whenWired hook(vaultManager) {
        reserve += amount;
        emit ReserveIncreased(amount, SOURCE_INTEREST);
    }

    /// @notice The pool's swept residual (§5.3.1 `leave`); the pool transferred it here.
    function onPoolDust(uint256 amount) external whenWired hook(stabilityPool) {
        reserve += amount;
        emit ReserveIncreased(amount, SOURCE_POOL_DUST);
    }

    /// @notice A liquidation remainder with no stake left to take it (§6.4.4); the VaultManager
    ///         transferred `coll` WETH here first.
    function recordDeficit(uint256 d, uint256 coll) external whenWired hook(vaultManager) {
        deficit += d;
        recoveredColl += coll;
        emit DeficitRecorded(d, coll, DEFICIT_NO_STAKES);
    }

    /// @notice Debt moved into a new auction (B, §6.8.2).
    function addAuctionDebt(uint256 d) external whenWired hook(auctionHouse) {
        auctionDebt += d;
        emit AuctionDebtChanged(int256(d), auctionDebt);
    }

    /// @notice A purchase (B, §6.8.4): the house burned `burned` against auction debt and moved
    ///         `toReserve` stablecoin here.
    function onAuctionPayment(uint256 burned, uint256 toReserve) external whenWired hook(auctionHouse) {
        auctionDebt -= burned;
        reserve += toReserve;
        emit AuctionDebtChanged(-int256(burned), auctionDebt);
        if (toReserve > 0) emit ReserveIncreased(toReserve, SOURCE_AUCTION_PENALTY);
    }

    /// @notice An auction finished short (B): its unpaid debt becomes deficit.
    function onAuctionShortfall(uint256 d) external whenWired hook(auctionHouse) {
        auctionDebt -= d;
        deficit += d;
        emit AuctionDebtChanged(-int256(d), auctionDebt);
        emit DeficitRecorded(d, 0, DEFICIT_AUCTION);
    }

    /// @notice A reset tip (B, §6.8.5), paid from the reserve. The house guarantees `amount ≤ reserve`.
    function payTip(address to, uint256 amount) external whenWired hook(auctionHouse) nonReentrant {
        reserve -= amount;
        token.safeTransfer(to, amount);
        emit ReserveDecreased(amount, REASON_RESET_TIP);
    }

    // ------------------------------------------------------------------ cover, settlement

    /// @notice Burns `min(reserve, deficit)` of the reserve against the deficit (§6.9.2). Anyone; any
    ///         mode before settlement; no price.
    function cover() external whenWired nonReentrant returns (uint256 c) {
        if (settled) revert SystemSettled();
        c = reserve < deficit ? reserve : deficit;
        if (c > 0) {
            reserve -= c;
            deficit -= c;
            token.burnFrom(address(this), c);
        }
        emit DeficitCovered(c, reserve, deficit);
    }

    /// @notice Settlement (§6.11.3): burns the whole reserve, turns auction debt into deficit, and sends
    ///         the recovered collateral to the ShutdownModule for the claim pool. ShutdownModule only.
    function onSettlement() external whenWired nonReentrant returns (uint256 coll) {
        if (msg.sender != shutdownModule) revert Unauthorized();
        if (settled) revert AlreadySettled();
        uint256 burned = reserve;
        reserve = 0;
        deficit += auctionDebt;
        auctionDebt = 0;
        coll = recoveredColl;
        recoveredColl = 0;
        settled = true;
        if (burned > 0) token.burnFrom(address(this), burned);
        if (coll > 0) WETH.safeTransfer(shutdownModule, coll);
        emit LedgerSettled(burned, deficit, coll);
    }
}
