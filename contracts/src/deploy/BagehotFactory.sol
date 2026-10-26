// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../core/HintHelpers.sol";
import {OracleAdapter} from "../core/OracleAdapter.sol";
import {SortedPositions} from "../core/SortedPositions.sol";
import {StableToken} from "../core/StableToken.sol";
import {VaultManager} from "../core/VaultManager.sol";
import {StabilityPool} from "../liquidation/StabilityPool.sol";
import {RedemptionModule} from "../redemption/RedemptionModule.sol";

/// @title BagehotFactory
/// @notice Deploys every contract of one deployment variant and wires them, all inside its own
///         constructor: one transaction, no un-wired window, no caller-supplied role addresses
///         (ADR-0021, P11-1). Every wired contract records this factory as its `deployer`, and only
///         the factory could ever call its `wire`, which it does here, once. No CREATE2 / `{salt:}`.
///         The creation code of each role is read from a blueprint deployed beforehand (ADR-0035): a
///         data contract whose code is `0xFE ‖ creationCode`, uncallable because of the leading
///         invalid opcode. The caller supplies where code is read from, never which contract fills a
///         role: each blueprint must match the code hash passed with it, the deploy script derives
///         those hashes from the build artifacts, and `blueprintsDigest` lets the checks re-derive
///         them after the fact.
///         The strategy is the real StabilityPool in deployment A (P19). Until the DeficitLedger
///         (P21), ShutdownModule and DutchAuctionHouse (P33) exist, those roles are filled by LOCAL-ONLY
///         stand-ins (`src/mocks/StandIn*`), and
///         the deployment script refuses to deploy this factory on any chain but 31337.
///         Cross-contract constraints (§3.3 1, 2, 5, 7, 8) are asserted by the deployment script and
///         the smoke test (`script/DeploymentChecks.sol`); each constructor and `wire` checks its own
///         arguments (§3.4).
contract BagehotFactory {
    /// @notice The factory still carries local-only stand-ins (P18-2): it deploys on chain 31337 only.
    error StandInsAreLocalOnly(uint256 chainId);
    /// @notice A blueprint has no code (ADR-0035).
    error BlueprintNoCode(uint256 role);
    /// @notice A blueprint's code does not start with 0xFE, so it could be called (ADR-0035).
    error BlueprintNotInert(uint256 role);
    /// @notice A blueprint's code hash differs from the one passed for its role (ADR-0035).
    error BlueprintMismatch(uint256 role);

    /// @notice Roles in creation order; `blueprints[i]` and `codehashes[i]` belong to role i.
    uint256 public constant ROLE_TOKEN = 0;
    uint256 public constant ROLE_ORACLE = 1;
    uint256 public constant ROLE_VAULT_MANAGER = 2;
    uint256 public constant ROLE_SORTED = 3;
    uint256 public constant ROLE_REDEMPTION_MODULE = 4;
    uint256 public constant ROLE_STRATEGY = 5;
    uint256 public constant ROLE_DEFICIT_LEDGER = 6;
    uint256 public constant ROLE_SHUTDOWN_MODULE = 7;
    uint256 public constant ROLE_HINT_HELPERS = 8;
    uint256 public constant ROLES = 9;

    uint256 internal constant LOCAL_CHAIN_ID = 31_337;

    struct Params {
        bool variantB;
        address weth;
        address priceFeed;
        address sequencerFeed;
        // VaultManager
        uint256 mcr;
        uint256 minDebt;
        uint256 gasReserve;
        uint256 ratePerSecond;
        uint256 poolShareBps;
        uint256 poolHookGas;
        uint256 liquidationPenalty; // StabilityPool (A)
        uint256 minDeposit; // StabilityPool (A)
        // SortedPositions
        uint256 maxHintSteps;
        // OracleAdapter
        uint256 staleness;
        uint256 gracePeriod;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 oracleGas;
        uint256 oraclePostFailureGas;
        // RedemptionModule
        uint256 redemptionFeeFloor;
        uint256 beta;
        uint256 baseRateDecay;
        // ShutdownModule (stand-in until its prompt)
        uint256 criticalTcr;
        // StableToken
        string tokenName;
        string tokenSymbol;
    }

    event Deployed(
        bool variantB,
        address token,
        address oracle,
        address vaultManager,
        address sorted,
        address redemptionModule,
        address hintHelpers,
        address strategy,
        address deficitLedger,
        address shutdownModule
    );

    bool public immutable variantB;
    uint256 public immutable deployBlock;
    StableToken public immutable token;
    OracleAdapter public immutable oracle;
    VaultManager public immutable vaultManager;
    SortedPositions public immutable sorted;
    RedemptionModule public immutable redemptionModule;
    HintHelpers public immutable hintHelpers;
    address public immutable strategy;
    address public immutable deficitLedger;
    address public immutable shutdownModule;
    /// @notice §1.2: the stability pool is the strategy in A and absent in B.
    address public immutable stabilityPool;
    /// @notice §3.3 constraint 7: the auction house is the strategy in B and absent in A.
    address public immutable auctionHouse;
    /// @notice keccak256(abi.encode(codehashes)): the blueprint code hashes this deployment was
    ///         created from, re-derived from the build artifacts by `DeploymentChecks`.
    bytes32 public immutable blueprintsDigest;

    /// @param blueprints Per role, a contract whose code is `0xFE ‖ creationCode` (ADR-0035).
    /// @param codehashes Per role, the expected `extcodehash` of its blueprint.
    constructor(Params memory p, address[ROLES] memory blueprints, bytes32[ROLES] memory codehashes) {
        if (block.chainid != LOCAL_CHAIN_ID) revert StandInsAreLocalOnly(block.chainid);
        // every blueprint is checked before anything is created
        for (uint256 i; i < ROLES; ++i) {
            _checkBlueprint(i, blueprints[i], codehashes[i]);
        }
        variantB = p.variantB;
        deployBlock = block.number;
        blueprintsDigest = keccak256(abi.encode(codehashes));
        address[ROLES] memory c = _createAll(p, blueprints);
        address pool_ = p.variantB ? address(0) : c[ROLE_STRATEGY];
        address house_ = p.variantB ? c[ROLE_STRATEGY] : address(0);
        // record everything before the wiring calls (checks-effects-interactions)
        (token, oracle, vaultManager, sorted, redemptionModule, hintHelpers) =
        (
            StableToken(c[ROLE_TOKEN]),
            OracleAdapter(c[ROLE_ORACLE]),
            VaultManager(c[ROLE_VAULT_MANAGER]),
            SortedPositions(c[ROLE_SORTED]),
            RedemptionModule(c[ROLE_REDEMPTION_MODULE]),
            HintHelpers(c[ROLE_HINT_HELPERS])
        );
        (strategy, deficitLedger, shutdownModule, stabilityPool, auctionHouse) =
        (c[ROLE_STRATEGY], c[ROLE_DEFICIT_LEDGER], c[ROLE_SHUTDOWN_MODULE], pool_, house_);

        SortedPositions(c[ROLE_SORTED]).wire(c[ROLE_VAULT_MANAGER]);
        VaultManager(c[ROLE_VAULT_MANAGER])
            .wire(
                c[ROLE_SORTED],
                c[ROLE_STRATEGY],
                pool_,
                c[ROLE_REDEMPTION_MODULE],
                c[ROLE_DEFICIT_LEDGER],
                c[ROLE_SHUTDOWN_MODULE]
            );
        RedemptionModule(c[ROLE_REDEMPTION_MODULE])
            .wire(c[ROLE_VAULT_MANAGER], c[ROLE_SHUTDOWN_MODULE], house_);
        StableToken(c[ROLE_TOKEN])
            .wire(c[ROLE_VAULT_MANAGER], c[ROLE_STRATEGY], c[ROLE_DEFICIT_LEDGER], c[ROLE_SHUTDOWN_MODULE]);
        if (!p.variantB) StabilityPool(pool_).wire(c[ROLE_VAULT_MANAGER], c[ROLE_DEFICIT_LEDGER]);
        emit Deployed(
            p.variantB,
            c[ROLE_TOKEN],
            c[ROLE_ORACLE],
            c[ROLE_VAULT_MANAGER],
            c[ROLE_SORTED],
            c[ROLE_REDEMPTION_MODULE],
            c[ROLE_HINT_HELPERS],
            c[ROLE_STRATEGY],
            c[ROLE_DEFICIT_LEDGER],
            c[ROLE_SHUTDOWN_MODULE]
        );
    }

    /// @dev Creates every role in role order (the CREATE nonces DeploymentChecks verifies).
    function _createAll(Params memory p, address[ROLES] memory blueprints)
        private
        returns (address[ROLES] memory c)
    {
        c[ROLE_TOKEN] = _create(blueprints[ROLE_TOKEN], abi.encode(p.tokenName, p.tokenSymbol));
        c[ROLE_ORACLE] = _create(
            blueprints[ROLE_ORACLE],
            abi.encode(
                p.priceFeed,
                p.sequencerFeed,
                p.staleness,
                p.gracePeriod,
                p.minPrice,
                p.maxPrice,
                p.oracleGas,
                p.oraclePostFailureGas
            )
        );
        c[ROLE_VAULT_MANAGER] = _create(
            blueprints[ROLE_VAULT_MANAGER],
            abi.encode(
                p.weth,
                c[ROLE_TOKEN],
                c[ROLE_ORACLE],
                p.mcr,
                p.minDebt,
                p.gasReserve,
                p.ratePerSecond,
                p.poolShareBps,
                p.poolHookGas
            )
        );
        c[ROLE_SORTED] = _create(blueprints[ROLE_SORTED], abi.encode(p.maxHintSteps));
        c[ROLE_REDEMPTION_MODULE] = _create(
            blueprints[ROLE_REDEMPTION_MODULE],
            abi.encode(c[ROLE_TOKEN], c[ROLE_ORACLE], p.redemptionFeeFloor, p.beta, p.baseRateDecay)
        );
        // A: the real StabilityPool (P19); B: the stand-in until the DutchAuctionHouse (P33)
        c[ROLE_STRATEGY] = _create(
            blueprints[ROLE_STRATEGY],
            p.variantB ? bytes("") : abi.encode(p.weth, c[ROLE_TOKEN], p.liquidationPenalty, p.minDeposit)
        );
        address house_ = p.variantB ? c[ROLE_STRATEGY] : address(0);
        c[ROLE_DEFICIT_LEDGER] = _create(blueprints[ROLE_DEFICIT_LEDGER], abi.encode(c[ROLE_VAULT_MANAGER]));
        c[ROLE_SHUTDOWN_MODULE] = _create(
            blueprints[ROLE_SHUTDOWN_MODULE], abi.encode(c[ROLE_VAULT_MANAGER], house_, p.criticalTcr)
        );
        c[ROLE_HINT_HELPERS] =
            _create(blueprints[ROLE_HINT_HELPERS], abi.encode(c[ROLE_VAULT_MANAGER], c[ROLE_SORTED]));
    }

    function _checkBlueprint(uint256 role, address blueprint, bytes32 codehash) private view {
        if (blueprint.code.length == 0) revert BlueprintNoCode(role);
        uint256 first;
        // the first byte of the blueprint's code, without copying the rest (scratch space)
        assembly ("memory-safe") {
            extcodecopy(blueprint, 0, 0, 1)
            first := byte(0, mload(0))
        }
        if (first != 0xFE) revert BlueprintNotInert(role);
        if (blueprint.codehash != codehash) revert BlueprintMismatch(role);
    }

    /// @dev CREATE (never CREATE2) with the blueprint's code after its 0xFE byte, followed by the
    ///      ABI-encoded constructor arguments. A reverting constructor's revert data is re-thrown.
    function _create(address blueprint, bytes memory args) private returns (address a) {
        uint256 n = blueprint.code.length - 1;
        uint256 total = n + args.length;
        assembly ("memory-safe") {
            let initcode := mload(0x40)
            extcodecopy(blueprint, initcode, 1, n)
            mcopy(add(initcode, n), add(args, 0x20), mload(args))
            a := create(0, initcode, total)
            if iszero(a) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
