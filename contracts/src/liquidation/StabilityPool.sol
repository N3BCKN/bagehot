// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolVault} from "../interfaces/IPoolVault.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {IDeficitLedgerPoolDust} from "../interfaces/ISystemViews.sol";
import {InsufficientBalance, InvalidParameter, Unauthorized, ZeroAmount} from "../lib/Errors.sol";
import {Rounding} from "../lib/Rounding.sol";
import {WiredBase} from "../lib/Wired.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title StabilityPool
/// @notice Deployment A's liquidation strategy: stablecoin deposits absorb liquidated debt in exchange
///         for the seized collateral, and earn a share of the interest (docs/spec.md §4.4, §5.3, §6.6).
///         Product–sum accounting: a deposit is worth `initial · P / snapP / SCALE_FACTOR^Δscale` in
///         its epoch and 0 after it; collateral and interest gains accrue in the sums `S` and `G`, one
///         per `(epoch, scale)`. There are no shares.
/// @dev One transient lock over `deposit`, `withdraw`, `claimGains` and `onLiquidation`. `onInterest`
///      is the lock-free callback of §5.10: VaultManager only, call-free, reached from inside a locked
///      depositor call through `vaultManager.accrue()` before the pool reads any deposit state.
contract StabilityPool is WiredBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStableToken;

    // ------------------------------------------------------------------ errors, events

    error NoDeposit();
    error DepositTooSmall();

    event DepositUpdated(
        address indexed depositor,
        uint256 deposit,
        uint256 P,
        uint256 epoch,
        uint256 scale,
        uint256 snapS,
        uint256 snapG
    );
    event GainsPaid(address indexed depositor, uint256 collGain, uint256 interestGain);
    event PoolOffset(
        uint256 debt,
        uint256 coll,
        uint256 perUnitGain,
        uint256 lastCollError,
        uint256 P,
        uint256 epoch,
        uint256 scale,
        uint256 totalDeposits
    );
    event PoolLiquidation(
        uint256 indexed positionId,
        uint256 debt,
        uint256 coll,
        uint256 seized,
        uint256 surplus,
        uint256 debtOffset,
        uint256 collToPool,
        uint256 collReturned
    );
    event PoolInterest(uint256 amount, uint256 perUnitGain, uint256 lastInterestError);
    event PoolDustSwept(uint256 amount);

    // ------------------------------------------------------------------ constants (§2.1)

    uint256 internal constant WAD = 1e18;
    uint256 public constant DECIMAL_PRECISION = 1e18;
    uint256 public constant P_PRECISION = 1e36;
    uint256 public constant SCALE_FACTOR = 1e9;
    uint256 public constant P_MIN = P_PRECISION / SCALE_FACTOR;
    uint256 public constant SCALE_SPAN = 2;
    /// @notice Range of `LIQUIDATION_PENALTY` (§3.4 index 2) and lower bound of `MIN_DEPOSIT` (index 3).
    uint256 public constant MAX_LIQUIDATION_PENALTY = 0.5e18;
    uint256 public constant MIN_MIN_DEPOSIT = 1e18;

    // ------------------------------------------------------------------ immutables

    IERC20 public immutable WETH;
    IStableToken public immutable token;
    uint256 public immutable LIQUIDATION_PENALTY;
    uint256 public immutable MIN_DEPOSIT;

    // ------------------------------------------------------------------ storage (§4.4)

    struct Deposit {
        uint256 initial; // 0 means no deposit
        uint256 snapP;
        uint256 snapS;
        uint256 snapG;
        uint256 snapEpoch;
        uint256 snapScale;
    }

    /// @notice `T`: stablecoin backing deposits, `≥ Σ compoundedDeposit`.
    uint256 public totalDeposits;
    /// @notice `P_MIN ≤ P ≤ P_PRECISION`; starts at `P_PRECISION`.
    uint256 public P = P_PRECISION;
    uint256 public currentScale;
    uint256 public currentEpoch;
    /// @notice Cumulative collateral gain per unit deposit × `P`, scaled by `DECIMAL_PRECISION`.
    mapping(uint256 epoch => mapping(uint256 scale => uint256)) public epochToScaleToS;
    /// @notice The same for interest (stablecoin) gains.
    mapping(uint256 epoch => mapping(uint256 scale => uint256)) public epochToScaleToG;
    uint256 public lastCollError;
    uint256 public lastInterestError;
    /// @notice WETH received from offsets minus WETH paid to depositors.
    uint256 public collGainsBalance;
    /// @notice Stablecoin interest received minus interest paid to depositors.
    uint256 public interestGainsBalance;
    mapping(address depositor => Deposit) public deposits;
    /// @notice Depositors whose record has `initial > 0` and `snapEpoch == epoch`.
    mapping(uint256 epoch => uint256) public depositorCount;

    // wired
    address public vaultManager;
    IDeficitLedgerPoolDust public deficitLedger;

    // ------------------------------------------------------------------ modifiers

    modifier onlyVault() {
        if (msg.sender != vaultManager) revert Unauthorized();
        _;
    }

    // ------------------------------------------------------------------ constructor, wiring

    /// @param liquidationPenalty WAD, `≤ 0.5e18` (index 2)
    /// @param minDeposit stablecoin wei, `≥ 1e18` (index 3)
    constructor(address weth_, address token_, uint256 liquidationPenalty, uint256 minDeposit) {
        if (weth_ == address(0)) revert InvalidParameter(0);
        if (token_ == address(0)) revert InvalidParameter(1);
        if (liquidationPenalty > MAX_LIQUIDATION_PENALTY) revert InvalidParameter(2);
        if (minDeposit < MIN_MIN_DEPOSIT) revert InvalidParameter(3);
        WETH = IERC20(weth_);
        token = IStableToken(token_);
        LIQUIDATION_PENALTY = liquidationPenalty;
        MIN_DEPOSIT = minDeposit;
    }

    /// @notice One-shot wiring (§3.4).
    function wire(address vaultManager_, address deficitLedger_) external onlyWiring {
        _requireNonZero(vaultManager_, 0);
        _requireNonZero(deficitLedger_, 1);
        vaultManager = vaultManager_;
        deficitLedger = IDeficitLedgerPoolDust(deficitLedger_);
        address[] memory addresses = new address[](2);
        (addresses[0], addresses[1]) = (vaultManager_, deficitLedger_);
        _markWired(addresses);
    }

    // ------------------------------------------------------------------ depositor functions (§5.3)

    /// @notice Adds `amount` stablecoin to the caller's deposit, paying their pending gains first
    ///         (§5.3.1). Anyone, for themselves; any mode. The resulting deposit must be at least
    ///         `MIN_DEPOSIT`. The stablecoin is pulled with the token's privileged `moveFrom`, so no
    ///         approval is needed.
    /// @dev Accrues first, so the caller is snapshotted after the interest owed so far (§5.3).
    function deposit(uint256 amount) external whenWired nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IPoolVault(vaultManager).accrue(); // may call back onInterest (§5.10)
        Deposit memory rec = deposits[msg.sender];
        bool inCurrentEpoch = rec.initial > 0 && rec.snapEpoch == currentEpoch;
        (uint256 collGain, uint256 interestGain) = gains(msg.sender);
        uint256 compounded = compoundedDeposit(msg.sender);
        uint256 newDeposit = compounded + amount;
        if (newDeposit < MIN_DEPOSIT) revert DepositTooSmall();
        if (token.balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _payGains(msg.sender, collGain, interestGain);
        totalDeposits += amount;
        _snapshot(msg.sender, newDeposit);
        if (!inCurrentEpoch) depositorCount[currentEpoch] += 1;
        token.moveFrom(msg.sender, address(this), amount);
        _emitDeposit(msg.sender);
        emit GainsPaid(msg.sender, collGain, interestGain);
    }

    /// @notice Withdraws up to `amount` of the caller's compounded deposit, paying their pending gains
    ///         first (§5.3.2). `type(uint256).max` withdraws everything. The remainder must be 0 or at
    ///         least `MIN_DEPOSIT`. Anyone, for themselves; any mode.
    function withdraw(uint256 amount) external whenWired nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IPoolVault(vaultManager).accrue();
        Deposit memory rec = deposits[msg.sender];
        if (rec.initial == 0) revert NoDeposit();
        bool inCurrentEpoch = rec.snapEpoch == currentEpoch;
        (uint256 collGain, uint256 interestGain) = gains(msg.sender);
        uint256 compounded = compoundedDeposit(msg.sender);
        uint256 w = amount < compounded ? amount : compounded;
        uint256 newDeposit = compounded - w;
        if (newDeposit != 0 && newDeposit < MIN_DEPOSIT) revert DepositTooSmall();
        _payGains(msg.sender, collGain, interestGain);
        totalDeposits -= w;
        uint256 swept = 0;
        if (newDeposit == 0) swept = _leave(msg.sender, inCurrentEpoch);
        else _snapshot(msg.sender, newDeposit);
        token.safeTransfer(msg.sender, w);
        _emitDeposit(msg.sender);
        emit GainsPaid(msg.sender, collGain, interestGain);
        if (swept > 0) emit PoolDustSwept(swept);
    }

    /// @notice Pays the caller's pending gains and re-snapshots their compounded deposit without
    ///         changing it (§5.3.3). The `MIN_DEPOSIT` rule is not applied. Anyone, for themselves.
    function claimGains() external whenWired nonReentrant {
        IPoolVault(vaultManager).accrue();
        Deposit memory rec = deposits[msg.sender];
        if (rec.initial == 0) revert NoDeposit();
        bool inCurrentEpoch = rec.snapEpoch == currentEpoch;
        (uint256 collGain, uint256 interestGain) = gains(msg.sender);
        uint256 compounded = compoundedDeposit(msg.sender);
        _payGains(msg.sender, collGain, interestGain);
        uint256 swept = 0;
        if (compounded == 0) swept = _leave(msg.sender, inCurrentEpoch);
        else _snapshot(msg.sender, compounded);
        _emitDeposit(msg.sender);
        emit GainsPaid(msg.sender, collGain, interestGain);
        if (swept > 0) emit PoolDustSwept(swept);
    }

    // ------------------------------------------------------------------ hooks (§5.3.4)

    /// @notice Absorbs a liquidation (§6.6.4). VaultManager only; `coll` WETH has already been sent
    ///         to the pool. Seizes `min(coll, debt·(1 + penalty)/price)` (R11, up), pays the surplus to
    ///         the owner, offsets `min(debt, totalDeposits)` with its proportional share of the seized
    ///         collateral (R12, down) and returns the rest of the seized collateral to the VaultManager.
    /// @return debtAbsorbed the debt offset against deposits
    /// @return collReturned the seized collateral the VaultManager redistributes
    function onLiquidation(uint256 positionId, address owner, uint256 debt, uint256 coll, uint256 price)
        external
        whenWired
        onlyVault
        nonReentrant
        returns (uint256 debtAbsorbed, uint256 collReturned)
    {
        uint256 seized = Rounding.mulDivUp(debt, WAD + LIQUIDATION_PENALTY, price); // R11 (up)
        if (seized > coll) seized = coll;
        uint256 surplus = coll - seized;
        uint256 dP = debt < totalDeposits ? debt : totalDeposits;
        uint256 collP = dP == debt ? seized : Rounding.mulDivDown(seized, dP, debt); // R12 (down)
        collReturned = seized - collP;
        if (dP > 0) _offset(dP, collP);
        if (surplus > 0) WETH.safeTransfer(owner, surplus);
        if (collReturned > 0) WETH.safeTransfer(vaultManager, collReturned);
        emit PoolLiquidation(positionId, debt, coll, seized, surplus, dP, collP, collReturned);
        return (dP, collReturned);
    }

    /// @notice Books the pool's interest share (§6.6.5, ADR-0033). VaultManager only; lock-free and
    ///         call-free (§5.10). Declines, returning false without changing state, while
    ///         `totalDeposits < MIN_DEPOSIT`; otherwise books and returns true. The VaultManager mints
    ///         the tokens. rounding: per-unit gain R15 (down, with error carry).
    function onInterest(uint256 amount) external whenWired onlyVault returns (bool booked) {
        uint256 t = totalDeposits;
        if (t < MIN_DEPOSIT) return false;
        uint256 num = amount * DECIMAL_PRECISION + lastInterestError;
        uint256 perUnit = num / t; // R15: floor division with error carry (§2.2)
        lastInterestError = num - perUnit * t;
        epochToScaleToG[currentEpoch][currentScale] += perUnit * P;
        interestGainsBalance += amount;
        emit PoolInterest(amount, perUnit, lastInterestError);
        return true;
    }

    // ------------------------------------------------------------------ views

    /// @notice Whether accrual would book an interest share now (§5.3.4): `totalDeposits ≥ MIN_DEPOSIT`.
    function acceptsInterest() external view returns (bool) {
        return totalDeposits >= MIN_DEPOSIT;
    }

    /// @notice `T`, the stablecoin backing deposits (§5.3.4).
    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }

    /// @notice The depositor's deposit after every offset since their snapshot (§6.6.6); 0 after an
    ///         epoch change or more than five scale changes. rounding: R16 (down, then a floor division
    ///         by `SCALE_FACTOR^Δscale`, §2.2).
    function compoundedDeposit(address a) public view returns (uint256) {
        Deposit storage r = deposits[a];
        if (r.initial == 0 || r.snapEpoch < currentEpoch) return 0;
        uint256 ds = currentScale - r.snapScale;
        if (ds > 5) return 0;
        uint256 q = Rounding.mulDivDown(r.initial, P, r.snapP); // R16 (down)
        return q / SCALE_FACTOR ** ds; // R16: floor division by SCALE_FACTOR^ds (§2.2)
    }

    /// @notice The depositor's pending collateral (WETH) and interest (stablecoin) gains (§6.6.7).
    ///         Gains of an old epoch are still paid from that epoch's sums. rounding: R31 per scale, then
    ///         R17 (down).
    function gains(address a) public view returns (uint256 collGain, uint256 interestGain) {
        Deposit storage r = deposits[a];
        if (r.initial == 0) return (0, 0);
        collGain = _gain(r, epochToScaleToS, r.snapS);
        interestGain = _gain(r, epochToScaleToG, r.snapG);
    }

    // ------------------------------------------------------------------ internal

    /// @dev §6.6.2, with `0 < d ≤ T` debt and `c` collateral already held. The per-unit gain carries
    ///      its remainder independently of `P`; `P` rounds down, so `Σ compoundedDeposit ≤ T`.
    function _offset(uint256 d, uint256 c) internal {
        uint256 t = totalDeposits;
        uint256 num = c * DECIMAL_PRECISION + lastCollError;
        uint256 perUnit = num / t; // R14: floor division with error carry (§2.2)
        lastCollError = num - perUnit * t;
        epochToScaleToS[currentEpoch][currentScale] += perUnit * P; // P before the update
        collGainsBalance += c;
        token.burnFrom(address(this), d);
        totalDeposits = t - d;
        if (d == t) {
            // pool emptied exactly: a new epoch
            currentEpoch += 1;
            currentScale = 0;
            P = P_PRECISION;
        } else {
            // at most 5 iterations and P·SCALE_FACTOR^k < 3.4e74 (§6.6.9)
            uint256 k = 0;
            uint256 newP = Rounding.mulDivDown(P, t - d, t); // R13 (down)
            while (newP < P_MIN) {
                k += 1;
                newP = Rounding.mulDivDown(P * SCALE_FACTOR ** k, t - d, t); // R13 (down)
            }
            P = newP;
            currentScale += k;
        }
        emit PoolOffset(d, c, perUnit, lastCollError, P, currentEpoch, currentScale, totalDeposits);
    }

    /// @dev §6.6.7 `gain`: the sum since the snapshot in the snapshot's `(epoch, scale)`, plus the next
    ///      `SCALE_SPAN` scales each divided by `SCALE_FACTOR^j` (floor, §2.2).
    function _gain(
        Deposit storage r,
        mapping(uint256 => mapping(uint256 => uint256)) storage acc,
        uint256 snap
    ) internal view returns (uint256) {
        mapping(uint256 => uint256) storage byScale = acc[r.snapEpoch];
        uint256 total = byScale[r.snapScale] - snap;
        for (uint256 j = 1; j <= SCALE_SPAN; ++j) {
            total += byScale[r.snapScale + j] / SCALE_FACTOR ** j; // R31 (floor, §2.2)
        }
        return Rounding.mulDivDown(r.initial, total, r.snapP * DECIMAL_PRECISION); // R17 (down)
    }

    /// @dev §6.6.8 "pay gains".
    function _payGains(address a, uint256 collGain, uint256 interestGain) internal {
        if (collGain > 0) {
            collGainsBalance -= collGain;
            WETH.safeTransfer(a, collGain);
        }
        if (interestGain > 0) {
            interestGainsBalance -= interestGain;
            token.safeTransfer(a, interestGain);
        }
    }

    /// @dev §6.6.8 `snapshot(x)`.
    function _snapshot(address a, uint256 x) internal {
        uint256 e = currentEpoch;
        uint256 s = currentScale;
        deposits[a] = Deposit(x, P, epochToScaleToS[e][s], epochToScaleToG[e][s], e, s);
    }

    /// @dev §5.3.1 `leave`: the record becomes empty. When the last current-epoch depositor leaves a
    ///      residual, it is swept to the DeficitLedger's reserve unless the ledger has settled.
    function _leave(address a, bool inCurrentEpoch) internal returns (uint256 swept) {
        delete deposits[a];
        if (inCurrentEpoch) {
            uint256 e = currentEpoch;
            depositorCount[e] -= 1;
            if (depositorCount[e] == 0 && totalDeposits > 0 && !deficitLedger.settled()) {
                swept = totalDeposits;
                totalDeposits = 0;
                token.safeTransfer(address(deficitLedger), swept);
                deficitLedger.onPoolDust(swept);
            }
        }
    }

    /// @dev §5.3.1 `emitDeposit`, after the record was written or deleted.
    function _emitDeposit(address a) internal {
        Deposit storage r = deposits[a];
        if (r.initial == 0) emit DepositUpdated(a, 0, P, currentEpoch, currentScale, 0, 0);
        else emit DepositUpdated(a, r.initial, r.snapP, r.snapEpoch, r.snapScale, r.snapS, r.snapG);
    }
}
