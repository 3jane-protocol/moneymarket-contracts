// SPDX-License-Identifier: GPL-20later
pragma solidity ^0.8.18;

/// @notice Interface for the ProtocolConfig contract

// Struct to hold market parameters
struct MarketConfig {
    uint256 gracePeriod; // Duration of grace period after cycle end
    uint256 delinquencyPeriod; // Duration of delinquency period before default
    uint256 minBorrow; // Minimum outstanding loan balance to prevent dust
    uint256 irp; // Penalty rate per second for delinquent borrowers
}

// Struct to hold credit line parameters
struct CreditLineConfig {
    uint256 maxLTV;
    uint256 maxVV;
    uint256 maxCreditLine;
    uint256 minCreditLine;
    uint256 maxDRP;
}

// Struct to hold IRM parameters
struct IRMConfig {
    uint256 curveSteepness;
    uint256 adjustmentSpeed;
    uint256 targetUtilization;
    uint256 initialRateAtTarget;
    uint256 minRateAtTarget;
    uint256 maxRateAtTarget;
}

/// @notice Struct to hold IRM parameters with int256 types for internal calculations
struct IRMConfigTyped {
    int256 curveSteepness;
    int256 adjustmentSpeed;
    int256 targetUtilization;
    int256 initialRateAtTarget;
    int256 minRateAtTarget;
    int256 maxRateAtTarget;
}

interface IProtocolConfig {
    /// @dev Initialize the contract with the owner
    /// @param newOwner The address of the new owner
    function initialize(address newOwner) external;

    /// @dev Set a configuration value
    /// @param key The configuration key
    /// @param value The configuration value
    function setConfig(bytes32 key, uint256 value) external;

    // Credit Line getters
    /// @dev Get the credit line parameters
    /// @return The credit line parameters
    function getCreditLineConfig() external view returns (CreditLineConfig memory);

    // Market getters
    /// @dev Get the pause status
    /// @return The pause status value
    function getIsPaused() external view returns (uint256);

    /// @dev Get the maximum on credit
    /// @return The max on credit value
    function getMaxOnCredit() external view returns (uint256);

    /// @dev Get the market parameters
    /// @return The market parameters
    function getMarketConfig() external view returns (MarketConfig memory);

    /// @dev Get the cycle duration for payment cycles
    /// @return The cycle duration in seconds
    function getCycleDuration() external view returns (uint256);

    // IRM getters
    /// @dev Get the IRM parameters
    /// @return The IRM parameters
    function getIRMConfig() external view returns (IRMConfig memory);

    // USD3 & sUSD3 getters
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

    /// @dev Get the USD3 commitment time
    /// @return The lock period in seconds
    function getUsd3CommitmentTime() external view returns (uint256);

    /// @dev Get the sUSD3 withdrawal window
    /// @return The withdrawal window duration in seconds after cooldown
    function getSusd3WithdrawalWindow() external view returns (uint256);

    /// @dev Get the USD3 supply cap
    /// @return The supply cap in asset units (0 means no cap)
    function getUsd3SupplyCap() external view returns (uint256);

    /// @dev Get configuration value by key
    /// @param key The configuration key
    /// @return The configuration value
    function config(bytes32 key) external view returns (uint256);
}
