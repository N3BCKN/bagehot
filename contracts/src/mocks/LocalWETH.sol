// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LocalWETH
/// @notice LOCAL ONLY (chain 31337). An 18-decimal ERC-20 standing in for WETH on a local anvil
///         deployment; anyone may mint. Never deployed on Base Sepolia, where the canonical WETH is
///         configured (config/<chain>.toml).
contract LocalWETH is ERC20 {
    constructor() ERC20("Wrapped Ether (local)", "WETH") {}

    /// @notice Mints `amount` to `to`. Anyone; local test funds only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
