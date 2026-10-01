// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Id} from "../../src/interfaces/IMorpho.sol";

/// @title CycleObligationDataLib
/// @notice Library for cycle obligation data validation and processing
/// @dev Contains validation functions and constants for payment cycle management
library CycleObligationDataLib {
    /// @notice Maximum repayment basis points (100% = 10000 bps)
    uint256 public constant MAX_REPAYMENT_BPS = 10000;

    /// @notice Minimum ending balance (to avoid dust)
    uint256 public constant MIN_ENDING_BALANCE = 0; // Can be 0 for fully repaid

    /// @notice Maximum ending balance per borrower
    uint256 public constant MAX_ENDING_BALANCE = 100_000_000e6; // 100M USDC

    /// @notice Internal struct for processing cycle obligations
    struct ProcessedObligation {
        address borrower;
        uint256 repaymentBps;
        uint256 endingBalance;
    }

    /// @notice Validate repayment basis points
    /// @param repaymentBps The repayment percentage in basis points
    /// @return valid True if repaymentBps is within acceptable range
    function validateRepaymentBps(uint256 repaymentBps) internal pure returns (bool valid) {
        return repaymentBps <= MAX_REPAYMENT_BPS;
    }

    /// @notice Validate ending balance
    /// @param endingBalance The ending balance amount
    /// @return valid True if ending balance is within acceptable range
    function validateEndingBalance(uint256 endingBalance) internal pure returns (bool valid) {
        return endingBalance <= MAX_ENDING_BALANCE;
    }

    /// @notice Validate all obligation parameters
    /// @param borrower The borrower address
    /// @param repaymentBps The repayment percentage in basis points
    /// @param endingBalance The ending balance amount
    /// @return valid True if all parameters are valid
    function validateObligation(address borrower, uint256 repaymentBps, uint256 endingBalance)
        internal
        pure
        returns (bool valid)
    {
        if (borrower == address(0)) return false;
        if (!validateRepaymentBps(repaymentBps)) return false;
        if (!validateEndingBalance(endingBalance)) return false;
        return true;
    }

    /// @notice Convert percentage to basis points
    /// @param percentage The percentage value (e.g., 5 for 5%)
    /// @return bps The value in basis points (e.g., 500 for 5%)
    function percentageToBps(uint256 percentage) internal pure returns (uint256 bps) {
        require(percentage <= 100, "Percentage exceeds 100%");
        return percentage * 100;
    }

    /// @notice Convert basis points to percentage
    /// @param bps The value in basis points
    /// @return percentage The percentage value
    function bpsToPercentage(uint256 bps) internal pure returns (uint256 percentage) {
        require(bps <= MAX_REPAYMENT_BPS, "BPS exceeds maximum");
        return bps / 100;
    }

    /// @notice Format amount for display (assumes 6 decimals)
    /// @param amount The amount to format
    /// @return formatted The formatted amount in whole units
    function formatAmount(uint256 amount) internal pure returns (uint256 formatted) {
        return amount / 1e6;
    }

    /// @notice Parse amount from whole units to token decimals (assumes 6 decimals)
    /// @param wholeUnits The amount in whole units
    /// @return amount The amount in token decimals
    function parseAmount(uint256 wholeUnits) internal pure returns (uint256 amount) {
        return wholeUnits * 1e6;
    }

    /// @notice Validate end date
    /// @param endDate The cycle end date (Unix timestamp)
    /// @return valid True if end date is reasonable
    function validateEndDate(uint256 endDate) internal view returns (bool valid) {
        // Must be in the past or very near future (allow 1 hour buffer)
        return endDate <= block.timestamp + 1 hours;
    }
}
