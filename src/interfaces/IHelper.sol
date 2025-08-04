// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC4626} from "../../lib/forge-std/src/interfaces/IERC4626.sol";

import {MarketParams} from "./IMorpho.sol";

/// @title IHelper
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IHelper {
    /// @notice The morpho contract.
    function MORPHO() external view returns (address);

    /// @notice The USD3 token address.
    function USD3() external view returns (address);

    /// @notice The sUSD3 token address.
    function sUSD3() external view returns (address);

    /// @notice The USDC token address.
    function USDC() external view returns (address);

    /// @notice The WAUSDC token address.
    function WAUSDC() external view returns (address);

    /// @notice Deposit
    function deposit(uint256 assets, address receiver, bool hop) external returns (uint256);

    /// @notice Redeem
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);

    /// @notice Borrow
    function borrow(MarketParams memory marketParams, uint256 assets) external returns (uint256, uint256);

    /// @notice Repay
    function repay(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256);
}
