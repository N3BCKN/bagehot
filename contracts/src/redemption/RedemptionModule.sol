// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IRedemptionVault} from "../interfaces/IRedemptionVault.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {IAuctionHousePurchaseState, IShutdownGate} from "../interfaces/ISystemViews.sol";
import {
    AuctionCallbackActive,
    InsufficientBalance,
    InvalidParameter,
    PriceUnusable,
    SystemShutdown,
    ZeroAmount
} from "../lib/Errors.sol";
import {Rounding} from "../lib/Rounding.sol";
import {WadRayMath} from "../lib/WadRayMath.sol";
import {WiredBase} from "../lib/Wired.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RedemptionModule
/// @notice Exchanges stablecoin for collateral at par, less a fee, from the lowest-NICR positions
///         (docs/spec.md §4.6, §5.5, §6.7). Owns the fee — a floor plus a base rate that rises with
///         each redemption and decays with time — and the critical-TCR gate; the loop itself runs
///         in `VaultManager.redeemCollateral`. Holds no tokens.
/// @dev The whole redemption decision (price, fee, gate) sits here (§6.7.2). One transient lock on
///      `redeem`; the VaultManager's own lock guards `accrue` and `redeemCollateral`, which are
///      separate contracts' locks and do not interfere.
contract RedemptionModule is WiredBase, ReentrancyGuardTransient {
    // ------------------------------------------------------------------ errors, events

    error ZeroIterations();
    error FeeExceedsMaximum();
    error NothingRedeemed();
    error TCRBelowCritical();

    /// @dev One redemption's fee inputs: supply after accrual, decayed base rate, fee rate.
    struct Fee {
        uint256 s0;
        uint256 decayed;
        uint256 rate;
    }

    event Redeemed(
        address indexed redeemer,
        uint256 requested,
        uint256 redeemed,
        uint256 collSent,
        uint256 feeRate,
        uint256 iterations,
        uint256 baseRate
    );

    // ------------------------------------------------------------------ constants

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    /// @notice Range of `BETA` (§3.1).
    uint256 public constant MAX_BETA = 100;

    // ------------------------------------------------------------------ immutables

    IStableToken public immutable token;
    IOracleAdapter public immutable oracle;
    uint256 public immutable REDEMPTION_FEE_FLOOR;
    uint256 public immutable BETA;
    uint256 public immutable BASE_RATE_DECAY;

    // ------------------------------------------------------------------ storage (§4.6)

    /// @notice WAD, `≤ WAD`; starts at 0.
    uint256 public baseRate;
    /// @notice Starts at the construction timestamp.
    uint256 public lastFeeOperationTime;

    // wired
    IRedemptionVault public vaultManager;
    IShutdownGate public shutdownModule;
    address public auctionHouse; // B; address(0) in A

    /// @param feeFloor WAD, `≤ WAD` (index 2)
    /// @param beta base-rate sensitivity divisor, `1 ≤ beta ≤ 100` (index 3)
    /// @param baseRateDecay RAY, `0 < x < RAY` (index 4)
    constructor(address token_, address oracle_, uint256 feeFloor, uint256 beta, uint256 baseRateDecay) {
        if (token_ == address(0)) revert InvalidParameter(0);
        if (oracle_ == address(0)) revert InvalidParameter(1);
        if (feeFloor > WAD) revert InvalidParameter(2);
        if (beta == 0 || beta > MAX_BETA) revert InvalidParameter(3);
        if (baseRateDecay == 0 || baseRateDecay >= RAY) revert InvalidParameter(4);
        token = IStableToken(token_);
        oracle = IOracleAdapter(oracle_);
        REDEMPTION_FEE_FLOOR = feeFloor;
        BETA = beta;
        BASE_RATE_DECAY = baseRateDecay;
        lastFeeOperationTime = block.timestamp;
    }

    /// @notice One-shot wiring (§3.4). `auctionHouse` is `address(0)` in deployment A.
    function wire(address vaultManager_, address shutdownModule_, address auctionHouse_) external onlyWiring {
        _requireNonZero(vaultManager_, 0);
        _requireNonZero(shutdownModule_, 1);
        vaultManager = IRedemptionVault(vaultManager_);
        shutdownModule = IShutdownGate(shutdownModule_);
        auctionHouse = auctionHouse_;
        address[] memory addresses = new address[](3);
        (addresses[0], addresses[1], addresses[2]) = (vaultManager_, shutdownModule_, auctionHouse_);
        _markWired(addresses);
    }

    // ------------------------------------------------------------------ external

    /// @notice Redeems up to `amount` of the caller's stablecoin for collateral (§5.5, §6.7.2).
    ///         Anyone; normal mode; price required. Reverts `TCRBelowCritical` while
    ///         `ShutdownModule.belowCritical(price)` holds, measured after accrual.
    /// @dev The fee rate is set by the requested amount; the stored base rate by the amount actually
    ///      redeemed (§6.7.2). rounding: decayed base rate R19 (up), increment R20 (up).
    /// @param maxIterations the most list nodes the loop visits (`> 0`)
    /// @param maxFeeRate WAD; the call reverts `FeeExceedsMaximum` above it
    /// @param upperHint insert hint for the final partial's new position (§6.7.3)
    /// @param lowerHint insert hint for the final partial's new position
    function redeem(
        uint256 amount,
        uint256 maxIterations,
        uint256 maxFeeRate,
        uint256 upperHint,
        uint256 lowerHint
    ) external whenWired nonReentrant {
        if (vaultManager.shutdown()) revert SystemShutdown();
        if (amount == 0) revert ZeroAmount();
        if (maxIterations == 0) revert ZeroIterations();
        uint256 price = _priceAfterGate();
        if (token.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        Fee memory f = _fee(amount);
        if (f.rate > maxFeeRate) revert FeeExceedsMaximum();
        (uint256 redeemed, uint256 collSent, uint256 iterations) = vaultManager.redeemCollateral(
            msg.sender, amount, f.rate, price, maxIterations, upperHint, lowerHint
        );
        if (redeemed == 0) revert NothingRedeemed();
        _record(amount, redeemed, collSent, iterations, f);
    }

    // ------------------------------------------------------------------ views

    /// @notice The base rate decayed to now (§6.7.1). Once positive it floors at 1 wei.
    /// @dev rounding: R19 (up — the fee never drops by rounding).
    function decayedBaseRate() public view returns (uint256) {
        return Rounding.mulDivUp(
            baseRate, WadRayMath.rpow(BASE_RATE_DECAY, block.timestamp - lastFeeOperationTime), RAY
        );
    }

    /// @notice The fee rate a redemption of `amount` would pay now (§5.5). Uses the current supply
    ///         without accruing, so it can differ from what a `redeem` in the same block charges by
    ///         the interest minted at that `redeem`'s accrual. Reverts (division by zero) while the
    ///         supply is 0, when no redemption is possible anyway.
    function redemptionFeeRate(uint256 amount) external view returns (uint256) {
        return Math.min(
            REDEMPTION_FEE_FLOOR + Math.min(decayedBaseRate() + _increment(amount, token.totalSupply()), WAD),
            WAD
        );
    }

    // ------------------------------------------------------------------ internal

    /// @dev Fetches the price (required), accrues, then applies the auction-callback guard and the
    ///      critical-TCR gate, in §6.7.2's order — the gate sees the current block's interest.
    function _priceAfterGate() internal returns (uint256 price) {
        bool usable;
        (price, usable) = oracle.fetchPrice();
        if (!usable) revert PriceUnusable();
        vaultManager.accrue();
        address house = auctionHouse;
        if (house != address(0) && IAuctionHousePurchaseState(house).inPurchase()) {
            revert AuctionCallbackActive();
        }
        if (shutdownModule.belowCritical(price)) revert TCRBelowCritical();
    }

    /// @dev §6.7.2: the fee rate from the requested amount, on the supply after accrual.
    function _fee(uint256 amount) internal view returns (Fee memory f) {
        f.s0 = token.totalSupply();
        f.decayed = decayedBaseRate();
        f.rate = Math.min(REDEMPTION_FEE_FLOOR + Math.min(f.decayed + _increment(amount, f.s0), WAD), WAD);
    }

    /// @dev §6.7.2: the stored base rate from the amount actually redeemed.
    function _record(uint256 amount, uint256 redeemed, uint256 collSent, uint256 iterations, Fee memory f)
        internal
    {
        uint256 newBaseRate = Math.min(f.decayed + _increment(redeemed, f.s0), WAD);
        baseRate = newBaseRate;
        lastFeeOperationTime = block.timestamp;
        emit Redeemed(msg.sender, amount, redeemed, collSent, f.rate, iterations, newBaseRate);
    }

    /// @dev §6.7.1 `increment(x, S0) = mulDivUp(x, WAD, S0 · BETA)`. rounding: R20 (up).
    ///      `S0 · BETA ≤ 2^128 · 100` cannot overflow.
    function _increment(uint256 x, uint256 s0) internal view returns (uint256) {
        return Rounding.mulDivUp(x, WAD, s0 * BETA);
    }
}
