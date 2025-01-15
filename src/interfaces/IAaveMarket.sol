// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IAaveMarket
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IAaveMarket {
    /// @notice Supply
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraw
    function withdraw(address asset, uint256 amount, address to) external;
}

/// @title IAaveToken
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IAaveToken {
    /// @notice UNDERLYING_ASSET_ADDRESS
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
