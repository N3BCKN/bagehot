// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OracleAdapter} from "../../src/core/OracleAdapter.sol";

/// @notice Calls `fetchPrice` twice in one transaction — the second time with exactly `gasLimit` —
///         so the second call runs with the adapter's storage and the feeds already warm: the only
///         situation in which fetchPrice's own remaining work after a failed read (two cold SLOADs,
///         ~4.2k, when cold) falls below the post-failure floor (CHG-004).
contract WarmFetcher {
    function run(OracleAdapter o, uint256 gasLimit) external returns (bool ok, bytes memory ret) {
        o.fetchPrice();
        (ok, ret) = address(o).call{gas: gasLimit}(abi.encodeCall(OracleAdapter.fetchPrice, ()));
    }
}
