// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StabilityPoolHandler} from "./handlers/StabilityPoolHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The pool invariants (P19, docs/invariants.md): I1 for the StabilityPool holder, I3's exact
///         inequalities and `P` range, the withdraw-entitlement clause, the empty-epoch clause, and U4.
///         The attribution bounds of I3 compare against exact rationals and are checked in Python
///         (`model/tools/sp_precision.py`, `model/invariants.py`), as the invariant text prescribes.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: nightly.invariant.fail-on-revert = true
contract StabilityPoolInvariantsTest is Test {
    StabilityPoolHandler internal h;

    function setUp() public {
        address[5] memory a =
            [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        h = new StabilityPoolHandler(a);
        targetContract(address(h));
    }

    function _sums() internal view returns (uint256 compounded, uint256 collGains, uint256 interestGains) {
        for (uint256 i; i < 5; ++i) {
            address a = h.actors(i);
            compounded += h.pool().compoundedDeposit(a);
            (uint256 c, uint256 g) = h.pool().gains(a);
            collGains += c;
            interestGains += g;
        }
    }

    /// @dev I1, StabilityPool row: both balances equal the recorded claims plus donations, exactly.
    function invariant_I1_poolHolder() public view {
        assertEq(
            h.weth().balanceOf(address(h.pool())),
            h.pool().collGainsBalance() + h.donatedWeth(),
            "I1 pool WETH"
        );
        assertEq(
            h.token().balanceOf(address(h.pool())),
            h.pool().totalDeposits() + h.pool().interestGainsBalance() + h.donatedToken(),
            "I1 pool stablecoin"
        );
    }

    /// @dev I3: Σ compounded ≤ T, Σ gains ≤ their balances, withdraw pays min(x, compounded), and an
    ///      empty current epoch holds nothing (the stand-in ledger never settles).
    function invariant_I3_poolSolvency() public view {
        (uint256 compounded, uint256 collGains, uint256 interestGains) = _sums();
        assertLe(compounded, h.pool().totalDeposits(), "I3: sum of compounded deposits <= totalDeposits");
        assertLe(collGains, h.pool().collGainsBalance(), "I3: sum of collateral gains <= collGainsBalance");
        assertLe(interestGains, h.pool().interestGainsBalance(), "I3: sum of interest gains <= balance");
        assertEq(h.entitlementViolations(), 0, "I3: withdraw paid other than min(x, compounded)");
        if (h.pool().depositorCount(h.pool().currentEpoch()) == 0) {
            assertEq(h.pool().totalDeposits(), 0, "I3: no current-epoch depositor => totalDeposits == 0");
        }
    }

    function invariant_I3_productRange() public view {
        assertGe(h.pool().P(), h.pool().P_MIN(), "I3: P >= P_MIN");
        assertLe(h.pool().P(), h.pool().P_PRECISION(), "I3: P <= P_PRECISION");
    }

    /// @dev U4: Σ compounded ≤ token.balanceOf(pool) − interestGainsBalance − donated.
    function invariant_U4_depositsCovered() public view {
        (uint256 compounded,,) = _sums();
        uint256 bal = h.token().balanceOf(address(h.pool()));
        assertLe(compounded + h.pool().interestGainsBalance() + h.donatedToken(), bal, "U4");
    }

    function invariant_noUnexpectedRevert() public view {
        assertEq(h.unexpectedReverts(), 0, "unexpected revert");
    }

    /// @dev Reach, reported at the end of every run (docs/fuzzing.md).
    function afterInvariant() public {
        emit log_named_uint("deposits", h.ok("deposit"));
        emit log_named_uint("withdrawals", h.ok("withdraw"));
        emit log_named_uint("offsets", h.ok("offset"));
        emit log_named_uint("liquidations", h.ok("liquidate"));
        emit log_named_uint("epoch changes", h.epochChanges());
        emit log_named_uint("scale changes", h.scaleChanges());
        emit log_named_uint("dust sweeps", h.sweeps());
    }
}
