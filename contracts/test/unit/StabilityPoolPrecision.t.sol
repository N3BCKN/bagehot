// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolFixture} from "../utils/PoolFixture.sol";

/// @notice Replays the sequences `model/tools/sp_precision.py` generated (P19 precision study) against
///         the contract and asserts bit equality with the integer model after every step: `T`, `P`,
///         scale, epoch, both carries, both gains balances, and every depositor's compounded deposit
///         and gains. The study's error statistics against exact rationals are in docs/fuzzing.md.
contract StabilityPoolPrecisionTest is PoolFixture {
    address[5] internal actors;

    function setUp() public {
        for (uint256 i; i < 5; ++i) {
            actors[i] = makeAddr(string.concat("a", vm.toString(i)));
        }
    }

    function test_replay_case0() public {
        _replay(0);
    }

    function test_replay_case1() public {
        _replay(1);
    }

    function test_replay_case2() public {
        _replay(2);
    }

    function test_replay_case3() public {
        _replay(3);
    }

    function test_replay_case4() public {
        _replay(4);
    }

    function test_replay_case5() public {
        _replay(5);
    }

    function test_replay_case6() public {
        _replay(6);
    }

    function test_replay_case7() public {
        _replay(7);
    }

    struct Case {
        uint256[] op;
        string[] x;
        string[] y;
        string[] state;
        uint256 width;
    }

    function _replay(uint256 n) internal {
        string memory json =
            vm.readFile(string.concat("test/data/sp_precision/case_", vm.toString(n), ".json"));
        Case memory c = Case(
            vm.parseJsonUintArray(json, ".op"),
            vm.parseJsonStringArray(json, ".x"),
            vm.parseJsonStringArray(json, ".y"),
            vm.parseJsonStringArray(json, ".state"),
            vm.parseJsonUint(json, ".stateWidth")
        );
        assertEq(c.width, 23, "8 state values + 3 per actor");
        _deployPool(vm.parseUint(vm.parseJsonString(json, ".MIN_DEPOSIT")));
        for (uint256 i; i < 5; ++i) {
            _fund(actors[i], 1e33);
        }
        for (uint256 j; j < c.op.length; ++j) {
            _step(c.op[j], vm.parseUint(c.x[j]), vm.parseUint(c.y[j]));
            _check(c, j);
        }
        assertGt(c.op.length, 0, "case has steps");
    }

    function _step(uint256 op, uint256 x, uint256 y) internal {
        if (op == 3) {
            tv.offset(x, y);
        } else if (op == 4) {
            tv.interest(y);
        } else {
            vm.prank(actors[x]);
            if (op == 0) pool.deposit(y);
            else if (op == 1) pool.withdraw(y);
            else pool.claimGains();
        }
    }

    function _check(Case memory c, uint256 j) internal view {
        uint256 b = j * c.width;
        uint256[8] memory got = [
            pool.totalDeposits(),
            pool.P(),
            pool.currentScale(),
            pool.currentEpoch(),
            pool.lastCollError(),
            pool.lastInterestError(),
            pool.collGainsBalance(),
            pool.interestGainsBalance()
        ];
        for (uint256 k; k < 8; ++k) {
            if (got[k] != vm.parseUint(c.state[b + k])) {
                revert(string.concat("state field ", vm.toString(k), " differs at step ", vm.toString(j)));
            }
        }
        for (uint256 i; i < 5; ++i) {
            uint256 o = b + 8 + 3 * i;
            (uint256 cg, uint256 ig) = pool.gains(actors[i]);
            if (
                pool.compoundedDeposit(actors[i]) != vm.parseUint(c.state[o])
                    || cg != vm.parseUint(c.state[o + 1]) || ig != vm.parseUint(c.state[o + 2])
            ) revert(string.concat("depositor ", vm.toString(i), " differs at step ", vm.toString(j)));
        }
    }
}
