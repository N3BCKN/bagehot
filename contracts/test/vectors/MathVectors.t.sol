// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MathHarness} from "../utils/MathHarness.sol";
import {Test, stdError} from "forge-std/Test.sol";

/// @notice The math libraries against spec/vectors/math.json (protected, normative) and
///         spec/generated/math_random.json (random cases with independently computed exact results).
contract MathVectorsTest is Test {
    MathHarness internal h;
    string internal spec;
    string internal gen;

    function setUp() public {
        h = new MathHarness();
        spec = vm.readFile("../spec/vectors/math.json");
        gen = vm.readFile("../spec/generated/math_random.json");
    }

    function _u(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function _step(uint256 v, uint256 i) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(v), "].steps[", vm.toString(i), "]");
    }

    // ------------------------------------------------------------------ spec/vectors/math.json
    function test_vectors_mulDiv() public view {
        uint256 i;
        for (; vm.keyExistsJson(spec, _step(0, i)); ++i) {
            string memory p = _step(0, i);
            uint256 x = _u(spec, string.concat(p, ".x"));
            uint256 y = _u(spec, string.concat(p, ".y"));
            uint256 d = _u(spec, string.concat(p, ".d"));
            assertEq(h.mulDivDown(x, y, d), _u(spec, string.concat(p, ".result.down")), "down");
            assertEq(h.mulDivUp(x, y, d), _u(spec, string.concat(p, ".result.up")), "up");
        }
        assertEq(i, 6, "all mulDiv vectors read");
    }

    function test_vectors_rpow() public view {
        uint256 checked;
        for (uint256 i; vm.keyExistsJson(spec, _step(1, i)); ++i) {
            string memory p = _step(1, i);
            if (keccak256(bytes(vm.parseJsonString(spec, string.concat(p, ".op")))) != keccak256("rpow")) {
                continue; // the trace vector pins intermediate states; checked in pytest
            }
            uint256 x = _u(spec, string.concat(p, ".x"));
            uint256 n = _u(spec, string.concat(p, ".n"));
            assertEq(h.rpowUp(x, n), _u(spec, string.concat(p, ".result")), "rpow");
            ++checked;
        }
        assertEq(checked, 8, "all rpow vectors read");
    }

    function test_vectors_rpowTraceFinalState() public view {
        // rpow.trace for x = RAY + 1e18, n = 7: the last state's z is the result.
        string memory p = _step(1, 8);
        uint256 x = _u(spec, string.concat(p, ".x"));
        uint256 n = _u(spec, string.concat(p, ".n"));
        assertEq(h.rpowUp(x, n), _u(spec, string.concat(p, ".result[2].z")));
        // and the intermediate states it lists: rpow(x, 1) and rpow(x, 3)
        assertEq(h.rpowUp(x, 1), _u(spec, string.concat(p, ".result[0].z")));
        assertEq(h.rpowUp(x, 3), _u(spec, string.concat(p, ".result[1].z")));
    }

    function test_vectors_derivedConstants() public view {
        string memory e = ".vectors[2].expected";
        uint256 ray = 1e27;
        uint256 rate = _u(spec, string.concat(e, ".RATE_PER_SECOND"));
        assertEq(
            h.rpowUp(ray + rate, 31_536_000),
            _u(spec, string.concat(e, ".['rpow(RAY+RATE_PER_SECOND,31536000)']"))
        );
        assertEq(
            h.rpowUp(_u(spec, string.concat(e, ".BASE_RATE_DECAY")), 43_200),
            _u(spec, string.concat(e, ".['rpow(BASE_RATE_DECAY,43200)']"))
        );
        assertEq(
            h.rpowUp(_u(spec, string.concat(e, ".CUT")), 600),
            _u(spec, string.concat(e, ".['rpow(CUT,600)']"))
        );
    }

    // ------------------------------------------------------------------ generated vectors
    function _isRevert(string memory v) internal pure returns (bool) {
        return
            keccak256(bytes(v)) == keccak256("Overflow") || keccak256(bytes(v)) == keccak256("DivisionByZero");
    }

    function _expectPanic(string memory v) internal {
        vm.expectRevert(
            keccak256(bytes(v)) == keccak256("Overflow") ? stdError.arithmeticError : stdError.divisionError
        );
    }

    function test_generated_mulDiv() public {
        string[] memory xs = vm.parseJsonStringArray(gen, ".mulDiv.x");
        string[] memory ys = vm.parseJsonStringArray(gen, ".mulDiv.y");
        string[] memory ds = vm.parseJsonStringArray(gen, ".mulDiv.d");
        string[] memory downs = vm.parseJsonStringArray(gen, ".mulDiv.down");
        string[] memory ups = vm.parseJsonStringArray(gen, ".mulDiv.up");
        uint256 reverts;
        for (uint256 i; i < xs.length; ++i) {
            (uint256 x, uint256 y, uint256 d) =
                (vm.parseUint(xs[i]), vm.parseUint(ys[i]), vm.parseUint(ds[i]));
            if (_isRevert(downs[i])) {
                _expectPanic(downs[i]);
                h.mulDivDown(x, y, d);
                ++reverts;
            } else {
                assertEq(h.mulDivDown(x, y, d), vm.parseUint(downs[i]), "generated down");
            }
            if (_isRevert(ups[i])) {
                _expectPanic(ups[i]);
                h.mulDivUp(x, y, d);
            } else {
                assertEq(h.mulDivUp(x, y, d), vm.parseUint(ups[i]), "generated up");
            }
        }
        assertEq(xs.length, 400);
        assertGt(reverts, 0, "generated set exercises reverts");
    }

    function _checkWadRay(string memory name, function(uint256, uint256) external pure returns (uint256) f)
        internal
        returns (uint256 reverts)
    {
        string[] memory xs = vm.parseJsonStringArray(gen, ".wadRay.x");
        string[] memory ys = vm.parseJsonStringArray(gen, ".wadRay.y");
        string[] memory want = vm.parseJsonStringArray(gen, string.concat(".wadRay.", name));
        for (uint256 i; i < xs.length; ++i) {
            (uint256 x, uint256 y) = (vm.parseUint(xs[i]), vm.parseUint(ys[i]));
            if (_isRevert(want[i])) {
                _expectPanic(want[i]);
                f(x, y);
                ++reverts;
            } else {
                assertEq(f(x, y), vm.parseUint(want[i]), name);
            }
        }
        assertEq(xs.length, 200);
    }

    function test_generated_wadRay() public {
        uint256 reverts = _checkWadRay("wmulDown", h.wmulDown) + _checkWadRay("wmulUp", h.wmulUp)
            + _checkWadRay("wdivDown", h.wdivDown) + _checkWadRay("wdivUp", h.wdivUp)
            + _checkWadRay("rmulDown", h.rmulDown) + _checkWadRay("rmulUp", h.rmulUp)
            + _checkWadRay("rdivDown", h.rdivDown) + _checkWadRay("rdivUp", h.rdivUp)
            + _checkWadRay("divUp", h.divUp);
        assertGt(reverts, 0, "generated wad/ray set exercises overflow");
    }

    function test_generated_rpow() public {
        string[] memory xs = vm.parseJsonStringArray(gen, ".rpow.x");
        string[] memory ns = vm.parseJsonStringArray(gen, ".rpow.n");
        string[] memory ups = vm.parseJsonStringArray(gen, ".rpow.up");
        string[] memory downs = vm.parseJsonStringArray(gen, ".rpow.down");
        uint256 overflows;
        for (uint256 i; i < xs.length; ++i) {
            (uint256 x, uint256 n) = (vm.parseUint(xs[i]), vm.parseUint(ns[i]));
            if (_isRevert(ups[i])) {
                _expectPanic(ups[i]);
                h.rpowUp(x, n);
                ++overflows;
            } else {
                assertEq(h.rpowUp(x, n), vm.parseUint(ups[i]), "generated rpow up");
            }
            if (_isRevert(downs[i])) {
                _expectPanic(downs[i]);
                h.rpowDown(x, n);
            } else {
                assertEq(h.rpowDown(x, n), vm.parseUint(downs[i]), "generated rpow down");
            }
        }
        assertEq(xs.length, 200);
        assertGt(overflows, 0, "generated set exercises rpow overflow");
    }
}
