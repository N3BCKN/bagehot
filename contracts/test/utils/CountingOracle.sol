// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";

/// @notice Test-only pass-through to the real OracleAdapter that counts `fetchPrice` calls, so a
///         handler can assert that an operation performed no oracle read (I9: repay, addCollateral and
///         close never read the oracle, §7) without cheatcodes — the same check runs under Medusa.
contract CountingOracle is IOracleAdapter {
    IOracleAdapter public immutable adapter;
    uint256 public reads;

    constructor(IOracleAdapter adapter_) {
        adapter = adapter_;
    }

    function fetchPrice() external returns (uint256 price, bool usable) {
        ++reads;
        return adapter.fetchPrice();
    }
}
