// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @notice One deployment's configuration, read from `config/<chainId>.toml`.
struct DeployConfig {
    uint256 chainId;
    bool variantB;
    // external dependencies: on chain 31337 the script deploys mocks and fills these in
    address weth;
    address priceFeed;
    address sequencerFeed;
    // mocks (chain 31337 only)
    uint8 mockFeedDecimals;
    uint256 mockInitialPrice;
    uint256 mockSequencerUpSince;
    // StableToken
    string tokenName;
    string tokenSymbol;
    // parameters (spec §3.1)
    uint256 mcr;
    uint256 minDebt;
    uint256 gasReserve;
    uint256 ratePerSecond;
    uint256 poolShareBps;
    uint256 maxHintSteps;
    uint256 liquidationPenalty;
    uint256 redemptionFeeFloor;
    uint256 beta;
    uint256 baseRateDecay;
    uint256 staleness;
    uint256 gracePeriod;
    uint256 minPrice;
    uint256 maxPrice;
    uint256 oracleGas;
    uint256 oraclePostFailureGas;
    uint256 criticalTcr;
    uint256 oracleFailureDuration;
}

/// @notice Loads `config/<chainId>.toml` with `vm.readFile` + `stdToml`. Values too large for TOML's
///         64-bit integers are strings and parsed exactly; the rest are integers.
abstract contract ConfigLoader is Script {
    using stdToml for string;

    error ConfigChainMismatch(uint256 inFile, uint256 expected);
    error ConfigVariantInvalid(string variant);

    function configPath(uint256 chainId) public view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../config/", vm.toString(chainId), ".toml");
    }

    function loadConfig(uint256 chainId) public view returns (DeployConfig memory c) {
        string memory t = vm.readFile(configPath(chainId));
        c.chainId = t.readUint(".chain_id");
        if (c.chainId != chainId) revert ConfigChainMismatch(c.chainId, chainId);
        string memory variant = t.readString(".variant");
        if (keccak256(bytes(variant)) == keccak256("B")) c.variantB = true;
        else if (keccak256(bytes(variant)) != keccak256("A")) revert ConfigVariantInvalid(variant);
        if (chainId == 31_337) {
            c.mockFeedDecimals = uint8(t.readUint(".mocks.price_feed_decimals"));
            c.mockInitialPrice = _big(t, ".mocks.initial_price");
            c.mockSequencerUpSince = t.readUint(".mocks.sequencer_up_since_s");
        } else {
            c.weth = t.readAddress(".external.weth");
            c.priceFeed = t.readAddress(".external.price_feed");
            c.sequencerFeed = t.readAddress(".external.sequencer_feed");
        }
        c.tokenName = t.readString(".token.name");
        c.tokenSymbol = t.readString(".token.symbol");
        _params(t, c);
    }

    function _params(string memory t, DeployConfig memory c) private pure {
        c.mcr = _big(t, ".params.mcr");
        c.minDebt = _big(t, ".params.min_debt");
        c.gasReserve = _big(t, ".params.gas_reserve");
        c.ratePerSecond = _big(t, ".params.rate_per_second");
        c.poolShareBps =
            c.variantB ? t.readUint(".params.pool_share_bps_b") : t.readUint(".params.pool_share_bps_a");
        c.maxHintSteps = t.readUint(".params.max_hint_steps");
        c.liquidationPenalty = _big(t, ".params.liquidation_penalty");
        c.redemptionFeeFloor = _big(t, ".params.redemption_fee_floor");
        c.beta = t.readUint(".params.beta");
        c.baseRateDecay = _big(t, ".params.base_rate_decay");
        c.staleness = t.readUint(".params.staleness_s");
        c.gracePeriod = t.readUint(".params.grace_period_s");
        c.minPrice = _big(t, ".params.min_price");
        c.maxPrice = _big(t, ".params.max_price");
        c.oracleGas = t.readUint(".params.oracle_gas");
        c.oraclePostFailureGas = t.readUint(".params.oracle_post_failure_gas");
        c.criticalTcr = _big(t, ".params.critical_tcr");
        c.oracleFailureDuration = t.readUint(".params.oracle_failure_duration_s");
    }

    /// @dev A decimal string, parsed exactly (no float, no 64-bit limit).
    function _big(string memory t, string memory key) private pure returns (uint256) {
        return vm.parseUint(t.readString(key));
    }
}
