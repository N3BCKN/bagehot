// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WiredBase} from "../../src/lib/Wired.sol";

/// @notice Minimal concrete WiredBase: one wired address and one guarded mutator, plus a deliberately
///         broken wire that skips `onlyWiring` and marks twice, to reach the base's own
///         once-only re-check.
contract WiredHarness is WiredBase {
    address public target;
    uint256 public counter;

    function wire(address target_) external onlyWiring {
        _requireNonZero(target_, 0);
        target = target_;
        address[] memory addresses = new address[](1);
        addresses[0] = target_;
        _markWired(addresses);
    }

    function brokenWireMarksTwice() external {
        address[] memory none = new address[](0);
        _markWired(none);
        _markWired(none);
    }

    function poke() external whenWired {
        counter += 1;
    }
}
