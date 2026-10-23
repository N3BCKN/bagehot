// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidParameter} from "./Errors.sol";

/// @title WiredBase
/// @notice One-shot wiring shared by every core contract except OracleAdapter (docs/spec.md §3.4,
///         §4.1, §9; ADR-0021). The immutable `deployer` may call the concrete `wire(...)` exactly
///         once; until then every state-changing function except `wire` reverts `NotWired()`.
/// @dev A concrete contract implements
///      `function wire(...) external onlyWiring { _requireNonZero(...); store; _markWired(addrs); }`
///      so the checks run in the order §3.4 fixes: `NotDeployer`, then `AlreadyWired`, then the
///      arguments in argument order. Named `WiredBase`, not `Wired`, so the contract does not
///      shadow the spec's `Wired` event (§11.1). Deployment and wiring happen in one factory
///      transaction (P18), and no address other than the deployer can wire, so there is no
///      front-running window.
abstract contract WiredBase {
    /// @notice `msg.sender` of the constructor; the only address allowed to call `wire`.
    address public immutable deployer;

    /// @notice Set once by `wire`; never cleared.
    bool public wired;

    /// @notice Emitted once by `wire`, with the wired addresses in argument order (§9).
    event Wired(address[] addresses);

    error NotWired();
    error AlreadyWired();
    error NotDeployer();

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Every state-changing function except `wire` starts with this check (§2.5).
    modifier whenWired() {
        if (!wired) revert NotWired();
        _;
    }

    /// @notice Guards the concrete `wire`: deployer first, then not yet wired (§3.4).
    modifier onlyWiring() {
        if (msg.sender != deployer) revert NotDeployer();
        if (wired) revert AlreadyWired();
        _;
    }

    /// @dev Reverts `InvalidParameter(index)` for a zero address where §3.4 requires a non-zero one.
    function _requireNonZero(address a, uint8 index) internal pure {
        if (a == address(0)) revert InvalidParameter(index);
    }

    /// @dev Called exactly once, at the end of the concrete `wire`, after its stores. The
    ///      `AlreadyWired` re-check keeps the once-only guarantee in the base even if a concrete
    ///      `wire` were ever written without `onlyWiring`.
    function _markWired(address[] memory addresses) internal {
        if (wired) revert AlreadyWired();
        wired = true;
        emit Wired(addresses);
    }
}
