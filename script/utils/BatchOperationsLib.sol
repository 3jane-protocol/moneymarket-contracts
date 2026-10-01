// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {MorphoCredit} from "../../src/MorphoCredit.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";

/// @title BatchOperationsLib
/// @notice Library for encoding various protocol operations for batching
/// @dev Provides helper functions to encode common protocol operations
library BatchOperationsLib {
    /// @notice Encode a setConfig call for ProtocolConfig
    /// @param key The configuration key
    /// @param value The configuration value
    /// @return Encoded function call
    function encodeSetConfig(bytes32 key, uint256 value) internal pure returns (bytes memory) {
        return abi.encodeCall(ProtocolConfig.setConfig, (key, value));
    }

    /// @notice Encode a setCreditLines call for CreditLine contract
    /// @param ids Market IDs for each credit line
    /// @param borrowers Borrower addresses
    /// @param vvs Valuation values
    /// @param credits Credit amounts
    /// @param drps Risk premium rates
    /// @return Encoded function call
    function encodeSetCreditLines(
        Id[] memory ids,
        address[] memory borrowers,
        uint256[] memory vvs,
        uint256[] memory credits,
        uint128[] memory drps
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(CreditLine.setCreditLines, (ids, borrowers, vvs, credits, drps));
    }

    /// @notice Encode a setOwner call for ProtocolConfig
    /// @param newOwner The new owner address
    /// @return Encoded function call
    function encodeSetOwner(address newOwner) internal pure returns (bytes memory) {
        return abi.encodeCall(ProtocolConfig.setOwner, (newOwner));
    }

    /// @notice Generate common configuration keys
    /// @dev These match the keys in ProtocolConfig.sol
    function getConfigKey(string memory keyName) internal pure returns (bytes32) {
        if (_strEquals(keyName, "MAX_LTV")) return keccak256("MAX_LTV");
        if (_strEquals(keyName, "MAX_VV")) return keccak256("MAX_VV");
        if (_strEquals(keyName, "MAX_CREDIT_LINE")) return keccak256("MAX_CREDIT_LINE");
        if (_strEquals(keyName, "MIN_CREDIT_LINE")) return keccak256("MIN_CREDIT_LINE");
        if (_strEquals(keyName, "MAX_DRP")) return keccak256("MAX_DRP");
        if (_strEquals(keyName, "IS_PAUSED")) return keccak256("IS_PAUSED");
        if (_strEquals(keyName, "MAX_ON_CREDIT")) return keccak256("MAX_ON_CREDIT");
        if (_strEquals(keyName, "IRP")) return keccak256("IRP");
        if (_strEquals(keyName, "MIN_BORROW")) return keccak256("MIN_BORROW");
        if (_strEquals(keyName, "GRACE_PERIOD")) return keccak256("GRACE_PERIOD");
        if (_strEquals(keyName, "DELINQUENCY_PERIOD")) return keccak256("DELINQUENCY_PERIOD");
        if (_strEquals(keyName, "CYCLE_DURATION")) return keccak256("CYCLE_DURATION");
        if (_strEquals(keyName, "CURVE_STEEPNESS")) return keccak256("CURVE_STEEPNESS");
        if (_strEquals(keyName, "ADJUSTMENT_SPEED")) return keccak256("ADJUSTMENT_SPEED");
        if (_strEquals(keyName, "TARGET_UTILIZATION")) return keccak256("TARGET_UTILIZATION");
        if (_strEquals(keyName, "INITIAL_RATE_AT_TARGET")) return keccak256("INITIAL_RATE_AT_TARGET");
        if (_strEquals(keyName, "MIN_RATE_AT_TARGET")) return keccak256("MIN_RATE_AT_TARGET");
        if (_strEquals(keyName, "MAX_RATE_AT_TARGET")) return keccak256("MAX_RATE_AT_TARGET");
        if (_strEquals(keyName, "TRANCHE_RATIO")) return keccak256("TRANCHE_RATIO");
        if (_strEquals(keyName, "TRANCHE_SHARE_VARIANT")) return keccak256("TRANCHE_SHARE_VARIANT");
        if (_strEquals(keyName, "SUSD3_LOCK_DURATION")) return keccak256("SUSD3_LOCK_DURATION");
        if (_strEquals(keyName, "SUSD3_COOLDOWN_PERIOD")) return keccak256("SUSD3_COOLDOWN_PERIOD");
        if (_strEquals(keyName, "USD3_COMMITMENT_TIME")) return keccak256("USD3_COMMITMENT_TIME");
        if (_strEquals(keyName, "SUSD3_WITHDRAWAL_WINDOW")) return keccak256("SUSD3_WITHDRAWAL_WINDOW");
        if (_strEquals(keyName, "USD3_SUPPLY_CAP")) return keccak256("USD3_SUPPLY_CAP");

        // If not found, return the keccak256 of the string
        return keccak256(bytes(keyName));
    }

    /// @notice Compare two strings for equality
    function _strEquals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Validate DRP value (must be between 0 and 10000 basis points)
    /// @param drp The DRP value to validate
    /// @return True if valid
    function validateDrp(uint128 drp) internal pure returns (bool) {
        return drp <= 10000; // Max 100% in basis points
    }
}
