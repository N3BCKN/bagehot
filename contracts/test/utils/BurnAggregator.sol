// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice An honest but expensive aggregator: it needs `NEED` gas, then answers correctly. All
///         state is immutable (embedded in the runtime code), so its code can be `vm.etch`ed over
///         the real Chainlink aggregator behind Base's real proxy on a fork — the proxy's own
///         deployed bytecode then decides how much gas comes back when this call starves (CHG-004).
contract BurnAggregator {
    uint256 internal immutable NEED;
    int256 internal immutable ANSWER;
    uint256 internal immutable UPDATED_AT;

    constructor(uint256 need, int256 answer, uint256 updatedAt) {
        NEED = need;
        ANSWER = answer;
        UPDATED_AT = updatedAt;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 g = gasleft(); // one read (see MockAggregator)
        uint256 stop = g > NEED ? g - NEED : 0;
        while (gasleft() > stop) {}
        return (1, ANSWER, UPDATED_AT, UPDATED_AT, 1);
    }
}
