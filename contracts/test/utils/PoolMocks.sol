// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StableToken} from "../../src/core/StableToken.sol";
import {StabilityPool} from "../../src/liquidation/StabilityPool.sol";
import {MockWETH} from "./VaultMocks.sol";

/// @notice The real pool with §6.6.2's internal `offset` exposed to its VaultManager, so the
///         `product_sum.json` unit vectors can drive an offset with `c` WETH already received
///         (`hook.offset`) without a liquidation around it.
contract StabilityPoolHarness is StabilityPool {
    constructor(address weth_, address token_, uint256 liquidationPenalty, uint256 minDeposit)
        StabilityPool(weth_, token_, liquidationPenalty, minDeposit)
    {}

    function offsetForTest(uint256 d, uint256 c) external whenWired onlyVault {
        _offset(d, c);
    }
}

/// @notice The test VaultManager of the `product_sum.json` unit vectors: `accrue()` is a no-op
///         (counted), `hook.offset(d, c)` sends `c` WETH to the pool and offsets, `hook.onInterest(g)`
///         mints `g` to the pool and notifies it, `liquidate` sends `coll` WETH and calls
///         `onLiquidation`. It is the token's minter and reports the pool as its `stabilityPool`, which
///         the DeficitLedger stand-in authorises `onPoolDust` against.
contract PoolTestVault {
    MockWETH public immutable weth;
    StableToken public immutable token;
    StabilityPoolHarness public pool;
    uint256 public accrueCalls;
    /// @notice When set, `accrue()` books this much interest first, as a real accrual would.
    uint256 public pendingInterest;
    /// @notice When set, `accrue()` re-enters the pool's depositor surface.
    bool public reenter;

    constructor(MockWETH weth_, StableToken token_) {
        weth = weth_;
        token = token_;
    }

    function setPool(StabilityPoolHarness pool_) external {
        pool = pool_;
    }

    function stabilityPool() external view returns (address) {
        return address(pool);
    }

    function accrue() external {
        ++accrueCalls;
        if (reenter) pool.withdraw(type(uint256).max); // a locked entry point, from inside the lock
        uint256 g = pendingInterest;
        if (g > 0) {
            pendingInterest = 0;
            interest(g);
        }
    }

    function setReenter(bool on) external {
        reenter = on;
    }

    function setPendingInterest(uint256 g) external {
        pendingInterest = g;
    }

    function mintTo(address to, uint256 amount) external {
        token.mint(to, amount);
    }

    function offset(uint256 d, uint256 c) external {
        weth.mint(address(pool), c);
        pool.offsetForTest(d, c);
    }

    /// @notice The vectors' `hook.onInterest`: mint, then book (the end state equals booking first).
    function interest(uint256 g) public returns (bool booked) {
        token.mint(address(pool), g);
        booked = pool.onInterest(g);
    }

    /// @notice Gas used by `onInterest(g)` as accrual calls it (CHG-006's measurement): mint first,
    ///         then the call, timed around the call alone (the pool account access is included).
    function measureInterest(uint256 g) external returns (uint256 used, bool booked) {
        token.mint(address(pool), g);
        uint256 before = gasleft();
        booked = pool.onInterest(g);
        used = before - gasleft();
    }

    function liquidate(uint256 id, address owner, uint256 debt, uint256 coll, uint256 price)
        external
        returns (uint256 debtAbsorbed, uint256 collReturned)
    {
        weth.mint(address(pool), coll);
        return pool.onLiquidation(id, owner, debt, coll, price);
    }
}

/// @notice A DeficitLedger that has settled (§4.7): the pool must skip the dust sweep (§5.3.1).
contract SettledLedger {
    function settled() external pure returns (bool) {
        return true;
    }

    function onPoolDust(uint256) external pure {
        revert("settled ledger takes no dust");
    }
}
