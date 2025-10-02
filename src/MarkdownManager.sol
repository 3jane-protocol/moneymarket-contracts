// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {IMarkdownManager} from "./interfaces/IMarkdownManager.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "./libraries/ProtocolConfigLib.sol";
import {Ownable} from "../lib/openzeppelin/contracts/access/Ownable.sol";

/// @title MarkdownManager
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Manages linear markdown calculations for borrowers in default
/// @dev Markdowns are applied linearly based on time in default and a configurable duration
contract MarkdownManager is IMarkdownManager, Ownable {
    /// @notice WAD constant for percentage calculations (1e18 = 100%)
    uint256 internal constant WAD = 1e18;

    /// @notice The protocol config contract address
    address public immutable protocolConfig;

    /// @notice Mapping of borrowers with markdown enabled
    mapping(address => bool) public markdownEnabled;

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

    /// @notice Get the full markdown duration from protocol config
    /// @return The duration in seconds for 100% markdown
    function fullMarkdownDuration() public view returns (uint256) {
        return IProtocolConfig(protocolConfig).config(ProtocolConfigLib.FULL_MARKDOWN_DURATION);
    }

    /// @notice Enable or disable markdown for a borrower
    /// @param borrower The borrower address
    /// @param enabled Whether to enable markdown
    function setEnableMarkdown(address borrower, bool enabled) external onlyOwner {
        markdownEnabled[borrower] = enabled;
        emit MarkdownEnabledUpdated(borrower, enabled);
    }

    /// @notice Calculate the markdown amount for a borrower's position
    /// @param borrower The address of the borrower
    /// @param borrowAmount The current borrow amount in assets
    /// @param timeInDefault The duration in seconds since the borrower entered default
    /// @return . The amount to reduce from the face value
    function calculateMarkdown(address borrower, uint256 borrowAmount, uint256 timeInDefault)
        external
        view
        returns (uint256)
    {
        if (!markdownEnabled[borrower]) {
            return 0;
        }

        uint256 markdownDuration = fullMarkdownDuration();

        if (markdownDuration == 0) {
            return 0;
        }

        if (timeInDefault >= markdownDuration) {
            return borrowAmount;
        }

        return (borrowAmount * timeInDefault) / markdownDuration;
    }

    /// @notice Get the markdown multiplier for a given time in default
    /// @param timeInDefault The duration in seconds since the borrower entered default
    /// @return . The value multiplier (1e18 = 100% value, 0 = 0% value)
    function getMarkdownMultiplier(uint256 timeInDefault) external view returns (uint256) {
        uint256 markdownDuration = fullMarkdownDuration();

        if (markdownDuration == 0 || timeInDefault == 0) {
            return WAD;
        }

        if (timeInDefault >= markdownDuration) {
            return 0;
        }

        uint256 markdownPercentage = (WAD * timeInDefault) / markdownDuration;
        return WAD - markdownPercentage;
    }
}
