// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Errors shared by several core contracts (docs/spec.md §11.2). Declared once at file
///         level so every contract raises the same selector; the Python model raises the same names.

/// @notice A constructor or `wire` argument is out of range, or zero where §3.4 does not allow it.
///         `index` is the 0-based position of the first failing argument (§3.4: argument order,
///         first failure wins).
error InvalidParameter(uint8 index);

/// @notice The caller is not in the permission matrix for this function (§9).
error Unauthorized();

/// @notice A required price is not usable (§7).
error PriceUnusable();

/// @notice The operation is forbidden after the shutdown trigger (§11.2).
error SystemShutdown();

/// @notice The operation is forbidden after settlement (§11.2).
error SystemSettled();

/// @notice Settlement is required first (§11.2).
error NotSettled();

/// @notice An amount argument is 0 (§11.2).
error ZeroAmount();

/// @notice The caller's stablecoin balance is below the amount to burn or move (§2.5).
error InsufficientBalance();

/// @notice Settlement preconditions (§11.2): no shutdown triggered yet / already settled.
error NotTriggered();
error AlreadySettled();

/// @notice `check` or `redeem` was called while the auction house is inside a buyer callback
///         (§6.7.2, §6.11.1).
error AuctionCallbackActive();
