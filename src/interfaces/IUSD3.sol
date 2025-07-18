// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IUSD3
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IUSD3 {
    /// @notice Deposit
    function deposit(uint256 assets, address receiver) external returns (uint256);

    /// @notice Withdraw
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}
