// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BagehotFactory} from "../src/deploy/BagehotFactory.sol";
import {LocalWETH} from "../src/mocks/LocalWETH.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {MockSequencerFeed} from "../src/mocks/MockSequencerFeed.sol";
import {Blueprints} from "./Blueprints.sol";
import {ConfigLoader, DeployConfig} from "./Config.s.sol";
import {DeploymentChecks} from "./DeploymentChecks.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Deploys one variant through `BagehotFactory` (one transaction: deploy + wire, from the
///         blueprints of ADR-0035, deployed or found beforehand), asserts
///         spec §3.3 before anything is broadcast (forge broadcasts only if the run succeeds), and,
///         when broadcasting, records it in `deployments/<chainId>.json` under the variant's key, so A
///         and B of one chain sit side by side. `run()` deploys the config's variant; `runVariant("B")`
///         (`--sig "runVariant(string)" B`) overrides it.
///         Chain guard (CLAUDE.md, ADR-0019): 31337 and 84532 are allowed; 8453 only with
///         `BAGEHOT_FORK=true` *and* an RPC that answers `anvil_nodeInfo` (a local anvil fork, never
///         a real Base node); every other chain reverts. While the factory carries local-only
///         stand-ins (P18-2), only 31337 can actually deploy.
contract Deploy is ConfigLoader {
    uint256 internal constant ANVIL = 31_337;
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant BASE = 8453;
    string internal constant SOLC = "0.8.28"; // foundry.toml `solc_version` (ADR-018)

    error ChainNotAllowed(uint256 chainId);
    error StandInsAreLocalOnly(uint256 chainId);
    error VariantInvalid(string variant);
    error ProvenanceRefused(string why);

    /// @notice Reverts unless `chainId` may be deployed to.
    function checkChain(uint256 chainId) public {
        bool fork = vm.envOr("BAGEHOT_FORK", false);
        if (!chainAllowed(chainId, fork, fork && isLocalAnvil())) revert ChainNotAllowed(chainId);
    }

    /// @notice The guard's rule: anvil and Base Sepolia always; Base mainnet only when the fork flag
    ///         is set and the RPC is a local anvil.
    function chainAllowed(uint256 chainId, bool forkFlag, bool localAnvil) public pure returns (bool) {
        return chainId == ANVIL || chainId == BASE_SEPOLIA || (chainId == BASE && forkFlag && localAnvil);
    }

    /// @notice True if the RPC is an anvil node: it answers `anvil_nodeInfo`, which no public node does.
    function isLocalAnvil() public returns (bool) {
        try this.probeAnvil() {
            return true;
        } catch {
            return false;
        }
    }

    function probeAnvil() external {
        vm.rpc("anvil_nodeInfo", "[]");
    }

    /// @notice Deploys the variant named in `config/<chainId>.toml`.
    function run() external returns (BagehotFactory f) {
        checkChain(block.chainid); // before reading any config: an unknown chain has none
        return _run(loadConfig(block.chainid));
    }

    /// @notice Deploys variant "A" or "B", overriding the config's.
    function runVariant(string calldata variant) external returns (BagehotFactory f) {
        checkChain(block.chainid);
        DeployConfig memory c = loadConfig(block.chainid);
        string memory t = vm.readFile(configPath(block.chainid));
        if (keccak256(bytes(variant)) == keccak256("B")) {
            (c.variantB, c.poolShareBps) = (true, vm.parseTomlUint(t, ".params.pool_share_bps_b"));
        } else if (keccak256(bytes(variant)) == keccak256("A")) {
            (c.variantB, c.poolShareBps) = (false, vm.parseTomlUint(t, ".params.pool_share_bps_a"));
        } else {
            revert VariantInvalid(variant);
        }
        return _run(c);
    }

    function _run(DeployConfig memory c) internal returns (BagehotFactory f) {
        checkChain(block.chainid);
        checkProvenance(
            block.chainid, vm.envOr("GIT_COMMIT", string("unknown")), vm.envOr("BAGEHOT_SOLC", SOLC)
        );
        (f, c) = deploy(c);
        // a dry run deploys nothing, so it must not overwrite a real manifest
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            writeManifest(f, c, string.concat("../deployments/", vm.toString(block.chainid), ".json"));
        }
    }

    /// @notice P18-3: what the manifest records must describe the deployed code. Off chain 31337 the
    ///         commit must be known and the tree clean (`git describe --dirty` adds "-dirty"); on every
    ///         chain the compiler foundry.toml pins (passed by the recipe) must be the one recorded.
    function checkProvenance(uint256 chainId, string memory commit, string memory solc) public pure {
        if (keccak256(bytes(solc)) != keccak256(bytes(SOLC))) {
            revert ProvenanceRefused("solc differs from foundry.toml");
        }
        if (chainId == ANVIL) return;
        if (keccak256(bytes(commit)) == keccak256("unknown")) revert ProvenanceRefused("GIT_COMMIT not set");
        if (_endsWith(commit, "-dirty")) revert ProvenanceRefused("working tree is dirty");
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }

    /// @notice Deploys mocks (31337 only), the blueprints that do not exist yet (earlier transactions,
    ///         ADR-0035), then the factory; asserts §3.3. Writes nothing to disk. Returns the
    ///         configuration completed with the mocks' addresses.
    function deploy(DeployConfig memory c) public returns (BagehotFactory f, DeployConfig memory) {
        checkChain(block.chainid);
        if (block.chainid != ANVIL) revert StandInsAreLocalOnly(block.chainid);
        vm.startBroadcast();
        (c.weth, c.priceFeed, c.sequencerFeed) = _localMocks(c);
        (address[9] memory blueprints, bytes32[9] memory hashes) = Blueprints.deployAll(c.variantB);
        f = new BagehotFactory(_factoryParams(c), blueprints, hashes);
        vm.stopBroadcast();
        DeploymentChecks.check(f, c);
        return (f, c);
    }

    function _localMocks(DeployConfig memory c) internal returns (address weth, address feed, address seq) {
        weth = address(new LocalWETH());
        MockAggregator priceFeed = new MockAggregator(c.mockFeedDecimals);
        priceFeed.setRound(1, int256(c.mockInitialPrice / 10 ** (18 - c.mockFeedDecimals)), block.timestamp);
        MockSequencerFeed sequencer = new MockSequencerFeed();
        sequencer.setStatus(0, block.timestamp - c.mockSequencerUpSince);
        (feed, seq) = (address(priceFeed), address(sequencer));
    }

    function _factoryParams(DeployConfig memory c) internal pure returns (BagehotFactory.Params memory p) {
        p.variantB = c.variantB;
        (p.weth, p.priceFeed, p.sequencerFeed) = (c.weth, c.priceFeed, c.sequencerFeed);
        (p.mcr, p.minDebt, p.gasReserve, p.ratePerSecond, p.poolShareBps, p.poolHookGas) =
        (c.mcr, c.minDebt, c.gasReserve, c.ratePerSecond, c.poolShareBps, c.poolHookGas);
        p.maxHintSteps = c.maxHintSteps;
        (p.liquidationPenalty, p.minDeposit) = (c.liquidationPenalty, c.minDeposit);
        (p.staleness, p.gracePeriod, p.minPrice, p.maxPrice) =
        (c.staleness, c.gracePeriod, c.minPrice, c.maxPrice);
        (p.oracleGas, p.oraclePostFailureGas) = (c.oracleGas, c.oraclePostFailureGas);
        (p.redemptionFeeFloor, p.beta, p.baseRateDecay) = (c.redemptionFeeFloor, c.beta, c.baseRateDecay);
        p.criticalTcr = c.criticalTcr;
        (p.tokenName, p.tokenSymbol) = (c.tokenName, c.tokenSymbol);
    }

    /// @notice Records the deployment under its variant's key in `path` (created with both keys if it
    ///         does not exist). Written only by this script (CLAUDE.md). `block` is the block the run
    ///         simulated against; the factory's `deployBlock` is the mined one (the smoke test checks
    ///         `block <= deployBlock`).
    function writeManifest(BagehotFactory f, DeployConfig memory c, string memory path) public {
        if (!vm.exists(path)) vm.writeJson('{"A":{},"B":{}}', path);
        vm.writeJson(_manifestJson(f, c), path, c.variantB ? ".B" : ".A");
    }

    function _manifestJson(BagehotFactory f, DeployConfig memory c) internal returns (string memory) {
        string memory addrs = _addressesJson(f, c);
        (string memory onChain, string memory configOnly) = _paramsJson(c);
        string memory m = "manifest";
        vm.serializeUint(m, "chainId", block.chainid);
        vm.serializeString(m, "variant", c.variantB ? "B" : "A");
        vm.serializeUint(m, "block", block.number);
        vm.serializeString(m, "gitCommit", vm.envOr("GIT_COMMIT", string("unknown")));
        vm.serializeString(m, "solc", vm.envOr("BAGEHOT_SOLC", SOLC));
        vm.serializeBool(m, "standIns", true);
        vm.serializeString(m, "params", onChain);
        vm.serializeString(m, "configOnlyParams", configOnly);
        vm.serializeString(m, "blueprints", _blueprintsJson(c.variantB));
        return vm.serializeString(m, "addresses", addrs);
    }

    function _addressesJson(BagehotFactory f, DeployConfig memory c) internal returns (string memory) {
        string memory a = "addresses";
        vm.serializeAddress(a, "factory", address(f));
        vm.serializeAddress(a, "token", address(f.token()));
        vm.serializeAddress(a, "oracle", address(f.oracle()));
        vm.serializeAddress(a, "vaultManager", address(f.vaultManager()));
        vm.serializeAddress(a, "sortedPositions", address(f.sorted()));
        vm.serializeAddress(a, "redemptionModule", address(f.redemptionModule()));
        vm.serializeAddress(a, "hintHelpers", address(f.hintHelpers()));
        vm.serializeAddress(a, "strategy", f.strategy());
        vm.serializeAddress(a, "deficitLedger", f.deficitLedger());
        vm.serializeAddress(a, "shutdownModule", f.shutdownModule());
        vm.serializeAddress(a, "weth", c.weth);
        vm.serializeAddress(a, "priceFeed", c.priceFeed);
        return vm.serializeAddress(a, "sequencerFeed", c.sequencerFeed);
    }

    /// @dev ADR-0035 provenance: per role, the blueprint the factory read and its code hash.
    function _blueprintsJson(bool variantB) internal returns (string memory out) {
        bytes[9] memory codes = Blueprints.creationCodes(variantB);
        string[9] memory n = Blueprints.names();
        for (uint256 i; i < 9; ++i) {
            string memory r = string.concat("blueprint.", n[i]);
            vm.serializeAddress(r, "address", Blueprints.predict(i, codes[i]));
            out = vm.serializeString(
                "blueprints", n[i], vm.serializeBytes32(r, "codehash", Blueprints.codehash(codes[i]))
            );
        }
    }

    /// @dev Parameters held by deployed contracts, and those held by no contract in every variant
    ///      (LIQUIDATION_PENALTY: the StabilityPool in A since P19, the auction house in B from P33;
    ///      ORACLE_FAILURE_DURATION: the ShutdownModule) but used by the §3.3 checks. MIN_DEPOSIT is
    ///      held by A's StabilityPool and recorded for both variants, as the shared configuration.
    function _paramsJson(DeployConfig memory c)
        internal
        returns (string memory onChain, string memory configOnly)
    {
        string memory k = "params";
        vm.serializeUint(k, "MCR", c.mcr);
        vm.serializeUint(k, "MIN_DEBT", c.minDebt);
        vm.serializeUint(k, "GAS_RESERVE", c.gasReserve);
        vm.serializeUint(k, "RATE_PER_SECOND", c.ratePerSecond);
        vm.serializeUint(k, "POOL_SHARE_BPS", c.poolShareBps);
        vm.serializeUint(k, "POOL_HOOK_GAS", c.poolHookGas);
        vm.serializeUint(k, "MIN_DEPOSIT", c.minDeposit);
        vm.serializeUint(k, "MAX_HINT_STEPS", c.maxHintSteps);
        vm.serializeUint(k, "REDEMPTION_FEE_FLOOR", c.redemptionFeeFloor);
        vm.serializeUint(k, "BETA", c.beta);
        vm.serializeUint(k, "BASE_RATE_DECAY", c.baseRateDecay);
        vm.serializeUint(k, "STALENESS", c.staleness);
        vm.serializeUint(k, "GRACE_PERIOD", c.gracePeriod);
        vm.serializeUint(k, "MIN_PRICE", c.minPrice);
        vm.serializeUint(k, "MAX_PRICE", c.maxPrice);
        vm.serializeUint(k, "ORACLE_GAS", c.oracleGas);
        vm.serializeUint(k, "ORACLE_POST_FAILURE_GAS", c.oraclePostFailureGas);
        onChain = vm.serializeUint(k, "CRITICAL_TCR", c.criticalTcr);
        string memory q = "configOnly";
        vm.serializeUint(q, "LIQUIDATION_PENALTY", c.liquidationPenalty);
        configOnly = vm.serializeUint(q, "ORACLE_FAILURE_DURATION", c.oracleFailureDuration);
    }
}
