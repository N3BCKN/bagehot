// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../../src/core/HintHelpers.sol";
import {OracleAdapter} from "../../src/core/OracleAdapter.sol";
import {SortedPositions} from "../../src/core/SortedPositions.sol";
import {StableToken} from "../../src/core/StableToken.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {BagehotFactory} from "../../src/deploy/BagehotFactory.sol";
import {ISortKeySource} from "../../src/interfaces/ISortKeySource.sol";
import {ISortedPositions} from "../../src/interfaces/ISortedPositions.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {StandInShutdownModule} from "../../src/mocks/StandInShutdownModule.sol";
import {StandInStrategy} from "../../src/mocks/StandInStrategy.sol";
import {RedemptionModule} from "../../src/redemption/RedemptionModule.sol";
import {DeficitLedger} from "../../src/safety/DeficitLedger.sol";

/// @notice TEST ONLY. BagehotFactory's deployment (variant A) with one deliberate wiring fault, to
///         prove DeploymentChecks rejects it (ADR-0031): mode 1 wires the token to a second strategy
///         (all liquidations would revert `Unauthorized`); mode 2 gives the RedemptionModule an
///         auction house in A (§3.3 constraint 7); mode 3 wires the VaultManager to a second ledger;
///         mode 4 leaves the token unwired. Same getters as BagehotFactory.
contract MisWiredFactory {
    bool public constant variantB = false;
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
    address public immutable stabilityPool;
    address public constant auctionHouse = address(0);

    constructor(BagehotFactory.Params memory p, uint8 mode) {
        deployBlock = block.number;
        token = new StableToken(p.tokenName, p.tokenSymbol);
        oracle = new OracleAdapter(
            p.priceFeed,
            p.sequencerFeed,
            p.staleness,
            p.gracePeriod,
            p.minPrice,
            p.maxPrice,
            p.oracleGas,
            p.oraclePostFailureGas
        );
        vaultManager = new VaultManager(
            p.weth,
            address(token),
            address(oracle),
            p.mcr,
            p.minDebt,
            p.gasReserve,
            p.ratePerSecond,
            p.poolShareBps,
            p.poolHookGas
        );
        sorted = new SortedPositions(p.maxHintSteps);
        redemptionModule = new RedemptionModule(
            address(token), address(oracle), p.redemptionFeeFloor, p.beta, p.baseRateDecay
        );
        address strategy_ =
            address(new StabilityPool(p.weth, address(token), p.liquidationPenalty, p.minDeposit));
        strategy = strategy_;
        stabilityPool = strategy_;
        deficitLedger = address(new DeficitLedger(p.weth, address(token)));
        address vmLedger = mode == 3 ? address(new DeficitLedger(p.weth, address(token))) : deficitLedger;
        shutdownModule = address(new StandInShutdownModule(address(vaultManager), address(0), p.criticalTcr));
        sorted.wire(address(vaultManager));
        vaultManager.wire(
            address(sorted), strategy_, strategy_, address(redemptionModule), vmLedger, shutdownModule
        );
        redemptionModule.wire(address(vaultManager), shutdownModule, mode == 2 ? strategy_ : address(0));
        address tokenStrategy = mode == 1 ? address(new StandInStrategy()) : strategy_;
        if (mode != 4) token.wire(address(vaultManager), tokenStrategy, deficitLedger, shutdownModule);
        StabilityPool(strategy_).wire(address(vaultManager), deficitLedger);
        DeficitLedger(deficitLedger)
            .wire(address(vaultManager), strategy_, address(0), strategy_, shutdownModule);
        hintHelpers =
            new HintHelpers(ISortKeySource(address(vaultManager)), ISortedPositions(address(sorted)));
    }
}
