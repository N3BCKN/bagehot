// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StableToken} from "../../src/core/StableToken.sol";
import {DeficitLedger} from "../../src/safety/DeficitLedger.sol";
import {PoolTestVault, StabilityPoolHarness} from "./PoolMocks.sol";
import {MockWETH} from "./VaultMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice A wired pool (harness) behind the test VaultManager, the real StableToken (pool as burner
///         and mover) and the DeficitLedger stand-in. The shutdown role is an inert address.
abstract contract PoolFixture is Test {
    uint256 internal constant PENALTY = 0.05e18;
    uint256 internal constant MIN_DEPOSIT = 1e18;

    MockWETH internal weth;
    StableToken internal token;
    PoolTestVault internal tv;
    StabilityPoolHarness internal pool;
    DeficitLedger internal ledger;

    function _deployPool(uint256 minDeposit) internal {
        weth = new MockWETH();
        token = new StableToken("Bagehot USD TEST", "bUSDTEST");
        tv = new PoolTestVault(weth, token);
        pool = new StabilityPoolHarness(address(weth), address(token), PENALTY, minDeposit);
        ledger = new DeficitLedger(address(weth), address(token));
        tv.setPool(pool);
        token.wire(address(tv), address(pool), address(ledger), makeAddr("shutdown"));
        pool.wire(address(tv), address(ledger));
        ledger.wire(address(tv), address(pool), address(0), address(pool), makeAddr("shutdown"));
    }

    function _fund(address a, uint256 amount) internal {
        tv.mintTo(a, amount);
    }

    function _deposit(address a, uint256 amount) internal {
        vm.prank(a);
        pool.deposit(amount);
    }

    function _withdraw(address a, uint256 amount) internal {
        vm.prank(a);
        pool.withdraw(amount);
    }
}
