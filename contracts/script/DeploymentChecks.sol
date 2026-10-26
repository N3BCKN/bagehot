// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BagehotFactory} from "../src/deploy/BagehotFactory.sol";
import {StandInDeficitLedger} from "../src/mocks/StandInDeficitLedger.sol";
import {StandInShutdownModule} from "../src/mocks/StandInShutdownModule.sol";
import {Blueprints} from "./Blueprints.sol";
import {DeployConfig} from "./Config.s.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The deployment assertions of spec §3.3, run by `Deploy.s.sol` before anything is broadcast
///         and again by `SmokeTest.s.sol` against the live chain (ADR-0031, P11-1):
///         constraint 8 (every wired address is the factory's contract for that role, the peer
///         graph agrees, every immutable `token`/`weth`/`oracle` is the deployment's, every wired
///         contract has `deployer() == factory` and `wired()`); the feeds have code and are the
///         configured ones; every parameter equals the configuration; constraints 1, 3, 5 and 7;
///         the blueprints the factory created from are today's build, and every deployed contract's
///         runtime code is its artifact's (ADR-0035).
///         Constraints 2 (LIQUIDATION_PENALTY/MIN_DEBT across contracts) and 4 (oracle gas, feed
///         decimals) are checked as far as contracts exist: 4 by the OracleAdapter constructor and
///         re-read here; 2 once the strategy contracts carry the parameters (P19, P33).
library DeploymentChecks {
    error DeploymentCheckFailed(string what);

    uint256 internal constant WAD = 1e18;
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function check(BagehotFactory f, DeployConfig memory c) internal view {
        _code(f);
        _deployerAndWired(f);
        _graph(f, c);
        _immutables(f, c);
        _params(f, c);
        _constraints(f, c);
        _provenance(f);
        _blueprints(f);
    }

    /// @dev ADR-0035: the code hashes the factory checked its blueprints against are those of today's
    ///      build, and each role's runtime code is its artifact's (immutables aside, see
    ///      `Blueprints.runtimeMatches`).
    function _blueprints(BagehotFactory f) private view {
        _req(f.blueprintsDigest() == Blueprints.digest(), "blueprints: created from today's build");
        address[9] memory roles = [
            address(f.token()),
            address(f.oracle()),
            address(f.vaultManager()),
            address(f.sorted()),
            address(f.redemptionModule()),
            f.strategy(),
            f.deficitLedger(),
            f.shutdownModule(),
            address(f.hintHelpers())
        ];
        string[9] memory a = Blueprints.artifacts();
        string[9] memory n = Blueprints.names();
        for (uint256 i; i < 9; ++i) {
            _req(
                Blueprints.runtimeMatches(roles[i], vm.getDeployedCode(a[i])),
                string.concat("runtime code: ", n[i], " is its artifact")
            );
        }
    }

    /// @dev §3.3 constraint 8 "the contract the factory created for that role", also for contracts
    ///      without `deployer()`: each role is the factory's CREATE address for its creation index, and
    ///      the factory's nonce shows it created nothing else (CREATE nonces start at 1).
    function _provenance(BagehotFactory f) private view {
        address fa = address(f);
        _req(
            address(f.token()) == vm.computeCreateAddress(fa, 1),
            "provenance: token is the factory's 1st creation"
        );
        _req(
            address(f.oracle()) == vm.computeCreateAddress(fa, 2),
            "provenance: oracle is the factory's 2nd creation"
        );
        _req(
            address(f.vaultManager()) == vm.computeCreateAddress(fa, 3), "provenance: vaultManager is the 3rd"
        );
        _req(address(f.sorted()) == vm.computeCreateAddress(fa, 4), "provenance: sorted is the 4th");
        _req(
            address(f.redemptionModule()) == vm.computeCreateAddress(fa, 5),
            "provenance: redemptionModule is the 5th"
        );
        _req(f.strategy() == vm.computeCreateAddress(fa, 6), "provenance: strategy is the 6th");
        _req(f.deficitLedger() == vm.computeCreateAddress(fa, 7), "provenance: deficitLedger is the 7th");
        _req(f.shutdownModule() == vm.computeCreateAddress(fa, 8), "provenance: shutdownModule is the 8th");
        _req(address(f.hintHelpers()) == vm.computeCreateAddress(fa, 9), "provenance: hintHelpers is the 9th");
        _req(vm.getNonce(fa) == 10, "provenance: the factory created exactly nine contracts");
    }

    function _feedDecimals(DeployConfig memory c) private view returns (uint8) {
        (bool ok, bytes memory ret) = c.priceFeed.staticcall(abi.encodeWithSignature("decimals()"));
        _req(ok && ret.length == 32, "price feed answers decimals()");
        return abi.decode(ret, (uint8));
    }

    function _req(bool ok, string memory what) private pure {
        if (!ok) revert DeploymentCheckFailed(what);
    }

    function _code(BagehotFactory f) private view {
        _req(address(f).code.length > 0, "factory has code");
        _req(address(f.token()).code.length > 0, "token has code");
        _req(address(f.oracle()).code.length > 0, "oracle has code");
        _req(address(f.vaultManager()).code.length > 0, "vaultManager has code");
        _req(address(f.sorted()).code.length > 0, "sorted has code");
        _req(address(f.redemptionModule()).code.length > 0, "redemptionModule has code");
        _req(address(f.hintHelpers()).code.length > 0, "hintHelpers has code");
        _req(f.strategy().code.length > 0, "strategy has code");
        _req(f.deficitLedger().code.length > 0, "deficitLedger has code");
        _req(f.shutdownModule().code.length > 0, "shutdownModule has code");
    }

    /// @dev §3.3 constraint 8: the factory deployed and wired every wired contract (P11-1: a CREATE2
    ///      proxy or an EOA as `deployer` would leave it unwireable or wireable by someone else).
    function _deployerAndWired(BagehotFactory f) private view {
        address fa = address(f);
        _req(f.token().deployer() == fa && f.token().wired(), "token: deployer == factory and wired");
        _req(
            f.vaultManager().deployer() == fa && f.vaultManager().wired(),
            "vaultManager: deployer == factory and wired"
        );
        _req(f.sorted().deployer() == fa && f.sorted().wired(), "sorted: deployer == factory and wired");
        _req(
            f.redemptionModule().deployer() == fa && f.redemptionModule().wired(),
            "redemptionModule: deployer == factory and wired"
        );
    }

    /// @dev §3.3 constraint 8: each contract's wired peers are the factory's contracts for each role,
    ///      the same everywhere; and constraint 7 for the auction house.
    function _graph(BagehotFactory f, DeployConfig memory c) private view {
        address vm_ = address(f.vaultManager());
        address strategy = f.strategy();
        address ledger = f.deficitLedger();
        address shutdown = f.shutdownModule();
        address pool = c.variantB ? address(0) : strategy;
        address house = c.variantB ? strategy : address(0);
        _req(f.variantB() == c.variantB, "variant");
        _req(f.stabilityPool() == pool && f.auctionHouse() == house, "factory roles per variant (1.2)");
        // VaultManager
        _req(address(f.vaultManager().sorted()) == address(f.sorted()), "vaultManager.sorted");
        _req(f.vaultManager().strategy() == strategy, "vaultManager.strategy");
        _req(f.vaultManager().stabilityPool() == pool, "vaultManager.stabilityPool");
        _req(
            f.vaultManager().redemptionModule() == address(f.redemptionModule()),
            "vaultManager.redemptionModule"
        );
        _req(f.vaultManager().deficitLedger() == ledger, "vaultManager.deficitLedger");
        _req(f.vaultManager().shutdownModule() == shutdown, "vaultManager.shutdownModule");
        // SortedPositions, HintHelpers
        _req(address(f.sorted().vaultManager()) == vm_, "sorted.vaultManager");
        _req(address(f.hintHelpers().vaultManager()) == vm_, "hintHelpers.vaultManager");
        _req(address(f.hintHelpers().sorted()) == address(f.sorted()), "hintHelpers.sorted");
        // RedemptionModule (constraint 7: auctionHouse)
        _req(address(f.redemptionModule().vaultManager()) == vm_, "redemptionModule.vaultManager");
        _req(address(f.redemptionModule().shutdownModule()) == shutdown, "redemptionModule.shutdownModule");
        _req(f.redemptionModule().auctionHouse() == house, "redemptionModule.auctionHouse (constraint 7)");
        // StableToken roles: minter, burners, mover
        _req(f.token().vaultManager() == vm_, "token.vaultManager");
        _req(f.token().strategy() == strategy, "token.strategy");
        _req(f.token().deficitLedger() == ledger, "token.deficitLedger");
        _req(f.token().shutdownModule() == shutdown, "token.shutdownModule");
        // stand-ins (local only) read the same peers
        _req(StandInDeficitLedger(ledger).vaultManager() == vm_, "deficitLedger.vaultManager");
        _req(address(StandInShutdownModule(shutdown).vaultManager()) == vm_, "shutdownModule.vaultManager");
        _req(
            StandInShutdownModule(shutdown).auctionHouse() == house,
            "shutdownModule.auctionHouse (constraint 7)"
        );
    }

    /// @dev §3.3 constraint 8: every immutable token/weth/oracle is the deployment's; the feeds are the
    ///      configured ones and have code (P11-1, P12 review F4).
    function _immutables(BagehotFactory f, DeployConfig memory c) private view {
        _req(address(f.vaultManager().WETH()) == c.weth, "vaultManager.WETH");
        _req(address(f.vaultManager().token()) == address(f.token()), "vaultManager.token");
        _req(address(f.vaultManager().oracle()) == address(f.oracle()), "vaultManager.oracle");
        _req(address(f.redemptionModule().token()) == address(f.token()), "redemptionModule.token");
        _req(address(f.redemptionModule().oracle()) == address(f.oracle()), "redemptionModule.oracle");
        _req(address(f.oracle().priceFeed()) == c.priceFeed, "oracle.priceFeed == configured");
        _req(address(f.oracle().sequencerFeed()) == c.sequencerFeed, "oracle.sequencerFeed == configured");
        _req(c.priceFeed.code.length > 0, "price feed has code");
        _req(c.sequencerFeed.code.length > 0, "sequencer feed has code");
        _req(c.weth.code.length > 0, "WETH has code");
    }

    /// @dev Every parameter as configured (constructor ranges, constraint 6, are checked on-chain).
    function _params(BagehotFactory f, DeployConfig memory c) private view {
        _req(f.vaultManager().MCR() == c.mcr, "MCR");
        _req(f.vaultManager().MIN_DEBT() == c.minDebt, "MIN_DEBT");
        _req(f.vaultManager().GAS_RESERVE() == c.gasReserve, "GAS_RESERVE");
        _req(f.vaultManager().RATE_PER_SECOND() == c.ratePerSecond, "RATE_PER_SECOND");
        _req(f.vaultManager().POOL_SHARE_BPS() == c.poolShareBps, "POOL_SHARE_BPS");
        _req(f.vaultManager().POOL_HOOK_GAS() == c.poolHookGas, "POOL_HOOK_GAS");
        _req(f.sorted().MAX_HINT_STEPS() == c.maxHintSteps, "MAX_HINT_STEPS");
        _req(f.redemptionModule().REDEMPTION_FEE_FLOOR() == c.redemptionFeeFloor, "REDEMPTION_FEE_FLOOR");
        _req(f.redemptionModule().BETA() == c.beta, "BETA");
        _req(f.redemptionModule().BASE_RATE_DECAY() == c.baseRateDecay, "BASE_RATE_DECAY");
        _req(f.oracle().STALENESS() == c.staleness, "STALENESS");
        _req(f.oracle().GRACE_PERIOD() == c.gracePeriod, "GRACE_PERIOD");
        _req(f.oracle().MIN_PRICE() == c.minPrice, "MIN_PRICE");
        _req(f.oracle().MAX_PRICE() == c.maxPrice, "MAX_PRICE");
        _req(f.oracle().ORACLE_GAS() == c.oracleGas, "ORACLE_GAS");
        _req(f.oracle().ORACLE_POST_FAILURE_GAS() == c.oraclePostFailureGas, "ORACLE_POST_FAILURE_GAS");
        _req(StandInShutdownModule(f.shutdownModule()).CRITICAL_TCR() == c.criticalTcr, "CRITICAL_TCR");
    }

    /// @dev §3.3 constraints that span contracts or parameters and are enforced only here.
    function _constraints(BagehotFactory f, DeployConfig memory c) private view {
        _req(WAD + c.liquidationPenalty < c.mcr, "constraint 1: WAD + LIQUIDATION_PENALTY < MCR");
        _req(!c.variantB || f.vaultManager().POOL_SHARE_BPS() == 0, "constraint 3: POOL_SHARE_BPS = 0 in B");
        _req(f.oracle().FEED_DECIMALS() <= 18, "constraint 4: FEED_DECIMALS <= 18");
        _req(c.criticalTcr <= c.mcr && c.criticalTcr >= WAD, "constraint 5: WAD <= CRITICAL_TCR <= MCR");
        _req(f.oracle().FEED_DECIMALS() == _feedDecimals(c), "FEED_DECIMALS as the feed reports");
        _req(c.oracleFailureDuration > c.staleness, "constraint 5: ORACLE_FAILURE_DURATION > STALENESS");
    }
}
