// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMarkdownController} from "../interfaces/IMarkdownController.sol";
import {IProtocolConfig} from "../interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../libraries/ProtocolConfigLib.sol";
import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";

/// @title MarkdownManagerMock
/// @notice Mock implementation of IMarkdownController for testing
/// @dev Extends the production MarkdownController with additional testing capabilities
contract MarkdownManagerMock is IMarkdownController, Ownable {
    /// @notice WAD constant for percentage calculations (1e18 = 100%)
    uint256 private constant WAD = 1e18;

    /// @notice The protocol config contract address
    address public immutable protocolConfig;

    /// @notice Mapping of borrowers with markdown enabled
    mapping(address => bool) public markdownEnabled;

    /// @notice Mapping from borrower address to custom markdown amount (for testing)
    mapping(address => uint256) public customMarkdowns;

    /// @notice Override duration for testing (0 means use protocol config)
    uint256 public overrideDuration;

    /// @notice Emitted when markdown is enabled or disabled for a borrower
    /// @param borrower The borrower address
    /// @param enabled Whether markdown is enabled
    event MarkdownEnabledUpdated(address indexed borrower, bool enabled);

    /// @notice Constructor
    /// @param _protocolConfig The protocol config contract address
    /// @param _owner The owner address
    constructor(address _protocolConfig, address _owner) Ownable(_owner) {
        require(_protocolConfig != address(0), "Invalid protocol config");
        protocolConfig = _protocolConfig;
    }

    /// @notice Mock does not check repayment status like production MarkdownController
    /// @dev This is intentional to allow simpler test setup without full MorphoCredit integration

    /// @notice Enable or disable markdown for a borrower
    /// @param borrower The borrower address
    /// @param enabled Whether to enable markdown
    function setEnableMarkdown(address borrower, bool enabled) external onlyOwner {
        markdownEnabled[borrower] = enabled;
        emit MarkdownEnabledUpdated(borrower, enabled);
    }

    /// @notice Set a custom markdown amount for testing
    /// @param borrower The borrower address
    /// @param amount The custom markdown amount
    function setCustomMarkdown(address borrower, uint256 amount) external {
        customMarkdowns[borrower] = amount;
    }

    /// @notice Alias for setCustomMarkdown for backward compatibility
    /// @param borrower The borrower address
    /// @param amount The custom markdown amount
    function setMarkdownForBorrower(address borrower, uint256 amount) external {
        customMarkdowns[borrower] = amount;
    }

    /// @notice Get the full markdown duration from protocol config or override
    /// @return The duration in seconds for 100% markdown
    function fullMarkdownDuration() public view returns (uint256) {
        if (overrideDuration > 0) {
            return overrideDuration;
        }
        return IProtocolConfig(protocolConfig).config(ProtocolConfigLib.FULL_MARKDOWN_DURATION);
    }

    /// @notice Set override duration for testing
    /// @param duration The override duration (0 to use protocol config)
    function setOverrideDuration(uint256 duration) external {
        overrideDuration = duration;
    }

    /// @inheritdoc IMarkdownController
    function calculateMarkdown(address borrower, uint256 borrowAmount, uint256 timeInDefault)
        external
        view
        returns (uint256 markdownAmount)
    {
        if (customMarkdowns[borrower] > 0) {
            return customMarkdowns[borrower] > borrowAmount ? borrowAmount : customMarkdowns[borrower];
        }

        if (!markdownEnabled[borrower]) {
            return 0;
        }

        uint256 duration = fullMarkdownDuration();

        if (duration == 0) {
            return 0;
        }

        if (timeInDefault >= duration) {
            return borrowAmount;
        }

        markdownAmount = (borrowAmount * timeInDefault) / duration;
    }

    /// @inheritdoc IMarkdownController
    function getMarkdownMultiplier(uint256 timeInDefault) external view returns (uint256 multiplier) {
        uint256 duration = fullMarkdownDuration();

        if (duration == 0 || timeInDefault == 0) {
            return WAD;
        }

        if (timeInDefault >= duration) {
            return 0;
        }

        uint256 markdownPercentage = (WAD * timeInDefault) / duration;
        multiplier = WAD - markdownPercentage;
    }

    /// @inheritdoc IMarkdownController
    function isFrozen(address borrower) external view returns (bool) {
        return markdownEnabled[borrower];
    }

    /// @inheritdoc IMarkdownController
    function slashJaneProportional(address, uint256) external pure returns (uint256) {
        // Mock does not actually slash tokens
        return 0;
    }

    /// @inheritdoc IMarkdownController
    function slashJaneFull(address) external pure returns (uint256) {
        // Mock does not actually slash tokens
        return 0;
    }

    /// @notice Set the daily markdown rate (for backward compatibility with old tests)
    /// @param _dailyMarkdownBps Daily markdown rate in basis points
    /// @dev Converts daily rate to full duration (70 days for 100% at 1% per day)
    function setDailyMarkdownRate(uint256 _dailyMarkdownBps) external {
        require(_dailyMarkdownBps <= 10000, "Rate exceeds 100%");
        if (_dailyMarkdownBps == 0) {
            overrideDuration = 0;
        } else {
            overrideDuration = (10000 * 86400) / _dailyMarkdownBps;
        }
    }
}
