// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC4626} from "../../lib/forge-std/src/interfaces/IERC4626.sol";

import {MarketParams} from "./IMorpho.sol";

/// @title IHelper
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IHelper {
    /// @notice The aave market
    function aaveMarket() external view returns (address);

    /// @notice The morpho contract.
    function morpho() external view returns (address);

    /// @notice Deposit
    function deposit(IERC4626 vault, uint256 assets, address receiver) external returns (uint256);

    /// @notice Redeem
    function redeem(IERC4626 vault, uint256 shares, address receiver, address owner) external returns (uint256);

    /// @notice Borrow
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);

    /// @notice Repay
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
}
