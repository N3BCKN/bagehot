// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BagehotFactory} from "../src/deploy/BagehotFactory.sol";
import {DeployConfig} from "./Config.s.sol";
import {Deploy} from "./Deploy.s.sol";
import {console} from "forge-std/console.sol";

/// @title DiffDeploy
/// @notice Deployment A for the differential test (P23) on a local anvil: the audited `Deploy.deploy`
///         path — local mocks, blueprints, the factory, the §3.3 checks — with the variant forced to A
///         and no manifest written (`deployments/` holds real deployments only). Prints the addresses
///         on one line, `DIFF_DEPLOY <factory> <weth> <priceFeed> <sequencerFeed>`, for the harness.
///         Run with `--unlocked --sender <anvil account>`: no key is involved.
contract DiffDeploy is Deploy {
    function runDiff() external returns (BagehotFactory f) {
        checkChain(block.chainid);
        if (block.chainid != ANVIL) revert StandInsAreLocalOnly(block.chainid);
        DeployConfig memory c = loadConfig(block.chainid);
        string memory t = vm.readFile(configPath(block.chainid));
        (c.variantB, c.poolShareBps) = (false, vm.parseTomlUint(t, ".params.pool_share_bps_a"));
        (f, c) = deploy(c);
        console.log(
            string.concat(
                "DIFF_DEPLOY ",
                vm.toString(address(f)),
                " ",
                vm.toString(c.weth),
                " ",
                vm.toString(c.priceFeed),
                " ",
                vm.toString(c.sequencerFeed)
            )
        );
    }
}
