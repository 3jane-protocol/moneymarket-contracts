// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title ITokenizedStrategy
/// @notice Interface for tokenized strategy reporting
interface ITokenizedStrategy {
    /// @notice Report profit and loss for the strategy
    /// @return profit Amount of profit generated
    /// @return loss Amount of loss incurred
    function report() external returns (uint256 profit, uint256 loss);
}
