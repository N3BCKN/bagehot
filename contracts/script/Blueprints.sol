// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HintHelpers} from "../src/core/HintHelpers.sol";
import {OracleAdapter} from "../src/core/OracleAdapter.sol";
import {SortedPositions} from "../src/core/SortedPositions.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {StabilityPool} from "../src/liquidation/StabilityPool.sol";
import {StandInDeficitLedger} from "../src/mocks/StandInDeficitLedger.sol";
import {StandInShutdownModule} from "../src/mocks/StandInShutdownModule.sol";
import {StandInStrategy} from "../src/mocks/StandInStrategy.sol";
import {RedemptionModule} from "../src/redemption/RedemptionModule.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice ADR-0035 blueprints, script side. A blueprint is a contract whose code is
///         `0xFE ‖ creationCode` (EIP-5202 layout without its optional header): the leading invalid
///         opcode makes it uncallable. Blueprints are deployed through the canonical CREATE2 deployer
///         with a fixed salt, so the address commits to the code: a second run, or the other variant,
///         finds them already there and deploys nothing. They are not wired contracts, so P11-1's ban
///         on `{salt:}` (a CREATE2 proxy as `deployer`) does not apply: the factory, not the proxy,
///         creates every role. Creation codes and hashes come from the same build as the scripts.
library Blueprints {
    error BlueprintTooLarge(uint256 role, uint256 size);
    error BlueprintDeployFailed(uint256 role);

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = keccak256("bagehot.blueprint.v1");
    uint256 internal constant MAX_CODE_SIZE = 24_576; // EIP-170, for the blueprint's own code
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Every role's creation code, in `BagehotFactory`'s role order. The strategy is the real
    ///         StabilityPool in deployment A (P19) and the stand-in in B until P33.
    function creationCodes(bool variantB) internal pure returns (bytes[9] memory c) {
        c[0] = type(StableToken).creationCode;
        c[1] = type(OracleAdapter).creationCode;
        c[2] = type(VaultManager).creationCode;
        c[3] = type(SortedPositions).creationCode;
        c[4] = type(RedemptionModule).creationCode;
        c[5] = variantB ? type(StandInStrategy).creationCode : type(StabilityPool).creationCode;
        c[6] = type(StandInDeficitLedger).creationCode;
        c[7] = type(StandInShutdownModule).creationCode;
        c[8] = type(HintHelpers).creationCode;
    }

    /// @notice Every role's artifact, for the runtime-code comparison (`vm.getDeployedCode`).
    function artifacts(bool variantB) internal pure returns (string[9] memory a) {
        a[0] = "StableToken.sol:StableToken";
        a[1] = "OracleAdapter.sol:OracleAdapter";
        a[2] = "VaultManager.sol:VaultManager";
        a[3] = "SortedPositions.sol:SortedPositions";
        a[4] = "RedemptionModule.sol:RedemptionModule";
        a[5] = variantB ? "StandInStrategy.sol:StandInStrategy" : "StabilityPool.sol:StabilityPool";
        a[6] = "StandInDeficitLedger.sol:StandInDeficitLedger";
        a[7] = "StandInShutdownModule.sol:StandInShutdownModule";
        a[8] = "HintHelpers.sol:HintHelpers";
    }

    /// @notice Role names, as the manifest records them.
    function names() internal pure returns (string[9] memory n) {
        n = [
            "token",
            "oracle",
            "vaultManager",
            "sortedPositions",
            "redemptionModule",
            "strategy",
            "deficitLedger",
            "shutdownModule",
            "hintHelpers"
        ];
    }

    function codehash(bytes memory creationCode) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"fe", creationCode));
    }

    function codehashes(bool variantB) internal pure returns (bytes32[9] memory h) {
        bytes[9] memory c = creationCodes(variantB);
        for (uint256 i; i < 9; ++i) {
            h[i] = codehash(c[i]);
        }
    }

    /// @notice The digest `BagehotFactory.blueprintsDigest` must equal for today's build.
    function digest(bool variantB) internal pure returns (bytes32) {
        return keccak256(abi.encode(codehashes(variantB)));
    }

    /// @notice Initcode that deploys `0xFE ‖ creationCode` as runtime code:
    ///         PUSH2 len, RETURNDATASIZE, DUP2, PUSH1 10, RETURNDATASIZE, CODECOPY, RETURN, then the code.
    function initcode(uint256 role, bytes memory creationCode) internal pure returns (bytes memory) {
        uint256 size = creationCode.length + 1;
        if (size > MAX_CODE_SIZE) revert BlueprintTooLarge(role, size);
        return abi.encodePacked(hex"61", uint16(size), hex"3d81600a3d39f3", hex"fe", creationCode);
    }

    function predict(uint256 role, bytes memory creationCode) internal pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(initcode(role, creationCode)), CREATE2_DEPLOYER);
    }

    /// @notice Deploys the blueprint for `creationCode` unless it already exists (same address, same
    ///         code). Call inside a broadcast to make it a transaction.
    function deploy(uint256 role, bytes memory creationCode) internal returns (address b) {
        b = predict(role, creationCode);
        if (b.code.length > 0) return b;
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(SALT, initcode(role, creationCode)));
        if (!ok || b.code.length == 0) revert BlueprintDeployFailed(role);
    }

    /// @notice Deploys (or finds) every role's blueprint; returns the factory's arguments.
    function deployAll(bool variantB)
        internal
        returns (address[9] memory blueprints, bytes32[9] memory hashes)
    {
        bytes[9] memory c = creationCodes(variantB);
        for (uint256 i; i < 9; ++i) {
            blueprints[i] = deploy(i, c[i]);
            hashes[i] = codehash(c[i]);
        }
    }

    /// @notice True if `a`'s runtime code is the artifact's: same length, and equal at every byte the
    ///         artifact does not leave zero. Immutables are zero placeholders in the artifact and
    ///         filled in on chain, so an exact hash cannot be compared; every other byte must match.
    function runtimeMatches(address a, bytes memory artifact) internal view returns (bool) {
        bytes memory code = a.code;
        if (code.length != artifact.length) return false;
        for (uint256 i; i < code.length; i += 32) {
            bytes32 wc;
            bytes32 wa;
            assembly ("memory-safe") {
                wc := mload(add(add(code, 0x20), i))
                wa := mload(add(add(artifact, 0x20), i))
            }
            if (wc == wa) continue;
            uint256 end = i + 32 < code.length ? i + 32 : code.length;
            for (uint256 k = i; k < end; ++k) {
                if (artifact[k] != 0 && artifact[k] != code[k]) return false;
            }
        }
        return true;
    }
}
