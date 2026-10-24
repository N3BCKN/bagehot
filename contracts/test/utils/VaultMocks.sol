// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain WETH stand-in for tests: an ERC-20 anyone can mint.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether (test)", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The DeficitLedger views the VaultManager reads (§5.1.12), settable, and its interest hook
///         (§5.6: `reserve += amount`), recorded.
contract MockLedgerViews {
    uint256 public recoveredColl;
    uint256 public auctionDebt;
    uint256 public deficit;
    uint256 public reserve;
    uint256 public interestCalls;

    function onInterest(uint256 amount) external {
        reserve += amount;
        ++interestCalls;
    }

    function set(uint256 recoveredColl_, uint256 auctionDebt_, uint256 deficit_) external {
        recoveredColl = recoveredColl_;
        auctionDebt = auctionDebt_;
        deficit = deficit_;
    }
}

/// @notice The DutchAuctionHouse view the VaultManager reads in deployment B, settable.
contract MockHouseViews {
    uint256 public totalLot;

    function set(uint256 totalLot_) external {
        totalLot = totalLot_;
    }
}

/// @notice The stability pool's interest interface (deployment A): takes its share only while
///         `totalDeposits ≥ MIN_DEPOSIT` (§6.6.5); `onInterest` recorded.
contract MockPool {
    uint256 public totalDeposits;
    uint256 public minDeposit = 1e18;
    uint256 public interestReceived;
    uint256 public interestCalls;

    function setDeposits(uint256 totalDeposits_) external {
        totalDeposits = totalDeposits_;
    }

    function acceptsInterest() external view returns (bool) {
        return totalDeposits >= minDeposit;
    }

    function onInterest(uint256 amount) external {
        interestReceived += amount;
        ++interestCalls;
    }
}

/// @notice A pool or ledger whose `onInterest` tries a configured call into the VaultManager and records
///         how it ended (review F3), or whose `acceptsInterest` reverts (review F4).
contract HostileInterestSink {
    address public target;
    bytes public data;
    bool public armed;
    bool public fired;
    bytes public innerRevert;
    bool public revertAccepts;

    function arm(address target_, bytes calldata data_) external {
        (target, data, armed, fired) = (target_, data_, true, false);
        delete innerRevert;
    }

    function setRevertAccepts(bool r) external {
        revertAccepts = r;
    }

    function acceptsInterest() external view returns (bool) {
        require(!revertAccepts, "pool broken");
        return true;
    }

    function onInterest(uint256) external {
        if (!armed) return;
        armed = false;
        fired = true;
        (bool ok, bytes memory ret) = target.call(data);
        innerRevert = ok ? bytes("") : ret;
    }
}
