// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id} from "./IMorpho.sol";

/// @title IMarkdownManager
/// @notice Interface for calculating debt markdowns based on default status and time
interface IMarkdownManager {
    /// @notice Calculate the markdown amount for a borrower's position
    /// @param borrower The address of the borrower
    /// @param borrowAmount The current borrow amount in assets
    /// @param timeInDefault The duration in seconds since the borrower entered default
    /// @return markdownAmount The amount to reduce from the face value
    function calculateMarkdown(address borrower, uint256 borrowAmount, uint256 timeInDefault)
        external
        view
        returns (uint256 markdownAmount);

    /// @notice Get the markdown multiplier for a given time in default
    /// @param timeInDefault The duration in seconds since the borrower entered default
    /// @return multiplier The value multiplier (1e18 = 100% value, 0 = 0% value)
    function getMarkdownMultiplier(uint256 timeInDefault) external view returns (uint256 multiplier);

    /// @notice Check if a market is valid for markdown calculations
    /// @param market The market ID to check
    /// @return isValid True if the market is valid for markdown calculations
    function isValidForMarket(Id market) external view returns (bool isValid);
}
