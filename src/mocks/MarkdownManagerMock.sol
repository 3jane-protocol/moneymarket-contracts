// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMarkdownManager} from "../interfaces/IMarkdownManager.sol";
import {Id} from "../interfaces/IMorpho.sol";

/// @title MarkdownManagerMock
/// @notice Mock implementation of IMarkdownManager for testing
/// @dev Implements a simple linear markdown based on time in default
contract MarkdownManagerMock is IMarkdownManager {
    /// @notice The daily markdown rate (in basis points)
    /// @dev Default: 100 bps per day (1% per day)
    uint256 public dailyMarkdownBps = 100;

    /// @notice The maximum markdown percentage (in basis points)
    /// @dev Default: 7000 bps (70% markdown)
    uint256 public maxMarkdownBps = 7000;

    /// @notice Basis points denominator
    uint256 internal constant BPS = 10000;

    /// @notice WAD for percentage calculations
    uint256 internal constant WAD = 1e18;

    /// @notice Seconds in a day
    uint256 internal constant SECONDS_PER_DAY = 86400;

    /// @notice Mapping from borrower address to custom markdown amount
    mapping(address => uint256) public markdowns;

    /// @notice Set the daily markdown rate
    /// @param _dailyMarkdownBps New daily markdown rate in basis points
    function setDailyMarkdownRate(uint256 _dailyMarkdownBps) external {
        require(_dailyMarkdownBps <= BPS, "Rate exceeds 100%");
        dailyMarkdownBps = _dailyMarkdownBps;
    }

    /// @notice Set the maximum markdown percentage
    /// @param _maxMarkdownBps New maximum markdown in basis points
    function setMaxMarkdown(uint256 _maxMarkdownBps) external {
        require(_maxMarkdownBps <= BPS, "Max exceeds 100%");
        maxMarkdownBps = _maxMarkdownBps;
    }

    /// @inheritdoc IMarkdownManager
    function calculateMarkdown(address borrower, uint256 borrowAmount, uint256 timeInDefault)
        external
        view
        returns (uint256 markdownAmount)
    {
        if (markdowns[borrower] > 0) {
            return markdowns[borrower];
        }

        if (timeInDefault == 0) return 0;

        uint256 daysInDefault = timeInDefault / SECONDS_PER_DAY;

        // Calculate markdown percentage (capped at max)
        uint256 markdownBps = daysInDefault * dailyMarkdownBps;
        if (markdownBps > maxMarkdownBps) {
            markdownBps = maxMarkdownBps;
        }

        // Calculate markdown amount
        markdownAmount = (borrowAmount * markdownBps) / BPS;
    }

    /// @inheritdoc IMarkdownManager
    function getMarkdownMultiplier(uint256 timeInDefault) external view returns (uint256 multiplier) {
        if (timeInDefault == 0) {
            return WAD; // 100% value
        }

        uint256 daysInDefault = timeInDefault / SECONDS_PER_DAY;

        // Calculate markdown percentage (capped at max)
        uint256 markdownBps = daysInDefault * dailyMarkdownBps;
        if (markdownBps > maxMarkdownBps) {
            markdownBps = maxMarkdownBps;
        }

        // Convert to multiplier (1 - markdown%)
        uint256 remainingValueBps = BPS - markdownBps;
        multiplier = (remainingValueBps * WAD) / BPS;
    }

    /// @inheritdoc IMarkdownManager
    function isValidForMarket(Id) external pure returns (bool) {
        // Mock always returns true for any market
        return true;
    }
}
