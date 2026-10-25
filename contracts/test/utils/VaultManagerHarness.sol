// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultManager} from "../../src/core/VaultManager.sol";
import {Rounding} from "../../src/lib/Rounding.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice VaultManager with a test-only setter for the redistribution state that P20 will write, so
///         P14 can exercise `_applyPending` (§6.5.3) and `_computeStake` with non-zero snapshots
///         (§6.5.4) before the writers exist. Never deployed outside tests.
contract VaultManagerHarness is VaultManager {
    using SafeERC20 for IERC20;

    /// @dev §6.5.2's error carries; the real ones arrive with their writer at P20.
    uint256 public lastErrorColl;
    uint256 public lastErrorDebt;

    event HarnessRedistributed(uint256 indexed id, uint256 collR, uint256 normR, uint256 totalStakes);

    constructor(
        address weth_,
        address token_,
        address oracle_,
        uint256 mcr,
        uint256 minDebt,
        uint256 gasReserve,
        uint256 ratePerSecond,
        uint256 poolShareBps
    ) VaultManager(weth_, token_, oracle_, mcr, minDebt, gasReserve, ratePerSecond, poolShareBps) {}

    /// @dev The accrual state an `interest.json` vector starts from (§6.2). `totalNormDebt` set
    ///      without supply: I2 is not meaningful after this.
    function setAccrualState(uint256 index_, uint256 lastAccrual_, uint256 totalNormDebt_) external {
        index = index_;
        lastAccrual = lastAccrual_;
        totalNormDebt = totalNormDebt_;
    }

    /// @dev A non-round index, so rounding directions R1 / R2 / R3 become observable (P15 makes the
    ///      index move for real; supply is not adjusted here, so I2 is not meaningful after this).
    function setIndex(uint256 index_) external {
        index = index_;
    }

    function setRedistribution(
        uint256 lColl,
        uint256 lDebt,
        uint256 pendColl,
        uint256 pendNorm,
        uint256 stakesSnapshot,
        uint256 collSnapshot
    ) external {
        LColl = lColl;
        LDebt = lDebt;
        pendingColl = pendColl;
        pendingNormDebt = pendNorm;
        totalNormDebt += pendNorm; // pending debt is part of totalNormDebt (I1 supporting identity)
        totalStakesSnapshot = stakesSnapshot;
        totalCollateralSnapshot = collSnapshot;
    }

    /// @dev Test-only stand-in for a deployment-A liquidation whose strategy absorbs nothing (P17,
    ///      approved by the human): §6.4.1's VaultManager side with `debtAbsorbed = 0` and
    ///      `collReturned = coll` — the whole position is redistributed (§6.5.2) — then the system
    ///      snapshots (§6.5.4). No ICR check: it exists to move the list into I13's tolerance regime.
    ///      The collateral never leaves the VaultManager (it becomes `pendingColl`) and the normalised
    ///      debt stays in `totalNormDebt` (as `pendingNormDebt`), so I1 and I2 are unaffected apart
    ///      from the gas reserve paid to the caller. Must be checked against P20's real
    ///      redistribution on the same inputs before it is retired (carry-forward).
    function redistribute(uint256 id) external {
        Position storage p = _positions[id];
        require(p.status == Status.Active, "harness: not active");
        require(totalStakes > p.stake, "harness: no other stakes");
        _accrue();
        _applyPending(id);
        sorted.remove(id);
        totalStakes -= p.stake;
        totalCollateral -= p.coll;
        activeCount -= 1;
        (uint256 n, uint256 coll) = (p.normDebt, p.coll);
        p.coll = 0;
        p.normDebt = 0;
        p.stake = 0;
        p.status = Status.ClosedByLiquidation;
        WETH.safeTransfer(msg.sender, GAS_RESERVE);
        _harnessRedistribute(coll, n);
        _harnessUpdateSystemSnapshots();
        emit HarnessRedistributed(id, coll, n, totalStakes);
    }

    /// @dev §6.5.2 exactly. Precondition `totalStakes > 0`.
    function _harnessRedistribute(uint256 collR, uint256 normR) internal {
        uint256 collNumerator = collR * DECIMAL_PRECISION + lastErrorColl;
        uint256 normNumerator = normR * DECIMAL_PRECISION + lastErrorDebt;
        uint256 dLColl = Rounding.mulDivDown(collNumerator, 1, totalStakes); // floor (§6.5.2)
        uint256 dLDebt = Rounding.mulDivDown(normNumerator, 1, totalStakes);
        lastErrorColl = collNumerator - dLColl * totalStakes;
        lastErrorDebt = normNumerator - dLDebt * totalStakes;
        LColl += dLColl;
        LDebt += dLDebt;
        pendingColl += collR;
        pendingNormDebt += normR;
    }

    /// @dev §6.5.4.
    function _harnessUpdateSystemSnapshots() internal {
        if (totalStakes == 0) {
            totalStakesSnapshot = 0;
            totalCollateralSnapshot = 0;
        } else {
            totalStakesSnapshot = totalStakes;
            totalCollateralSnapshot = totalCollateral + pendingColl;
        }
    }
}
