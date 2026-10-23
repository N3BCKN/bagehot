// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice StableToken: the ERC-20 surface plus the privileged functions core contracts call (§5.9).
interface IStableToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function moveFrom(address account, address to, uint256 amount) external;
}
