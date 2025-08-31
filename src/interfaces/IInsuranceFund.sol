// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IInsuranceFund
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Interface for the InsuranceFund contract
/// @dev Defines the interface for insurance fund operations
interface IInsuranceFund {
    /// @notice Address of the CreditLine contract
    function CREDIT_LINE() external view returns (address);

    /// @notice Transfers loanToken to the CreditLine contract
    /// @param loanToken Address of the loan token to transfer
    /// @param amount Amount of loanToken to transfer
    /// @dev Only callable by the CreditLine contract
    /// @dev Transfers the specified amount of loanToken to the CreditLine contract
    function bring(address loanToken, uint256 amount) external;
}
