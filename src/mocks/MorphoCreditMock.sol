// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import "../MorphoCredit.sol";

/// @title MorphoCreditMock
/// @notice Mock implementation of MorphoCredit for testing purposes
/// @dev Overrides certain functions to remove restrictions that would interfere with testing
contract MorphoCreditMock is MorphoCredit {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _protocolConfig) MorphoCredit(_protocolConfig) {}

    /// @dev Override _beforeSupply to do nothing (remove usd3 restriction)
    function _beforeSupply(MarketParams memory, Id id, address onBehalf, uint256, uint256, bytes calldata)
        internal
        virtual
        override
    {
        // Do nothing - remove usd3 restriction for testing
    }

    /// @dev Override _beforeWithdraw to do nothing (remove usd3 restriction)
    function _beforeWithdraw(MarketParams memory, Id id, address onBehalf, uint256, uint256)
        internal
        virtual
        override
    {
        // Do nothing - remove usd3 restriction for testing
    }

    /// @dev Override _beforeBorrow to remove helper/paused restrictions
    function _beforeBorrow(MarketParams memory, Id id, address onBehalf, uint256, uint256) internal virtual override {
        // Remove helper and paused restrictions for testing
        // Keep the repayment status check and premium accrual
        (RepaymentStatus status,) = getRepaymentStatus(id, onBehalf);
        if (status != RepaymentStatus.Current) revert ErrorsLib.OutstandingRepayment();
        _accrueBorrowerPremium(id, onBehalf);
        // No need to update markdown - borrower must be Current to borrow, so markdown is always 0
    }
}
