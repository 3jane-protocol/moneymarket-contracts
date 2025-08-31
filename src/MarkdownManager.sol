// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {IMarkdownManager} from "./interfaces/IMarkdownManager.sol";

/// @title MarkdownManager
/// @author 3Jane
/// @custom:contact support@3jane.xyz
contract MarkdownManager is IMarkdownManager {
    /// @notice Calculate the markdown amount for a borrower's position
    /// @param borrower The address of the borrower
    /// @param borrowAmount The current borrow amount in assets
    /// @param timeInDefault The duration in seconds since the borrower entered default
    /// @return markdownAmount The amount to reduce from the face value
    function calculateMarkdown(address borrower, uint256 borrowAmount, uint256 timeInDefault)
        external
        pure
        returns (uint256 markdownAmount)
    {
        return 0;
    }

    /// @notice Get the markdown multiplier for a given time in default
    /// @param timeInDefault The duration in seconds since the borrower entered default
    /// @return multiplier The value multiplier (1e18 = 100% value, 0 = 0% value)
    function getMarkdownMultiplier(uint256 timeInDefault) external pure returns (uint256 multiplier) {
        return 0;
    }
}
