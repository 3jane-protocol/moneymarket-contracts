// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ConstantsLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
library ConstantsLib {
    /// @notice Curve steepness (scaled by WAD).
    /// @dev Curve steepness = 4.
    int256 public constant CURVE_STEEPNESS = 4 ether;

    /// @notice Adjustment speed per second (scaled by WAD).
    /// @dev Adjustment speed = 50/an.
    int256 public constant ADJUSTMENT_SPEED = int256(50 ether) / 365 days;

    /// @notice Target utilization (scaled by WAD).
    /// @dev Target utilization = 90%.
    int256 public constant TARGET_UTILIZATION = 0.90 ether;

    /// @notice Initial rate at target per second (scaled by WAD).
    /// @dev Initial rate at target = 4% (rate between 1% and 16%).
    int256 public constant INITIAL_RATE_AT_TARGET = 0.04 ether / int256(365 days);

    /// @notice Minimum rate at target per second (scaled by WAD).
    /// @dev Minimum rate at target = 0.1% (minimum rate = 0.025%).
    int256 public constant MIN_RATE_AT_TARGET = 0.001 ether / int256(365 days);

    /// @notice Maximum rate at target per second (scaled by WAD).
    /// @dev Maximum rate at target = 200% (maximum rate = 800%).
    int256 public constant MAX_RATE_AT_TARGET = 2.00 ether / int256(365 days);
}
