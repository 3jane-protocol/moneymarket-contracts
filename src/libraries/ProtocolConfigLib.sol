// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title ProtocolConfigLib
/// @notice Library containing all configuration keys for ProtocolConfig
/// @dev Centralizes all configuration keys to avoid magic strings and improve maintainability
library ProtocolConfigLib {
    // Credit Line Keys
    bytes32 internal constant MAX_LTV = keccak256("MAX_LTV");
    bytes32 internal constant MAX_VV = keccak256("MAX_VV");
    bytes32 internal constant MAX_CREDIT_LINE = keccak256("MAX_CREDIT_LINE");
    bytes32 internal constant MIN_CREDIT_LINE = keccak256("MIN_CREDIT_LINE");
    bytes32 internal constant MAX_DRP = keccak256("MAX_DRP");

    // Market Keys
    bytes32 internal constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 internal constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 internal constant IRP = keccak256("IRP");
    bytes32 internal constant MIN_BORROW = keccak256("MIN_BORROW");
    bytes32 internal constant GRACE_PERIOD = keccak256("GRACE_PERIOD");
    bytes32 internal constant DELINQUENCY_PERIOD = keccak256("DELINQUENCY_PERIOD");
    bytes32 internal constant CYCLE_DURATION = keccak256("CYCLE_DURATION");
    bytes32 internal constant DEBT_CAP = keccak256("DEBT_CAP");

    // IRM Keys
    bytes32 internal constant CURVE_STEEPNESS = keccak256("CURVE_STEEPNESS");
    bytes32 internal constant ADJUSTMENT_SPEED = keccak256("ADJUSTMENT_SPEED");
    bytes32 internal constant TARGET_UTILIZATION = keccak256("TARGET_UTILIZATION");
    bytes32 internal constant INITIAL_RATE_AT_TARGET = keccak256("INITIAL_RATE_AT_TARGET");
    bytes32 internal constant MIN_RATE_AT_TARGET = keccak256("MIN_RATE_AT_TARGET");
    bytes32 internal constant MAX_RATE_AT_TARGET = keccak256("MAX_RATE_AT_TARGET");

    // USD3 & sUSD3 Keys
    bytes32 internal constant TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
    bytes32 internal constant TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
    bytes32 internal constant SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
    bytes32 internal constant SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");
    bytes32 internal constant USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
    bytes32 internal constant SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");
    bytes32 internal constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");
    bytes32 internal constant MIN_SUSD3_BACKING_RATIO = keccak256("MIN_SUSD3_BACKING_RATIO");

    // Markdown Keys
    bytes32 internal constant FULL_MARKDOWN_DURATION = keccak256("FULL_MARKDOWN_DURATION");
}
