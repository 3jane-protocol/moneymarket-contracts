// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IStataTokenV2
/// @notice Minimal Aave static aToken interface used by the LCC margin deposit helper.
interface IStataTokenV2 is IERC20 {
    function asset() external view returns (address);
    function aToken() external view returns (address);
    function maxDeposit(address account) external view returns (uint256);
    function deposit(uint256 assets, address account) external returns (uint256 shares);
    function depositATokens(uint256 assets, address account) external returns (uint256 shares);
}
