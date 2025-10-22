// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {IMarkdownController} from "./interfaces/IMarkdownController.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "./libraries/ProtocolConfigLib.sol";
import {Ownable} from "../lib/openzeppelin/contracts/access/Ownable.sol";
import {Jane} from "./jane/Jane.sol";
import {IMorphoCredit} from "./interfaces/IMorpho.sol";
import {MorphoCreditLib} from "./libraries/periphery/MorphoCreditLib.sol";
import {Id, RepaymentStatus} from "./interfaces/IMorpho.sol";

/// @title MarkdownController
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Controls markdown calculations and JANE token redistribution for borrowers in default
/// @dev Markdowns are applied linearly based on time in default and a configurable duration
contract MarkdownController is IMarkdownController, Ownable {
    /// @notice WAD constant for percentage calculations (1e18 = 100%)
    uint256 internal constant WAD = 1e18;

    /// @notice The protocol config contract address
    address public immutable protocolConfig;

    /// @notice The JANE token contract
    Jane public immutable jane;

    /// @notice The MorphoCredit contract address
    address public immutable morphoCredit;

    /// @notice The market ID to check repayment status
    Id public immutable marketId;

    /// @notice Mapping of borrowers with markdown enabled
    mapping(address => bool) public markdownEnabled;

    /// @notice Tracks cumulative JANE slashed per borrower
    mapping(address => uint256) public janeSlashed;

    /// @notice Tracks initial JANE balance when markdown started
    mapping(address => uint256) public initialJaneBalance;

    /// @notice Emitted when markdown is enabled or disabled for a borrower
    /// @param borrower The borrower address
    /// @param enabled Whether markdown is enabled
    event MarkdownEnabledUpdated(address indexed borrower, bool enabled);

    /// @notice Constructor
    /// @param _protocolConfig The protocol config contract address
    /// @param _owner The owner address
    /// @param _jane The JANE token address
    /// @param _morphoCredit The MorphoCredit contract address
    /// @param _marketId The market ID to check repayment status
    constructor(address _protocolConfig, address _owner, address _jane, address _morphoCredit, Id _marketId)
        Ownable(_owner)
    {
        require(_protocolConfig != address(0), "Invalid protocol config");
        require(_jane != address(0), "Invalid jane");
        require(_morphoCredit != address(0), "Invalid morphoCredit");
        protocolConfig = _protocolConfig;
        jane = Jane(_jane);
        morphoCredit = _morphoCredit;
        marketId = _marketId;
    }

    /// @notice Only MorphoCredit can call slash functions
    modifier onlyMorphoCredit() {
        require(msg.sender == morphoCredit, "Only MorphoCredit");
        _;
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
    function getMarkdownMultiplier(uint256 timeInDefault) public view returns (uint256) {
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

    /// @notice Check if a borrower's JANE transfers are frozen
    /// @param borrower The borrower address
    /// @return True if the borrower is frozen (markdown enabled AND delinquent/default)
    function isFrozen(address borrower) external view returns (bool) {
        if (!markdownEnabled[borrower]) return false;

        // Check if borrower is actually delinquent or in default
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(morphoCredit), marketId, borrower);
        return status == RepaymentStatus.Delinquent || status == RepaymentStatus.Default;
    }

    /// @notice Redistributes JANE proportionally to markdown progression
    /// @param borrower The borrower address
    /// @param timeInDefault Time the borrower has been in default
    /// @return slashed Amount of JANE redistributed
    function slashJaneProportional(address borrower, uint256 timeInDefault)
        external
        onlyMorphoCredit
        returns (uint256 slashed)
    {
        if (!markdownEnabled[borrower] || timeInDefault == 0) return 0;

        uint256 initialBalance = initialJaneBalance[borrower];

        // Initialize tracking on first slash
        if (initialBalance == 0) {
            initialBalance = jane.balanceOf(borrower);
            if (initialBalance == 0) return 0;
            initialJaneBalance[borrower] = initialBalance;
        }

        // Calculate target slash based on initial balance
        uint256 multiplier = getMarkdownMultiplier(timeInDefault);
        uint256 targetSlashed = initialBalance * (WAD - multiplier) / WAD;

        // Slash delta since last touch
        uint256 alreadySlashed = janeSlashed[borrower];
        if (targetSlashed <= alreadySlashed) {
            return 0;
        }

        slashed = targetSlashed - alreadySlashed;

        // Cap at current balance
        uint256 currentBalance = jane.balanceOf(borrower);
        if (slashed > currentBalance) slashed = currentBalance;

        if (slashed > 0) {
            janeSlashed[borrower] += slashed;
            jane.redistributeFromBorrower(borrower, slashed);
        }
    }

    /// @notice Redistributes all remaining JANE on settlement
    /// @param borrower The borrower address
    /// @return slashed Amount of JANE redistributed
    function slashJaneFull(address borrower) external onlyMorphoCredit returns (uint256 slashed) {
        if (!markdownEnabled[borrower]) return 0;

        slashed = jane.balanceOf(borrower);
        if (slashed > 0) {
            jane.redistributeFromBorrower(borrower, slashed);
        }

        // Reset tracking on settlement
        janeSlashed[borrower] = 0;
        initialJaneBalance[borrower] = 0;
    }

    /// @notice Reset burn tracking state for a borrower
    /// @param borrower The borrower address
    function resetBorrowerState(address borrower) external onlyMorphoCredit {
        janeSlashed[borrower] = 0;
        initialJaneBalance[borrower] = 0;
    }
}
