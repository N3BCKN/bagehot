// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Blueprints} from "../../script/Blueprints.sol";
import {DeployConfig} from "../../script/Config.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeploymentChecks} from "../../script/DeploymentChecks.sol";
import {SmokeTest} from "../../script/SmokeTest.s.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {BagehotFactory} from "../../src/deploy/BagehotFactory.sol";
import {StandInShutdownModule} from "../../src/mocks/StandInShutdownModule.sol";
import {StandInStrategy} from "../../src/mocks/StandInStrategy.sol";
import {MisWiredFactory} from "../utils/MisWiredFactory.sol";
import {StabilityPoolHarness} from "../utils/PoolMocks.sol";
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

/// @notice Exposes the blueprint library's internal functions to `vm.expectRevert`.
contract BlueprintsCaller {
    function initcode(uint256 role, bytes memory creationCode) external pure returns (bytes memory) {
        return Blueprints.initcode(role, creationCode);
    }
}

/// @notice Creates the factory from raw initcode so `gasleft()` sees the CREATE: forge's test
///         preprocessor rewrites `new X(...)` in tests into the `deployCode` cheatcode, whose cost is
///         not metered (the P18 reading of 1,998 gas was this artefact).
contract FactoryGasMeter {
    function deploy(BagehotFactory.Params memory p, address[9] memory b, bytes32[9] memory h)
        external
        returns (BagehotFactory f, uint256 used)
    {
        bytes memory init = abi.encodePacked(type(BagehotFactory).creationCode, abi.encode(p, b, h));
        uint256 g = gasleft();
        address a;
        assembly ("memory-safe") {
            a := create(0, add(init, 0x20), mload(init))
        }
        used = g - gasleft();
        require(a != address(0), "factory creation failed");
        f = BagehotFactory(a);
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
        (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
        vm.chainId(84_532);
        vm.expectRevert(abi.encodeWithSelector(BagehotFactory.StandInsAreLocalOnly.selector, 84_532));
        new BagehotFactory(p, b, h);
    }

    /// @dev P18-1 / ADR-0035: the deployment must stay deployable. The factory's initcode no longer
    ///      carries the protocol (EIP-3860 stops binding); the binding limit is the deployment
    ///      transaction's gas against EIP-7825's 2^24 cap, kept with a 1M margin; every contract's
    ///      runtime and every blueprint fits EIP-170. Fails here, in CI, before it fails a deployment.
    function test_factory_initcodeAndGasWithinLimits() public {
        uint256 initcode = type(BagehotFactory).creationCode.length;
        assertLt(initcode, 8192, "factory initcode is small: it embeds no contract");
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        BagehotFactory.Params memory p = _paramsOf(f, c);
        (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
        (BagehotFactory f2, uint256 execution) = new FactoryGasMeter().deploy(p, b, h);
        // plus the transaction's intrinsic cost (every calldata byte priced as nonzero, EIP-3860's 2 gas
        // per initcode word). An estimate under this test's EVM: anvil's receipt was 8,358,263 against
        // 8,308,398 here (2026-10-26); the 1M margin absorbs such differences between hardforks.
        uint256 calldataBytes = initcode + abi.encode(p, b, h).length;
        uint256 used = execution + 21_000 + 16 * calldataBytes + 2 * ((calldataBytes + 31) / 32);
        assertLt(used, 16_777_216 - 1_000_000, "deployment transaction gas (1M margin under 2^24)");
        address[9] memory roles = [
            address(f2.token()),
            address(f2.oracle()),
            address(f2.vaultManager()),
            address(f2.sorted()),
            address(f2.redemptionModule()),
            f2.strategy(),
            f2.deficitLedger(),
            f2.shutdownModule(),
            address(f2.hintHelpers())
        ];
        uint256 runtime;
        for (uint256 i; i < 9; ++i) {
            assertLe(roles[i].code.length, 24_576, "runtime within EIP-170");
            assertLe(b[i].code.length, 24_576, "blueprint within EIP-170");
            runtime += roles[i].code.length;
        }
        emit log_named_uint("factory initcode bytes", initcode);
        emit log_named_uint("factory CREATE gas (execution + deposits)", execution);
        emit log_named_uint("deployment transaction gas, estimate", used);
        emit log_named_uint("runtime created bytes", runtime);
    }

    // ------------------------------------------------------------------ blueprints (ADR-0035)

    function _params() internal returns (BagehotFactory.Params memory p) {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        p = _paramsOf(f, c);
    }

    function test_blueprint_noCode_revertsForEveryRole() public {
        BagehotFactory.Params memory p = _params();
        for (uint256 i; i < 9; ++i) {
            (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
            b[i] = makeAddr("empty");
            vm.expectRevert(abi.encodeWithSelector(BagehotFactory.BlueprintNoCode.selector, i));
            new BagehotFactory(p, b, h);
        }
    }

    /// @dev A callable contract is refused even when the hash passed with it is its own.
    function test_blueprint_notInert_revertsForEveryRole() public {
        BagehotFactory.Params memory p = _params();
        address callable = address(new StandInStrategy());
        for (uint256 i; i < 9; ++i) {
            (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
            (b[i], h[i]) = (callable, callable.codehash);
            vm.expectRevert(abi.encodeWithSelector(BagehotFactory.BlueprintNotInert.selector, i));
            new BagehotFactory(p, b, h);
        }
    }

    function test_blueprint_hashMismatch_revertsForEveryRole() public {
        BagehotFactory.Params memory p = _params();
        for (uint256 i; i < 9; ++i) {
            (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
            h[i] = bytes32(uint256(h[i]) ^ 1);
            vm.expectRevert(abi.encodeWithSelector(BagehotFactory.BlueprintMismatch.selector, i));
            new BagehotFactory(p, b, h);
        }
    }

    /// @dev Swapping two blueprints with their hashes passes the factory's own check (each hash is
    ///      the blueprint's), deploys the wrong code into two roles, and is refused by the checks.
    function test_blueprint_swappedRoles_failsChecks() public {
        (BagehotFactory f0, DeployConfig memory c) = _local(false);
        (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
        // the ledger and the strategy stand-ins: both construct, but in each other's role
        (b[5], b[6], h[5], h[6]) = (b[6], b[5], h[6], h[5]);
        vm.expectRevert(); // the ledger stand-in takes an argument the strategy's constructor does not
        new BagehotFactory(_paramsOf(f0, c), b, h);
    }

    /// @dev A blueprint that is not today's build but deploys working code — in A's strategy role, the
    ///      pool test harness (a StabilityPool with one extra function, same constructor and `wire`) —
    ///      passes the factory and every functional check, and is refused by the digest check.
    function test_blueprint_notTodaysBuild_failsDigestCheck() public {
        (BagehotFactory f0, DeployConfig memory c) = _local(false);
        (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
        bytes memory altered = type(StabilityPoolHarness).creationCode;
        b[5] = Blueprints.deploy(5, altered);
        h[5] = Blueprints.codehash(altered);
        BagehotFactory bad = new BagehotFactory(_paramsOf(f0, c), b, h);
        _expectCheckFails(bad, c, "blueprints: created from today's build");
    }

    function test_blueprint_isInertAndDeployedOnce() public {
        (address[9] memory b1, bytes32[9] memory h1) = Blueprints.deployAll(false);
        (address[9] memory b2,) = Blueprints.deployAll(false);
        for (uint256 i; i < 9; ++i) {
            assertEq(b1[i], b2[i], "a second run finds the same blueprint");
            assertEq(b1[i].codehash, h1[i], "the address holds the hashed code");
            assertEq(uint8(b1[i].code[0]), 0xFE, "leading invalid opcode");
            (bool ok,) = b1[i].call{gas: 100_000}("");
            assertFalse(ok, "a blueprint cannot be called");
        }
    }

    function test_blueprint_tooLarge_reverts() public {
        BlueprintsCaller caller = new BlueprintsCaller();
        caller.initcode(0, new bytes(24_575)); // 24,576 with the 0xFE byte: the limit
        vm.expectRevert(abi.encodeWithSelector(Blueprints.BlueprintTooLarge.selector, 3, 24_577));
        caller.initcode(3, new bytes(24_576));
    }

    /// @dev A constructor that reverts inside the factory re-throws its own error.
    function test_factory_revertingConstructor_bubbles() public {
        BagehotFactory.Params memory p = _params();
        p.criticalTcr = 1e18 - 1;
        (address[9] memory b, bytes32[9] memory h) = Blueprints.deployAll(false);
        vm.expectRevert(StandInShutdownModule.StandInInvalid.selector);
        new BagehotFactory(p, b, h);
    }

    function test_runtimeMatches_artifactAndMismatches() public {
        (BagehotFactory f,) = _local(false);
        address token = address(f.token());
        assertTrue(Blueprints.runtimeMatches(token, "StableToken.sol:StableToken"));
        assertFalse(Blueprints.runtimeMatches(token, "OracleAdapter.sol:OracleAdapter"), "another contract");
        bytes memory code = token.code;
        code[code.length / 2] = bytes1(uint8(code[code.length / 2]) ^ 0xFF);
        vm.etch(token, code);
        assertFalse(Blueprints.runtimeMatches(token, "StableToken.sol:StableToken"), "one byte changed");
    }

    /// @dev Security review P19 I-1: a byte that is zero in the artifact but is not an immutable (a STOP,
    ///      a zero PUSH operand, metadata) must match exactly; only the reported immutables are masked.
    function test_runtimeMatches_zeroByteOutsideImmutables_isNotAWildcard() public {
        (BagehotFactory f,) = _local(false);
        address token = address(f.token());
        bytes memory artifact = vm.getDeployedCode("StableToken.sol:StableToken");
        (uint256[] memory starts, uint256[] memory lengths) =
            Blueprints.immutableRanges("StableToken.sol:StableToken");
        assertGt(starts.length, 0, "StableToken has immutables");
        bytes memory code = token.code;
        assertTrue(Blueprints.runtimeMatchesMasked(code, artifact, starts, lengths), "as deployed");
        uint256 k;
        for (; k < artifact.length; ++k) {
            if (artifact[k] != 0) continue;
            bool inImmutable;
            for (uint256 r; r < starts.length; ++r) {
                if (k >= starts[r] && k < starts[r] + lengths[r]) inImmutable = true;
            }
            if (!inImmutable) break;
        }
        assertLt(k, artifact.length, "found a zero byte outside the immutables");
        code[k] = 0x01;
        assertFalse(Blueprints.runtimeMatchesMasked(code, artifact, starts, lengths), "zero byte changed");
    }

    function test_check_runtimeCodeChanged_fails() public {
        (BagehotFactory f, DeployConfig memory c) = _local(false);
        address hints = address(f.hintHelpers());
        bytes memory code = hints.code;
        code[code.length - 1] = bytes1(uint8(code[code.length - 1]) ^ 0xFF);
        vm.etch(hints, code);
        _expectCheckFails(f, c, "runtime code: hintHelpers is its artifact");
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
