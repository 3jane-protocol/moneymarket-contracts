// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title RebateRepaymentLib
/// @notice Helpers for turning report-only rebate amounts into Safe repayment actions.
library RebateRepaymentLib {
    enum RepaymentAction {
        SkippedZeroDebt,
        PartialRepay,
        FullRepay
    }

    struct MergedRebate {
        address borrower;
        uint256 aaveRebateUsdc;
        uint256 delayedRebateUsdc;
    }

    struct RepaymentSelection {
        RepaymentAction action;
        uint256 helperAssetsArgument;
        uint256 expectedAppliedUsdc;
        uint256 auditRemainderUsdc;
    }

    function addAaveRebate(MergedRebate[] memory rebates, uint256 length, address borrower, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return _addRebate(rebates, length, borrower, amount, false);
    }

    function addDelayedRebate(MergedRebate[] memory rebates, uint256 length, address borrower, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return _addRebate(rebates, length, borrower, amount, true);
    }

    function totalRebate(MergedRebate memory rebate) internal pure returns (uint256) {
        return rebate.aaveRebateUsdc + rebate.delayedRebateUsdc;
    }

    function indexOf(MergedRebate[] memory rebates, uint256 length, address borrower) internal pure returns (uint256) {
        for (uint256 i = 0; i < length; i++) {
            if (rebates[i].borrower == borrower) return i;
        }
        return type(uint256).max;
    }

    function selectRepayment(uint256 rebateUsdc, uint256 fullPayoffUsdc)
        internal
        pure
        returns (RepaymentSelection memory selection)
    {
        if (fullPayoffUsdc == 0) {
            selection.action = RepaymentAction.SkippedZeroDebt;
            selection.auditRemainderUsdc = rebateUsdc;
            return selection;
        }

        if (rebateUsdc >= fullPayoffUsdc) {
            selection.action = RepaymentAction.FullRepay;
            selection.helperAssetsArgument = type(uint256).max;
            selection.expectedAppliedUsdc = fullPayoffUsdc;
            selection.auditRemainderUsdc = rebateUsdc - fullPayoffUsdc;
            return selection;
        }

        selection.action = RepaymentAction.PartialRepay;
        selection.helperAssetsArgument = rebateUsdc;
        selection.expectedAppliedUsdc = rebateUsdc;
    }

    function _addRebate(MergedRebate[] memory rebates, uint256 length, address borrower, uint256 amount, bool delayed)
        private
        pure
        returns (uint256)
    {
        if (amount == 0) return length;

        uint256 index = indexOf(rebates, length, borrower);
        if (index == type(uint256).max) {
            index = length;
            rebates[index].borrower = borrower;
            length++;
        }

        if (delayed) {
            rebates[index].delayedRebateUsdc += amount;
        } else {
            rebates[index].aaveRebateUsdc += amount;
        }

        return length;
    }
}
