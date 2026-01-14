// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title ProtocolConfigLib
/// @notice Library containing all configuration keys for ProtocolConfig
/// @dev Centralizes all configuration keys to avoid magic strings and improve maintainability
library ProtocolConfigLib {
    // Market Control Keys
    bytes32 internal constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 internal constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 internal constant DEBT_CAP = keccak256("DEBT_CAP");
    bytes32 internal constant CC_FROZEN = keccak256("CC_FROZEN");
    bytes32 internal constant CC_DEBT_CAP_BPS = keccak256("CC_DEBT_CAP_BPS");
    bytes32 internal constant CC_CREDIT_LINE_BPS = keccak256("CC_CREDIT_LINE_BPS");
    bytes32 internal constant CC_ORIGINATION_FEE_BPS = keccak256("CC_ORIGINATION_FEE_BPS");
    bytes32 internal constant CC_FEE_RECIPIENT = keccak256("CC_FEE_RECIPIENT");
    bytes32 internal constant CC_THROTTLE_PERIOD = keccak256("CC_THROTTLE_PERIOD");
    bytes32 internal constant CC_THROTTLE_LIMIT = keccak256("CC_THROTTLE_LIMIT");

    // Credit Line Keys
    bytes32 internal constant MIN_LOAN_DURATION = keccak256("MIN_LOAN_DURATION");
    bytes32 internal constant LATE_REPAYMENT_THRESHOLD = keccak256("LATE_REPAYMENT_THRESHOLD");
    bytes32 internal constant DEFAULT_THRESHOLD = keccak256("DEFAULT_THRESHOLD");
    bytes32 internal constant GRACE_PERIOD = keccak256("GRACE_PERIOD");

    // Interest Rate Keys
    bytes32 internal constant CURVE_STEEPNESS = keccak256("CURVE_STEEPNESS");
    bytes32 internal constant ADJUSTMENT_SPEED = keccak256("ADJUSTMENT_SPEED");
    bytes32 internal constant TARGET_UTILIZATION = keccak256("TARGET_UTILIZATION");
    bytes32 internal constant INITIAL_RATE_AT_TARGET = keccak256("INITIAL_RATE_AT_TARGET");
    bytes32 internal constant MIN_RATE_AT_TARGET = keccak256("MIN_RATE_AT_TARGET");
    bytes32 internal constant MAX_RATE_AT_TARGET = keccak256("MAX_RATE_AT_TARGET");

    // Tranche Keys (USD3 & sUSD3)
    bytes32 internal constant TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
    bytes32 internal constant TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
    bytes32 internal constant MIN_SUSD3_BACKING_RATIO = keccak256("MIN_SUSD3_BACKING_RATIO");

    // Timing Keys
    bytes32 internal constant SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
    bytes32 internal constant SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");
    bytes32 internal constant USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
    bytes32 internal constant SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");

    // Supply Cap Keys
    bytes32 internal constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");

    // Markdown Keys
    bytes32 internal constant FULL_MARKDOWN_DURATION = keccak256("FULL_MARKDOWN_DURATION");
}
