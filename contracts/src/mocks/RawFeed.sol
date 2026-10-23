// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title RawFeed
/// @notice TEST ONLY. Answers every call it has no function for — `latestRoundData()`,
///         `decimals()`, anything — with exactly the bytes set in `payload`, unencoded, or reverts
///         with them. It produces the non-ABI outputs the oracle adapter must survive (spec §6.10.1,
///         ADR-0029): 32 or 159 bytes, a 160-byte answer with junk above bit 80 in the `uint80`
///         words, an empty return, or a 150 KB return or revert payload (return bombing).
/// @dev No assembly: a `fallback` declared `returns (bytes memory)` returns its bytes raw.
///      Excluded from coverage, static analysis and invariants. Setters are permissionless.
contract RawFeed {
    bytes public payload;
    bool public reverts;
    /// @notice Zero bytes appended to `payload` on the wire, generated in memory so a large reply
    ///         stays cheap for the feed itself (a storage payload of 150 KB could not be read
    ///         within ORACLE_GAS).
    uint256 public padding;

    /// @notice Reverting with `payload` puts `RawFeedReverted(payload)` on the wire: 4 + 64 bytes
    ///         of ABI framing plus the payload, so the revert data is at least as large as it.
    error RawFeedReverted(bytes payload);

    function setPayload(bytes calldata payload_) external {
        payload = payload_;
    }

    /// @notice A payload of `n` zero bytes, built on-chain (a 150 KB calldata argument is awkward).
    function setZeroPayload(uint256 n) external {
        payload = new bytes(n);
    }

    function setPadding(uint256 padding_) external {
        padding = padding_;
    }

    function setReverts(bool reverts_) external {
        reverts = reverts_;
    }

    fallback(bytes calldata) external returns (bytes memory out) {
        bytes memory p = payload;
        out = p;
        uint256 pad = padding;
        if (pad != 0) {
            out = new bytes(p.length + pad);
            for (uint256 i; i < p.length; ++i) {
                out[i] = p[i];
            }
        }
        if (reverts) revert RawFeedReverted(out);
    }
}
