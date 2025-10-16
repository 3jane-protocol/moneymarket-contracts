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
    function _beforeWithdraw(MarketParams memory, Id id, address onBehalf, uint256, uint256) internal virtual override {
        // Do nothing - remove usd3 restriction for testing
    }

    /// @dev Override _beforeBorrow to remove helper/paused restrictions but keep freeze check
    function _beforeBorrow(MarketParams memory, Id id, address onBehalf, uint256, uint256) internal virtual override {
        // Remove helper and paused restrictions for testing
        // Keep the market freeze check, repayment status check and premium accrual
        if (_isMarketFrozen(id)) revert ErrorsLib.MarketFrozen();

        (RepaymentStatus status,) = getRepaymentStatus(id, onBehalf);
        if (status != RepaymentStatus.Current) revert ErrorsLib.OutstandingRepayment();
        _accrueBorrowerPremium(id, onBehalf);
        // No need to update markdown - borrower must be Current to borrow, so markdown is always 0
    }

    /// @dev Override _beforeRepay to remove minBorrow restriction but keep other logic
    function _beforeRepay(MarketParams memory, Id id, address onBehalf, uint256 assets, uint256)
        internal
        virtual
        override
    {
        // Remove minBorrow restriction for testing
        // Keep all other logic from parent implementation

        // Check if market is frozen (must come first, before any state changes)
        if (_isMarketFrozen(id)) revert ErrorsLib.MarketFrozen();

        // Accrue premium (including penalty if past grace period)
        _accrueBorrowerPremium(id, onBehalf);
        _updateBorrowerMarkdown(id, onBehalf);

        // Skip minBorrow check for testing
        // Parent implementation would check here, but we omit it for testing flexibility

        // Track payment against obligation
        _trackObligationPayment(id, onBehalf, assets);
    }
}
