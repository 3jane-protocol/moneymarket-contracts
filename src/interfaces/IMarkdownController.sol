// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id} from "./IMorpho.sol";

/// @title IMarkdownController
/// @notice Interface for controlling debt markdowns and JANE token penalties for borrowers in default
interface IMarkdownController {
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

    /// @notice Check if a borrower's JANE transfers are frozen
    /// @param borrower The borrower address
    /// @return True if the borrower is frozen
    function isFrozen(address borrower) external view returns (bool);

    /// @notice Burns JANE proportionally to markdown progression
    /// @param borrower The borrower address
    /// @param timeInDefault Time the borrower has been in default
    /// @return burned Amount of JANE burned
    function burnJaneProportional(address borrower, uint256 timeInDefault) external returns (uint256 burned);

    /// @notice Burns all remaining JANE on settlement
    /// @param borrower The borrower address
    /// @return burned Amount of JANE burned
    function burnJaneFull(address borrower) external returns (uint256 burned);

    /// @notice Reset burn tracking state for a borrower
    /// @param borrower The borrower address
    function resetBorrowerState(address borrower) external;
}
