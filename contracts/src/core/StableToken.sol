// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStableToken} from "../interfaces/IStableToken.sol";
import {Unauthorized} from "../lib/Errors.sol";
import {WiredBase} from "../lib/Wired.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StableToken
/// @notice The USD-pegged stablecoin (docs/spec.md §4.10, §5.9). A plain OZ ERC-20 plus three
///         privileged functions, each restricted to addresses fixed once by `wire`:
///         `mint` (the VaultManager), `burnFrom` (VaultManager, strategy, DeficitLedger,
///         ShutdownModule) and `moveFrom` (the strategy: StabilityPool in A, DutchAuctionHouse in B).
///         There is no other privileged function and nothing can be changed after wiring.
/// @dev The ERC-20 surface (`transfer`, `approve`, `transferFrom`, views) does not require `wired`
///      (§2.5). The token makes no external call, so it needs no reentrancy lock. Testnet
///      deployments carry `TEST` in name and symbol; the deploy script (P18) sets them.
contract StableToken is ERC20, WiredBase, IStableToken {
    /// @notice Total supply never exceeds this (§2.2 supply cap).
    uint256 public constant SUPPLY_CAP = type(uint128).max;

    address public vaultManager;
    address public strategy;
    address public deficitLedger;
    address public shutdownModule;

    error SupplyCapExceeded();

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice One-shot wiring (§3.4). All four addresses must be non-zero.
    function wire(address vaultManager_, address strategy_, address deficitLedger_, address shutdownModule_)
        external
        onlyWiring
    {
        _requireNonZero(vaultManager_, 0);
        _requireNonZero(strategy_, 1);
        _requireNonZero(deficitLedger_, 2);
        _requireNonZero(shutdownModule_, 3);
        vaultManager = vaultManager_;
        strategy = strategy_;
        deficitLedger = deficitLedger_;
        shutdownModule = shutdownModule_;
        address[] memory addresses = new address[](4);
        addresses[0] = vaultManager_;
        addresses[1] = strategy_;
        addresses[2] = deficitLedger_;
        addresses[3] = shutdownModule_;
        _markWired(addresses);
    }

    /// @notice Mints `amount` to `to`. Minter only (the VaultManager).
    /// @dev `amount > SUPPLY_CAP − totalSupply` is §5.9's `totalSupply + amount > 2^128 − 1`
    ///      without the overflow for amounts near 2^256.
    function mint(address to, uint256 amount) external whenWired {
        if (msg.sender != vaultManager) revert Unauthorized();
        if (amount > SUPPLY_CAP - totalSupply()) revert SupplyCapExceeded();
        _mint(to, amount);
    }

    /// @notice Burns `amount` from `account` without an allowance. Burners only.
    /// @dev Core contracts pass only their own address, the current `msg.sender` or the redeemer
    ///      (§2.5); an insufficient balance reverts with OZ's `ERC20InsufficientBalance`.
    ///      Same selector as OZ `ERC20Burnable.burnFrom(address,uint256)` but **not** its semantics:
    ///      no allowance is checked or spent. Indexers and bots must not assume ERC20Burnable.
    function burnFrom(address account, uint256 amount) external whenWired {
        if (!_isBurner(msg.sender)) revert Unauthorized();
        _burn(account, amount);
    }

    /// @notice Moves `amount` from `account` to `to` without an allowance. Mover only (the strategy).
    function moveFrom(address account, address to, uint256 amount) external whenWired {
        if (msg.sender != strategy) revert Unauthorized();
        _transfer(account, to, amount);
    }

    function _isBurner(address a) internal view returns (bool) {
        return a == vaultManager || a == strategy || a == deficitLedger || a == shutdownModule;
    }
}
