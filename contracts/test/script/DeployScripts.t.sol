// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployConfig} from "../../script/Config.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeploymentChecks} from "../../script/DeploymentChecks.sol";
import {SmokeTest} from "../../script/SmokeTest.s.sol";
import {BagehotFactory} from "../../src/deploy/BagehotFactory.sol";
import {MisWiredFactory} from "../utils/MisWiredFactory.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Forwards every getter of a real factory from a different address: the deployment it
///         reports was not deployed by it, so `deployer() == factory` must fail.
contract ImpostorFactory {
    BagehotFactory internal immutable real;

    constructor(BagehotFactory real_) {
        real = real_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = address(real).staticcall(data);
        require(ok);
        return ret;
    }
}

/// @notice P18: chain guard, the local-only stand-ins, full local deployments of A and B passing
///         every §3.3 assertion and the functional smoke, and each assertion family rejecting a bad
///         deployment or configuration.
contract DeployScriptsTest is Test {
    Deploy internal deployer;
    SmokeTest internal smoker;

    function setUp() public {
        vm.warp(1_760_000_000); // a realistic clock: the sequencer mock reports "up since" well before now
        deployer = new Deploy();
        smoker = new SmokeTest();
    }

    // ------------------------------------------------------------------ chain guard

    function test_checkChain_allowsAnvilAndBaseSepolia() public {
        deployer.checkChain(31_337);
        deployer.checkChain(84_532);
    }

    function test_checkChain_ethereumMainnet_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 1));
        deployer.checkChain(1);
    }

    function test_checkChain_baseWithoutForkFlag_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 8453));
        deployer.checkChain(8453);
    }

    function test_chainAllowed_forkFlagAndLocalAnvil() public view {
        assertTrue(deployer.chainAllowed(8453, true, true), "8453: fork flag and a local anvil");
        assertFalse(deployer.chainAllowed(8453, true, false), "8453: the flag alone is not enough (ADR-0019)");
        assertFalse(deployer.chainAllowed(8453, false, true), "8453: an anvil alone is not enough");
        assertFalse(deployer.chainAllowed(1, true, true), "nothing admits Ethereum mainnet");
        assertTrue(
            deployer.chainAllowed(31_337, false, false) && deployer.chainAllowed(84_532, false, false),
            "anvil, Sepolia"
        );
    }

    /// @dev Without a fork there is no RPC to answer `anvil_nodeInfo`: not a local anvil.
    function test_isLocalAnvil_withoutRpc_false() public {
        assertFalse(deployer.isLocalAnvil());
    }

    function test_checkChain_otherChains_revert() public {
        uint256[4] memory ids = [uint256(10), 137, 42_161, 11_155_111];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, ids[i]));
            deployer.checkChain(ids[i]);
        }
    }

    /// @dev The acceptance criterion: running the deployment on chain 1 or 8453 (no fork flag) reverts.
    function test_run_onEthereumMainnet_reverts() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 1));
        deployer.run();
    }

    function test_run_onBaseWithoutForkFlag_reverts() public {
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 8453));
        deployer.run();
    }

    /// @dev While the factory carries local-only stand-ins, Base Sepolia passes the guard but cannot
    ///      deploy.
    function test_deploy_onBaseSepolia_refusesStandIns() public {
        DeployConfig memory c = deployer.loadConfig(31_337);
        vm.chainId(84_532);
        vm.expectRevert(abi.encodeWithSelector(Deploy.StandInsAreLocalOnly.selector, 84_532));
        deployer.deploy(c);
    }

    function test_loadConfig_missingFile_reverts() public {
        assertTrue(vm.exists(deployer.configPath(31_337)));
        assertFalse(vm.exists(deployer.configPath(84_532)), "no Base Sepolia config yet");
        vm.expectRevert();
        deployer.loadConfig(84_532);
    }

    // ------------------------------------------------------------------ local deployments

    function _local(bool variantB) internal returns (BagehotFactory f, DeployConfig memory c) {
        c = deployer.loadConfig(31_337);
        if (variantB) (c.variantB, c.poolShareBps) = (true, 0);
        (f, c) = deployer.deploy(c); // asserts §3.3 internally
    }

    function test_deployA_passesChecksAndSmoke() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        assertEq(f.stabilityPool(), f.strategy(), "A: the pool is the strategy");
        assertEq(f.auctionHouse(), address(0), "A: no auction house");
        smoker.smoke(f, c, makeAddr("smoker"));
    }

    function test_deployB_passesChecksAndSmoke() public {
        (BagehotFactory f, DeployConfig memory c) = _local(true);
        assertEq(f.stabilityPool(), address(0), "B: no pool");
        assertEq(f.auctionHouse(), f.strategy(), "B: the auction house is the strategy");
        smoker.smoke(f, c, makeAddr("smoker"));
    }

    function test_factory_everyWiredContractDeployedAndWiredByIt() public {
        (BagehotFactory f,) = _local(false);
        assertEq(f.token().deployer(), address(f));
        assertEq(f.vaultManager().deployer(), address(f));
        assertEq(f.sorted().deployer(), address(f));
        assertEq(f.redemptionModule().deployer(), address(f));
        assertTrue(
            f.token().wired() && f.vaultManager().wired() && f.sorted().wired()
                && f.redemptionModule().wired()
        );
    }

    // ------------------------------------------------------------------ the checks reject bad deployments

    function _expectCheckFails(BagehotFactory f, DeployConfig memory c, string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(DeploymentChecks.DeploymentCheckFailed.selector, what));
        this.runCheck(f, c);
    }

    function runCheck(BagehotFactory f, DeployConfig memory c) external view {
        DeploymentChecks.check(f, c);
    }

    function test_check_impostorFactory_failsDeployerCheck() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory impostor = BagehotFactory(address(new ImpostorFactory(f)));
        _expectCheckFails(impostor, c, "token: deployer == factory and wired");
    }

    function test_check_wrongVariantExpected_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.variantB = true;
        _expectCheckFails(f, c, "variant");
    }

    function test_check_wrongWeth_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.weth = address(0xBEEF);
        _expectCheckFails(f, c, "vaultManager.WETH");
    }

    function test_check_wrongPriceFeed_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.priceFeed = address(0xFEED);
        _expectCheckFails(f, c, "oracle.priceFeed == configured");
    }

    function test_check_parameterMismatch_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.mcr += 1;
        _expectCheckFails(f, c, "MCR");
    }

    function test_check_constraint1_penaltyTooLarge_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.liquidationPenalty = c.mcr - 1e18; // WAD + penalty == MCR
        _expectCheckFails(f, c, "constraint 1: WAD + LIQUIDATION_PENALTY < MCR");
    }

    function test_check_constraint5_failureDurationNotAboveStaleness_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.oracleFailureDuration = c.staleness;
        _expectCheckFails(f, c, "constraint 5: ORACLE_FAILURE_DURATION > STALENESS");
    }

    /// @dev ADR-0031's motivating fault: the token wired to another strategy than the VaultManager.
    function test_check_tokenWiredToAnotherStrategy_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory bad = BagehotFactory(address(new MisWiredFactory(_paramsOf(f, c), 1)));
        _expectCheckFails(bad, c, "token.strategy");
    }

    /// @dev §3.3 constraint 7: an auction house given to the RedemptionModule in deployment A.
    function test_check_constraint7_auctionHouseInA_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory bad = BagehotFactory(address(new MisWiredFactory(_paramsOf(f, c), 2)));
        _expectCheckFails(bad, c, "redemptionModule.auctionHouse (constraint 7)");
    }

    function _paramsOf(BagehotFactory, DeployConfig memory c)
        internal
        pure
        returns (BagehotFactory.Params memory p)
    {
        p.weth = c.weth;
        (p.priceFeed, p.sequencerFeed) = (c.priceFeed, c.sequencerFeed);
        (p.mcr, p.minDebt, p.gasReserve, p.ratePerSecond, p.poolShareBps) =
        (c.mcr, c.minDebt, c.gasReserve, c.ratePerSecond, c.poolShareBps);
        p.maxHintSteps = c.maxHintSteps;
        (p.staleness, p.gracePeriod, p.minPrice, p.maxPrice) =
        (c.staleness, c.gracePeriod, c.minPrice, c.maxPrice);
        (p.oracleGas, p.oraclePostFailureGas) = (c.oracleGas, c.oraclePostFailureGas);
        (p.redemptionFeeFloor, p.beta, p.baseRateDecay) = (c.redemptionFeeFloor, c.beta, c.baseRateDecay);
        p.criticalTcr = c.criticalTcr;
        (p.tokenName, p.tokenSymbol) = (c.tokenName, c.tokenSymbol);
    }

    function test_check_vaultManagerWiredToAnotherLedger_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory bad = BagehotFactory(address(new MisWiredFactory(_paramsOf(f, c), 3)));
        _expectCheckFails(bad, c, "vaultManager.deficitLedger");
    }

    function test_check_tokenUnwired_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory bad = BagehotFactory(address(new MisWiredFactory(_paramsOf(f, c), 4)));
        _expectCheckFails(bad, c, "token: deployer == factory and wired");
    }

    function test_check_wrongSequencerFeed_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        c.sequencerFeed = c.priceFeed;
        _expectCheckFails(f, c, "oracle.sequencerFeed == configured");
    }

    /// @dev §3.3 constraint 5's first half: CRITICAL_TCR above MCR is refused before broadcast.
    function test_deploy_criticalTcrAboveMcr_refused() public {
        DeployConfig memory c = deployer.loadConfig(31_337);
        c.criticalTcr = c.mcr + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentChecks.DeploymentCheckFailed.selector, "constraint 5: WAD <= CRITICAL_TCR <= MCR"
            )
        );
        deployer.deploy(c);
    }

    // ------------------------------------------------------------------ local-only, size, gas

    function test_factory_offLocalChain_reverts() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory.Params memory p = _paramsOf(f, c);
        vm.chainId(84_532);
        vm.expectRevert(abi.encodeWithSelector(BagehotFactory.StandInsAreLocalOnly.selector, 84_532));
        new BagehotFactory(p);
    }

    /// @dev P18-1: the factory must stay deployable — EIP-3860 initcode limit and a 16,777,216 gas cap
    ///      per transaction (EIP-7825). Fails here, in CI, before it fails a deployment.
    function test_factory_initcodeAndGasWithinLimits() public {
        assertLt(type(BagehotFactory).creationCode.length + 1024, 49_152, "initcode (+1 KiB for arguments)");
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory.Params memory p = _paramsOf(f, c);
        uint256 g = gasleft();
        new BagehotFactory(p);
        assertLt(g - gasleft(), 16_777_216, "factory deployment gas");
    }

    // ------------------------------------------------------------------ smoke and manifest

    /// @dev Security review M-1: on anvil (--block-time 2) blocks pass between deploy and smoke.
    function test_smokeAfterBlocksElapsed_A() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        smoker.smoke(f, c, makeAddr("smoker"));
    }

    function test_smokeAfterBlocksElapsed_B() public {
        (BagehotFactory f, DeployConfig memory c) = _local(true);
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        smoker.smoke(f, c, makeAddr("smoker"));
    }

    /// @dev The smoke test measures steps, so earlier positions on the chain do not break it.
    function test_smokeTwice_secondRunSeesPriorActivity() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        smoker.smoke(f, c, makeAddr("first"));
        smoker.smoke(f, c, makeAddr("second"));
    }

    /// @dev Security review M-3: outside a broadcast nothing is written to deployments/. Forge refuses
    ///      any access to that directory until it exists (human action 2), so a write attempt would
    ///      revert here: `run()` completing is the assertion.
    function test_run_withoutBroadcast_writesNoManifest() public {
        BagehotFactory f = deployer.run();
        assertTrue(address(f).code.length > 0);
    }

    /// @dev Both variants in one manifest, read back and fully re-checked.
    function test_manifest_roundTrip_bothVariants() public {
        string memory path = "cache/manifest-roundtrip-test.json";
        if (vm.exists(path)) vm.removeFile(path);
        (BagehotFactory fa, DeployConfig memory ca) = _local(false);
        (BagehotFactory fb, DeployConfig memory cb) = _local(true);
        deployer.writeManifest(fa, ca, path);
        deployer.writeManifest(fb, cb, path);
        (BagehotFactory ra,) = smoker.loadDeployment(path, "A");
        (BagehotFactory rb,) = smoker.loadDeployment(path, "B");
        assertEq(address(ra), address(fa), "A read back");
        assertEq(address(rb), address(fb), "B read back, A kept");
        vm.removeFile(path);
    }

    // ------------------------------------------------------------------ manifest provenance (P18-3)

    function test_provenance_localDirtyTreeAllowed() public view {
        deployer.checkProvenance(31_337, "30799172bbbd-dirty", "0.8.28");
        deployer.checkProvenance(31_337, "unknown", "0.8.28");
    }

    function test_provenance_sepoliaDirtyTree_refused() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ProvenanceRefused.selector, "working tree is dirty"));
        deployer.checkProvenance(84_532, "30799172bbbd-dirty", "0.8.28");
    }

    function test_provenance_sepoliaUnknownCommit_refused() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ProvenanceRefused.selector, "GIT_COMMIT not set"));
        deployer.checkProvenance(84_532, "unknown", "0.8.28");
    }

    function test_provenance_sepoliaCleanTree_allowed() public view {
        deployer.checkProvenance(84_532, "30799172bbbd", "0.8.28");
    }

    function test_provenance_solcMismatch_refusedEverywhere() public {
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.ProvenanceRefused.selector, "solc differs from foundry.toml")
        );
        deployer.checkProvenance(31_337, "30799172bbbd", "0.8.29");
    }
}
