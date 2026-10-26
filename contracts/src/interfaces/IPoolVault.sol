// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What the stability pool calls on the VaultManager (spec §5.3, §5.1.8), and the wired pool
///         address the local DeficitLedger stand-in authorises `onPoolDust` against (§4.2).
interface IPoolVault {
    function accrue() external;
    function stabilityPool() external view returns (address);
}
