// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Id} from "../../src/interfaces/IMorpho.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/// @title CreditLineDataLib
/// @notice Library for credit line data validation and processing
/// @dev Contains validation functions and constants for credit line management
library CreditLineDataLib {
    using MathLib for uint256;

    /// @notice Maximum default risk premium allowed (100% APR)
    /// @dev ~31.7 billion per second for 100% APR
    uint256 public constant MAX_DRP = 31709791983;

    /// @notice Minimum credit line amount (to avoid dust)
    uint256 public constant MIN_CREDIT_LINE = 1e6; // 1 USDC for 6 decimal token

    /// @notice Maximum credit line amount per borrower
    uint256 public constant MAX_CREDIT_LINE = 10_000_000e6; // 10M USDC

    /// @notice Maximum loan-to-value ratio (95%)
    uint256 public constant MAX_LTV = 0.95e18; // 95% in WAD

    /// @notice Internal struct for processing credit lines
    struct ProcessedCreditLine {
        Id marketId;
        address borrower;
        uint256 valueVerified;
        uint256 creditAmount;
        uint128 defaultRiskPremium;
    }

    /// @notice Validate default risk premium
    /// @param drp The default risk premium to validate
    /// @return valid True if DRP is within acceptable range
    function validateDrp(uint128 drp) internal pure returns (bool valid) {
        return drp <= MAX_DRP;
    }

    /// @notice Validate credit amount
    /// @param credit The credit amount to validate
    /// @return valid True if credit is within acceptable range
    function validateCredit(uint256 credit) internal pure returns (bool valid) {
        return credit >= MIN_CREDIT_LINE && credit <= MAX_CREDIT_LINE;
    }

    /// @notice Validate loan-to-value ratio
    /// @param credit The credit amount
    /// @param vv The value verified (collateral value)
    /// @return valid True if LTV is within acceptable range
    function validateLtv(uint256 credit, uint256 vv) internal pure returns (bool valid) {
        if (vv == 0) return false;
        return credit.wDivDown(vv) <= MAX_LTV;
    }

    /// @notice Validate all credit line parameters
    /// @param borrower The borrower address
    /// @param vv The value verified
    /// @param credit The credit amount
    /// @param drp The default risk premium
    /// @return valid True if all parameters are valid
    function validateCreditLine(address borrower, uint256 vv, uint256 credit, uint128 drp)
        internal
        pure
        returns (bool valid)
    {
        if (borrower == address(0)) return false;
        if (!validateDrp(drp)) return false;
        if (!validateCredit(credit)) return false;
        if (!validateLtv(credit, vv)) return false;
        return true;
    }

    /// @notice Calculate the annual percentage rate from DRP
    /// @param drp The default risk premium per second (scaled by WAD)
    /// @return apr The annual percentage rate (in basis points)
    function drpToApr(uint128 drp) internal pure returns (uint256 apr) {
        // Convert per-second rate to annual rate
        // drp is in WAD per second, multiply by seconds in year
        uint256 annualRate = uint256(drp) * 365 days;
        // Convert to basis points (divide by WAD, multiply by 10000)
        return (annualRate * 10000) / 1e18;
    }

    /// @notice Calculate DRP from annual percentage rate
    /// @param aprBps The annual percentage rate in basis points
    /// @return drp The default risk premium per second (scaled by WAD)
    function aprToDrp(uint256 aprBps) internal pure returns (uint128 drp) {
        // Convert basis points to WAD
        uint256 annualRate = (aprBps * 1e18) / 10000;
        // Convert to per-second rate
        uint256 perSecondRate = annualRate / 365 days;
        require(perSecondRate <= type(uint128).max, "DRP overflow");
        return uint128(perSecondRate);
    }

    /// @notice Format credit amount for display (assumes 6 decimals)
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
}
