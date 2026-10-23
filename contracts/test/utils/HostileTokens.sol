// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Shared re-entry hook: when armed, the next token callback calls `target` with `data`
///         and records how that inner call ended. The outer operation itself completes.
abstract contract ReentryHook {
    address public target;
    bytes public data;
    bool public armed;
    bool public fired;
    bytes public innerRevert;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
        fired = false;
        delete innerRevert;
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        fired = true;
        (bool ok, bytes memory ret) = target.call(data);
        innerRevert = ok ? bytes("") : ret;
    }
}

/// @notice WETH whose transfer and transferFrom re-enter (the real WETH9 cannot; the guard must not
///         depend on that).
contract HostileWETH is ERC20, ReentryHook {
    constructor() ERC20("Hostile WETH", "hWETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool r = super.transfer(to, amount);
        _reenter();
        return r;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool r = super.transferFrom(from, to, amount);
        _reenter();
        return r;
    }
}

/// @notice A stablecoin whose mint and burnFrom re-enter.
contract HostileStable is ERC20, ReentryHook {
    constructor() ERC20("Hostile USD", "hUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
        _reenter();
    }

    function burnFrom(address account, uint256 amount) external {
        _burn(account, amount);
        _reenter();
    }
}

/// @notice An oracle that always returns a usable fixed price.
contract FixedOracle {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function fetchPrice() external view returns (uint256, bool) {
        return (price, true);
    }
}
