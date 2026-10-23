// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidParameter} from "../../src/lib/Errors.sol";
import {WiredBase} from "../../src/lib/Wired.sol";
import {WiredHarness} from "../utils/WiredHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The one-shot wiring pattern (spec §3.4, §4.1, §9; ADR-0021).
contract WiredTest is Test {
    WiredHarness internal w;
    address internal constant TARGET = address(0xBEEF);

    function setUp() public {
        w = new WiredHarness();
    }

    function test_deployerIsTheConstructorCaller() public {
        assertEq(w.deployer(), address(this));
        vm.prank(address(0xA11CE));
        WiredHarness other = new WiredHarness();
        assertEq(other.deployer(), address(0xA11CE));
        assertFalse(w.wired());
    }

    function test_wire_setsStateAndEmitsOnce() public {
        address[] memory expected = new address[](1);
        expected[0] = TARGET;
        vm.expectEmit(address(w));
        emit WiredBase.Wired(expected);
        w.wire(TARGET);
        assertTrue(w.wired());
        assertEq(w.target(), TARGET);
    }

    function test_wire_secondCallReverts() public {
        w.wire(TARGET);
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        w.wire(address(0xCAFE));
        assertEq(w.target(), TARGET);
    }

    /// @dev The front-running pitfall: nobody but the deployer can wire, before or after.
    function testFuzz_wire_onlyDeployerCanWire(address caller) public {
        vm.prank(caller);
        if (caller == address(this)) {
            w.wire(TARGET);
            assertTrue(w.wired());
            return;
        }
        vm.expectRevert(WiredBase.NotDeployer.selector);
        w.wire(TARGET);
        assertFalse(w.wired());
    }

    function test_wire_nonDeployerAfterWiringGetsNotDeployerFirst() public {
        w.wire(TARGET);
        vm.prank(address(0xBAD));
        vm.expectRevert(WiredBase.NotDeployer.selector);
        w.wire(TARGET);
    }

    function test_wire_alreadyWiredCheckedBeforeArguments() public {
        w.wire(TARGET);
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        w.wire(address(0));
    }

    function test_wire_zeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidParameter.selector, uint8(0)));
        w.wire(address(0));
        assertFalse(w.wired());
    }

    function test_whenWired_revertsBeforeWiring() public {
        vm.expectRevert(WiredBase.NotWired.selector);
        w.poke();
        w.wire(TARGET);
        w.poke();
        assertEq(w.counter(), 1);
    }

    function test_markWired_isOnceOnlyEvenWithoutTheModifier() public {
        vm.expectRevert(WiredBase.AlreadyWired.selector);
        w.brokenWireMarksTwice();
        assertFalse(w.wired());
    }
}
