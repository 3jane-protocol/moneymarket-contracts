// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IInsuranceFund} from "../interfaces/IInsuranceFund.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

/// @title InsuranceFundMock
/// @notice Mock implementation of the insurance fund for testing
contract InsuranceFundMock is IInsuranceFund {
    using SafeTransferLib for IERC20;

    address public override CREDIT_LINE;

    constructor() {
        // Default to empty, will be set by test
    }

    function setCreditLine(address creditLine) external {
        CREDIT_LINE = creditLine;
    }

    /// @notice Transfers loanToken to the CreditLine contract
    /// @param loanToken Address of the loan token to transfer
    /// @param amount Amount of loanToken to transfer
    function bring(address loanToken, uint256 amount) external override {
        require(msg.sender == CREDIT_LINE, "Only CreditLine can call");
        IERC20(loanToken).safeTransfer(CREDIT_LINE, amount);
    }
}
