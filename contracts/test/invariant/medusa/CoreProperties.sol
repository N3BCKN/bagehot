// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreHandler} from "../handlers/CoreHandler.sol";

/// @notice Medusa target (P17): the core handler's actions as the fuzzed surface and its checks as
///         `property_*` functions — the same check functions the Foundry invariants assert
///         (`test/invariant/CoreInvariants.t.sol`). Deployment A, which has the most behaviour
///         (redistribution, pool interest); the handler is built without event logs, which Medusa
///         cannot read, so I2's counters and the I5 analysis come from its state reconstruction —
///         validated against the events by `invariant_stateReconstructionMatchesEvents` in Foundry.
///         The I8 unwind needs snapshots and runs in Foundry only.
contract CoreProperties is CoreHandler {
    constructor()
        CoreHandler(
            false,
            false,
            [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E), address(0xE41)]
        )
    {}

    function property_I1_holderBalances() external view returns (bool ok) {
        (ok,) = checkI1Holders();
    }

    function property_I1_supportingSums() external view returns (bool ok) {
        (ok,) = checkI1Sums();
    }

    function property_I2_supplyDriftBound() external view returns (bool ok) {
        (ok,) = checkI2();
    }

    function property_I5_redemptionHealthy() external view returns (bool ok) {
        (ok,) = checkI5();
    }

    function property_I8_noRoundingDeficit() external view returns (bool ok) {
        (ok,) = checkI8();
    }

    function property_I9_rescuePathsLive() external view returns (bool ok) {
        (ok,) = checkI9();
    }

    function property_I11_parametersImmutable() external view returns (bool ok) {
        (ok,) = checkI11();
    }

    function property_I12_priceGate() external view returns (bool ok) {
        (ok,) = checkI12();
    }

    function property_I13_sortedOrder() external view returns (bool ok) {
        (ok,) = checkI13();
    }

    function property_noUnexpectedReverts() external view returns (bool ok) {
        (ok,) = checkNoUnexpectedReverts();
    }
}
