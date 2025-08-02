// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IWrap
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IWrap {
    /// @notice Deposit
    function deposit(uint256 assets, address receiver) external returns (uint256);

    /// @notice Withdraw
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}
