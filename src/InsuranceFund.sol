// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {IInsuranceFund} from "./interfaces/IInsuranceFund.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title InsuranceFund
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice This contract manages insurance fund operations for the Morpho protocol
/// @dev Handles insurance fund transfers to the CreditLine contract
contract InsuranceFund is IInsuranceFund {
    using SafeTransferLib for IERC20;

    /// @notice Address of the CreditLine contract
    address public immutable CREDIT_LINE;

    /// @notice Initializes the InsuranceFund contract with the CreditLine address
    /// @param creditLine Address of the CreditLine contract
    /// @dev Validates that the CreditLine address is not zero
    constructor(address creditLine) {
        if (creditLine == address(0)) revert ErrorsLib.ZeroAddress();
        CREDIT_LINE = creditLine;
    }

    /// @notice Transfers loanToken to the CreditLine contract
    /// @param loanToken Address of the loan token to transfer
    /// @param amount Amount of loanToken to transfer
    /// @dev Only callable by the CreditLine contract
    /// @dev Transfers the specified amount of loanToken to the CreditLine contract
    function bring(address loanToken, uint256 amount) external {
        if (msg.sender != CREDIT_LINE) revert ErrorsLib.Unauthorized();

        IERC20(loanToken).safeTransfer(CREDIT_LINE, amount);
    }
}
