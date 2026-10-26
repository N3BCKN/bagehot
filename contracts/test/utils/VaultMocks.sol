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

/// @notice The stability pool's interest interface (deployment A): books its share only while
///         `totalDeposits ≥ MIN_DEPOSIT` and declines below, without recording (§6.6.5, ADR-0033).
contract MockPool {
    uint256 public totalDeposits;
    uint256 public minDeposit = 1e18;
    uint256 public interestReceived;
    uint256 public interestCalls;
    bool public fail;

    function setDeposits(uint256 totalDeposits_) external {
        totalDeposits = totalDeposits_;
    }

    function acceptsInterest() external view returns (bool) {
        return totalDeposits >= minDeposit;
    }

    /// @notice Makes `onInterest` revert: the `fail` outcome of `interest.json#poolHook` (ADR-0033).
    function setFail(bool f) external {
        fail = f;
    }

    function onInterest(uint256 amount) external returns (bool) {
        require(!fail, "pool failed");
        if (totalDeposits < minDeposit) return false;
        interestReceived += amount;
        ++interestCalls;
        return true;
    }
}

/// @notice A pool or ledger whose `onInterest` tries a configured call into the VaultManager and records
///         how it ended (review F3), or reverts outright (review F4, ADR-0033).
contract HostileInterestSink {
    address public target;
    bytes public data;
    bool public armed;
    bool public fired;
    bytes public innerRevert;
    bool public revertInterest;

    function arm(address target_, bytes calldata data_) external {
        (target, data, armed, fired) = (target_, data_, true, false);
        delete innerRevert;
    }

    function setRevertInterest(bool r) external {
        revertInterest = r;
    }

    function acceptsInterest() external pure returns (bool) {
        return true;
    }

    function onInterest(uint256) external returns (bool) {
        require(!revertInterest, "pool broken");
        if (!armed) return true;
        armed = false;
        fired = true;
        (bool ok, bytes memory ret) = target.call(data);
        innerRevert = ok ? bytes("") : ret;
        return true;
    }
}

/// @notice A stability pool whose `onInterest` fails in every way the guarded call must survive
///         (CHG-006 / ADR-0033): it reverts, panics, burns all its gas, answers with the wrong size or
///         a word other than 0/1 — or books after burning `heavyGas`, or declines.
contract HostilePool {
    enum Mode {
        Book,
        Decline,
        Revert,
        Panic,
        BurnAll,
        WrongSize,
        NonBool,
        Heavy
    }

    Mode public mode;
    uint256 public heavyGas;
    uint256 public booked;
    uint256 public bookCalls;

    function setMode(Mode m) external {
        mode = m;
    }

    function setHeavy(uint256 gasToBurn) external {
        (mode, heavyGas) = (Mode.Heavy, gasToBurn);
    }

    function acceptsInterest() external pure returns (bool) {
        return true;
    }

    function onInterest(uint256 amount) external returns (bool) {
        Mode m = mode;
        if (m == Mode.Decline) return false;
        if (m == Mode.Revert) revert("pool broken");
        if (m == Mode.Panic) {
            uint256 x = type(uint256).max;
            x += amount; // checked arithmetic: Panic(0x11), as a G overflow would
        }
        if (m == Mode.BurnAll) {
            while (true) {} // runs out of the forwarded gas
        }
        if (m == Mode.WrongSize) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(0x20, 1)
                return(0, 0x40)
            }
        }
        if (m == Mode.NonBool) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 0x20)
            }
        }
        if (m == Mode.Heavy) {
            // burns `heavyGas` before booking; given less, it runs out of gas (never reverts early,
            // which would hand gas back — the real pool never reads gasleft(), §6.2)
            uint256 left = gasleft();
            uint256 stop = left > heavyGas ? left - heavyGas : 0;
            while (gasleft() > stop) {}
        }
        booked += amount;
        ++bookCalls;
        return true;
    }
}

/// @notice A pool that reverts early when it is given less than `need` gas — exactly what spec §6.2's
///         gas rule assumes the real pool never does (it never reads gasleft()). Used to pin that
///         assumption: such a pool's failure can be faked by a caller.
contract GasSensitivePool {
    uint256 public immutable need;

    constructor(uint256 need_) {
        need = need_;
    }

    function acceptsInterest() external pure returns (bool) {
        return true;
    }

    function onInterest(uint256) external view returns (bool) {
        require(gasleft() >= need, "short of gas");
        return true;
    }
}
