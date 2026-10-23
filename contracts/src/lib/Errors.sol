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
