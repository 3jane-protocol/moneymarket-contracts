// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IJane
/// @notice Minimal JANE token interface used by reward distribution
interface IJane is IERC20 {
    /// @notice Mints `value` tokens to `account`
    function mint(address account, uint256 value) external;
}
