// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title ITokenizedStrategy
/// @notice Interface for tokenized strategy reporting
interface ITokenizedStrategy {
    /// @notice Report profit and loss for the strategy
    /// @return profit Amount of profit generated
    /// @return loss Amount of loss incurred
    function report() external returns (uint256 profit, uint256 loss);

    /// @notice Timestamp when locked profit is fully unlocked
    /// @return unlockDate Unix timestamp for full profit unlock
    function fullProfitUnlockDate() external view returns (uint256 unlockDate);

    /// @notice Current performance fee in basis points
    /// @return fee Performance fee
    function performanceFee() external view returns (uint16 fee);

    /// @notice Maximum time over which profit unlocks
    /// @return unlockTime Profit max unlock time in seconds
    function profitMaxUnlockTime() external view returns (uint256 unlockTime);
}
