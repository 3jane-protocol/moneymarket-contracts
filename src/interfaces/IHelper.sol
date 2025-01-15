// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {MarketParams} from "./IMorpho.sol";

/// @title IHelper
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IHelper {
    /// @notice The aave market
    function aaveMarket() external view returns (address);

    /// @notice The morpho contract.
    function morpho() external view returns (address);

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
