// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {RebateRepaymentLib} from "../../../src/libraries/RebateRepaymentLib.sol";

contract RebateRepaymentLibTest is Test {
    using RebateRepaymentLib for RebateRepaymentLib.MergedRebate;

    function test_addRebate_mergesAaveAndDelayedAmounts() public pure {
        RebateRepaymentLib.MergedRebate[] memory rebates = new RebateRepaymentLib.MergedRebate[](4);
        address borrower = address(0xB0B);

        uint256 length = RebateRepaymentLib.addAaveRebate(rebates, 0, borrower, 100e6);
        length = RebateRepaymentLib.addDelayedRebate(rebates, length, borrower, 25e6);

        assertEq(length, 1);
        assertEq(rebates[0].borrower, borrower);
        assertEq(rebates[0].aaveRebateUsdc, 100e6);
        assertEq(rebates[0].delayedRebateUsdc, 25e6);
        assertEq(rebates[0].totalRebate(), 125e6);
    }

    function test_addRebate_skipsZeroAmounts() public pure {
        RebateRepaymentLib.MergedRebate[] memory rebates = new RebateRepaymentLib.MergedRebate[](1);

        uint256 length = RebateRepaymentLib.addAaveRebate(rebates, 0, address(0xB0B), 0);

        assertEq(length, 0);
    }

    function test_selectRepayment_skipsZeroDebtAndAuditsRemainder() public pure {
        RebateRepaymentLib.RepaymentSelection memory selection = RebateRepaymentLib.selectRepayment(100e6, 0);

        assertEq(uint256(selection.action), uint256(RebateRepaymentLib.RepaymentAction.SkippedZeroDebt));
        assertEq(selection.helperAssetsArgument, 0);
        assertEq(selection.expectedAppliedUsdc, 0);
        assertEq(selection.auditRemainderUsdc, 100e6);
    }

    function test_selectRepayment_partialWhenRebateBelowDebt() public pure {
        RebateRepaymentLib.RepaymentSelection memory selection = RebateRepaymentLib.selectRepayment(100e6, 250e6);

        assertEq(uint256(selection.action), uint256(RebateRepaymentLib.RepaymentAction.PartialRepay));
        assertEq(selection.helperAssetsArgument, 100e6);
        assertEq(selection.expectedAppliedUsdc, 100e6);
        assertEq(selection.auditRemainderUsdc, 0);
    }

    function test_selectRepayment_fullWhenRebateEqualsDebt() public pure {
        RebateRepaymentLib.RepaymentSelection memory selection = RebateRepaymentLib.selectRepayment(100e6, 100e6);

        assertEq(uint256(selection.action), uint256(RebateRepaymentLib.RepaymentAction.FullRepay));
        assertEq(selection.helperAssetsArgument, type(uint256).max);
        assertEq(selection.expectedAppliedUsdc, 100e6);
        assertEq(selection.auditRemainderUsdc, 0);
    }

    function test_selectRepayment_fullWhenRebateExceedsDebtAndAuditsRemainder() public pure {
        RebateRepaymentLib.RepaymentSelection memory selection = RebateRepaymentLib.selectRepayment(125e6, 100e6);

        assertEq(uint256(selection.action), uint256(RebateRepaymentLib.RepaymentAction.FullRepay));
        assertEq(selection.helperAssetsArgument, type(uint256).max);
        assertEq(selection.expectedAppliedUsdc, 100e6);
        assertEq(selection.auditRemainderUsdc, 25e6);
    }
}
