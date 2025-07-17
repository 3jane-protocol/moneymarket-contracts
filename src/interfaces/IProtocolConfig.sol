// SPDX-License-Identifier: GPL-20later
pragma solidity >=0.5.0;
/// @notice Interface for the ProtocolConfig contract

interface IProtocolConfig {
    /// @dev Initialize the contract with the owner
    /// @param newOwner The address of the new owner
    function initialize(address newOwner) external;

    /// @dev Set a configuration value
    /// @param key The configuration key
    /// @param value The configuration value
    function setConfig(bytes32 key, uint256 value) external;

    /// @dev Get the maximum loan-to-value ratio
    /// @return The maximum LTV value
    function getMaxLTV() external view returns (uint256);

    /// @dev Get the maximum credit line
    /// @return The maximum credit line value
    function getMaxCreditLine() external view returns (uint256);

    /// @dev Get the minimum credit line
    /// @return The minimum credit line value
    function getMinCreditLine() external view returns (uint256);

    /// @dev Get the minimum borrow amount
    /// @return The minimum borrow value
    function getMinBorrow() external view returns (uint256);

    /// @dev Get the maximum default risk premium
    /// @return The maximum DRP value
    function getMaxDRP() external view returns (uint256);

    /// @dev Get the maximum interest rate premium
    /// @return The maximum IRP value
    function getMaxIRP() external view returns (uint256);

    /// @dev Get the grace period
    /// @return The grace period value
    function getGracePeriod() external view returns (uint256);

    /// @dev Get the delinquency period
    /// @return The delinquency period value
    function getDelinquencyPeriod() external view returns (uint256);

    /// @dev Get the pause status
    /// @return The pause status value
    function getIsPaused() external view returns (uint256);

    /// @dev Get the maximum overcollateralization
    /// @return The maximum OC value
    function getMaxOC() external view returns (uint256);

    /// @dev Get the tranche ratio
    /// @return The tranche ratio value
    function getTrancheRatio() external view returns (uint256);

    /// @dev Get the tranche share variant
    /// @return The tranche share variant value
    function getTrancheShareVariant() external view returns (uint256);

    /// @dev Get the SUSD3 lock duration
    /// @return The SUSD3 lock duration value
    function getSusd3LockDuration() external view returns (uint256);

    /// @dev Get the SUSD3 cooldown period
    /// @return The SUSD3 cooldown period value
    function getSusd3CooldownPeriod() external view returns (uint256);

    /// @dev Get configuration value by key
    /// @param key The configuration key
    /// @return The configuration value
    function config(bytes32 key) external view returns (uint256);
}
