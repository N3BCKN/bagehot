// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../core/HintHelpers.sol";
import {OracleAdapter} from "../core/OracleAdapter.sol";
import {SortedPositions} from "../core/SortedPositions.sol";
import {StableToken} from "../core/StableToken.sol";
import {VaultManager} from "../core/VaultManager.sol";
import {ISortKeySource} from "../interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../interfaces/ISortedPositions.sol";
import {StandInDeficitLedger} from "../mocks/StandInDeficitLedger.sol";
import {StandInShutdownModule} from "../mocks/StandInShutdownModule.sol";
import {StandInStrategy} from "../mocks/StandInStrategy.sol";
import {RedemptionModule} from "../redemption/RedemptionModule.sol";

/// @title BagehotFactory
/// @notice Deploys every contract of one deployment variant and wires them, all inside its own
///         constructor: one transaction, no un-wired window, no caller-supplied role addresses
///         (ADR-0021, P11-1). Every wired contract records this factory as its `deployer`, and only
///         the factory could ever call its `wire`, which it does here, once. No CREATE2 / `{salt:}`.
///         Until StabilityPool (P19), DeficitLedger (P21), ShutdownModule and DutchAuctionHouse
///         (P33) exist, those roles are filled by LOCAL-ONLY stand-ins (`src/mocks/StandIn*`), and
///         the deployment script refuses to deploy this factory on any chain but 31337.
///         Cross-contract constraints (§3.3 1, 2, 5, 7, 8) are asserted by the deployment script and
///         the smoke test (`script/DeploymentChecks.sol`); each constructor and `wire` checks its own
///         arguments (§3.4).
contract BagehotFactory {
    /// @notice The factory still carries local-only stand-ins (P18-2): it deploys on chain 31337 only.
    error StandInsAreLocalOnly(uint256 chainId);

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

    constructor(Params memory p) {
        if (block.chainid != LOCAL_CHAIN_ID) revert StandInsAreLocalOnly(block.chainid);
        variantB = p.variantB;
        deployBlock = block.number;
        StableToken token_ = new StableToken(p.tokenName, p.tokenSymbol);
        OracleAdapter oracle_ = _oracle(p);
        VaultManager vm_ = new VaultManager(
            p.weth,
            address(token_),
            address(oracle_),
            p.mcr,
            p.minDebt,
            p.gasReserve,
            p.ratePerSecond,
            p.poolShareBps
        );
        SortedPositions sorted_ = new SortedPositions(p.maxHintSteps);
        RedemptionModule rm_ = new RedemptionModule(
            address(token_), address(oracle_), p.redemptionFeeFloor, p.beta, p.baseRateDecay
        );
        address strategy_ = address(new StandInStrategy());
        address pool_ = p.variantB ? address(0) : strategy_;
        address house_ = p.variantB ? strategy_ : address(0);
        address ledger_ = address(new StandInDeficitLedger(address(vm_)));
        address shutdown_ = address(new StandInShutdownModule(address(vm_), house_, p.criticalTcr));

        HintHelpers hints_ = new HintHelpers(ISortKeySource(address(vm_)), ISortedPositions(address(sorted_)));
        // record everything before the wiring calls (checks-effects-interactions)
        (token, oracle, vaultManager, sorted, redemptionModule, hintHelpers) =
        (token_, oracle_, vm_, sorted_, rm_, hints_);
        (strategy, deficitLedger, shutdownModule, stabilityPool, auctionHouse) =
        (strategy_, ledger_, shutdown_, pool_, house_);

        sorted_.wire(address(vm_));
        vm_.wire(address(sorted_), strategy_, pool_, address(rm_), ledger_, shutdown_);
        rm_.wire(address(vm_), shutdown_, house_);
        token_.wire(address(vm_), strategy_, ledger_, shutdown_);
        emit Deployed(
            p.variantB,
            address(token_),
            address(oracle_),
            address(vm_),
            address(sorted_),
            address(rm_),
            address(hints_),
            strategy_,
            ledger_,
            shutdown_
        );
    }

    function _oracle(Params memory p) private returns (OracleAdapter) {
        return new OracleAdapter(
            p.priceFeed,
            p.sequencerFeed,
            p.staleness,
            p.gracePeriod,
            p.minPrice,
            p.maxPrice,
            p.oracleGas,
            p.oraclePostFailureGas
        );
    }
}
