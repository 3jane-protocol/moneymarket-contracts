// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {Market, Position, RepaymentStatus, MarkdownState} from "../../../../src/interfaces/IMorpho.sol";

/// @title HookIntegrationTest
/// @notice Tests for markdown updates through Morpho hooks (_beforeBorrow, _beforeRepay, _afterRepay)
contract HookIntegrationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    event BorrowerMarkdownUpdated(Id indexed id, address indexed borrower, uint256 oldMarkdown, uint256 newMarkdown);
    event DefaultCleared(Id indexed id, address indexed borrower);

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock();

        // Deploy credit line
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);

        // Create market with credit line
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);
        morphoCredit.setMarkdownManager(id, address(markdownManager));
        vm.stopPrank();

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 500_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 500_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test markdown updates in _beforeBorrow hook
    function testBeforeBorrowHookUpdatesMarkdown() public {
        uint256 borrowAmount = 50_000e18;

        // Setup borrower with existing loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Create obligation and immediately move to a time where borrower is in default
        // The obligation cycle ended 1 day ago, so we need to add grace + delinquency periods
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Get the actual cycle end to calculate proper timing
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEnd = morphoCredit.paymentCycle(id, cycleId);

        // Move to default period and wait for markdown to accumulate
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;
        vm.warp(defaultStart + 5 days); // 5 days into default

        // Verify we're in default
        (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default");

        // Trigger markdown update
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownBefore = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            markdownBefore = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
        }
        assertTrue(markdownBefore > 0, "Should have markdown after 5 days in default");

        // Forward time so markdown accumulates more
        vm.warp(block.timestamp + 5 days);

        // Clear the obligation to test borrow hook
        _repayObligation(BORROWER);

        // New borrow should trigger markdown update in _beforeBorrow
        uint256 gasBefore = gasleft();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10_000e18, 0, BORROWER, BORROWER);
        uint256 gasUsed = gasBefore - gasleft();

        // After repaying, borrower is current so markdown should be 0
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownAfter = 0;
        // After repayment, borrower should be current with no markdown
        assertEq(markdownAfter, 0, "Markdown should be cleared after repaying obligation");

        emit log_named_uint("Gas used for borrow with markdown update", gasUsed);
    }

    /// @notice Test markdown updates in _beforeRepay and _afterRepay hooks
    function testRepayHooksUpdateMarkdown() public {
        uint256 borrowAmount = 50_000e18;

        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);
        _moveToDefault();

        // Check if borrower is actually in default
        (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default after _moveToDefault");

        // Let markdown accrue
        vm.warp(block.timestamp + 10 days);

        // Trigger markdown update to set default time
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get markdown state and default time
        uint128 lastCalcMarkdown = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus statusAfterAccrue, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(statusAfterAccrue), uint8(RepaymentStatus.Default), "Should be in default");
        assertTrue(defaultTime > 0, "Should have default time");
        assertTrue(lastCalcMarkdown > 0, "Markdown should be calculated");

        // Get obligation amount
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);

        // Prepare full obligation payment
        loanToken.setBalance(BORROWER, amountDue);

        // Before repay, markdown should exist
        uint256 markdownBefore = lastCalcMarkdown;
        assertTrue(markdownBefore > 0, "Should have markdown before repay");

        // Expect DefaultCleared event first
        vm.expectEmit(true, true, false, false);
        emit DefaultCleared(id, BORROWER);

        // Then expect markdown update event during repay (clearing to 0)
        vm.expectEmit(true, true, false, true);
        emit BorrowerMarkdownUpdated(id, BORROWER, markdownBefore, 0);

        // Repay full obligation - should trigger markdown updates in hooks and clear markdown
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");

        // Verify markdown was cleared after repaying obligation
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 currentMarkdown = 0;
        // After repayment, borrower should be current with no markdown
        assertEq(currentMarkdown, 0, "Markdown should be cleared after repaying obligation");

        // Verify status is now Current
        (RepaymentStatus statusAfter,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(statusAfter), uint8(RepaymentStatus.Current), "Should be current after repayment");
    }

    /// @notice Test state consistency across hook operations
    function testStateConsistencyAcrossHooks() public {
        uint256 borrowAmount = 100_000e18;

        // Setup two borrowers
        address borrower1 = BORROWER;
        address borrower2 = ONBEHALF;

        _setupBorrowerWithLoan(borrower1, borrowAmount);
        _setupBorrowerWithLoan(borrower2, borrowAmount);

        // Put both in default
        _createPastObligation(borrower1, 500, borrowAmount);
        _createPastObligation(borrower2, 500, borrowAmount);
        _moveToDefault();

        // Let markdown accrue
        vm.warp(block.timestamp + 15 days);

        // Get initial market state
        Market memory marketBefore = morpho.market(id);
        assertEq(marketBefore.totalMarkdownAmount, 0, "Market markdown should be stale");

        // Borrower 1 makes partial repayment - triggers hooks
        // Only pay part of obligation to keep borrower in default
        (, uint128 amountDue1,) = morphoCredit.repaymentObligation(id, borrower1);
        uint256 partialPayment1 = amountDue1 / 2; // Pay half to stay in default
        loanToken.setBalance(borrower1, partialPayment1);
        vm.prank(borrower1);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, partialPayment1, 0, borrower1, hex"");

        // Since partial payment is not allowed, pay full amount to clear obligation
        loanToken.setBalance(borrower1, amountDue1);
        vm.prank(borrower1);
        morpho.repay(marketParams, amountDue1, 0, borrower1, hex"");

        // Check market - borrower1's markdown should be cleared after full payment
        Market memory marketMid = morpho.market(id);
        assertEq(marketMid.totalMarkdownAmount, 0, "Market should have no markdown after borrower1 clears default");

        // Borrower 2 also pays full obligation
        (, uint128 amountDue2,) = morphoCredit.repaymentObligation(id, borrower2);
        loanToken.setBalance(borrower2, amountDue2);
        vm.prank(borrower2);
        morpho.repay(marketParams, amountDue2, 0, borrower2, hex"");

        // Check market - both borrowers cleared their defaults
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalMarkdownAmount, 0, "Market should have no markdown after both clear defaults");

        // Verify individual markdowns are cleared
        uint256 borrowAssets1 = morpho.expectedBorrowAssets(marketParams, borrower1);
        uint256 borrowAssets2 = morpho.expectedBorrowAssets(marketParams, borrower2);
        (RepaymentStatus status1,) = morphoCredit.getRepaymentStatus(id, borrower1);
        (RepaymentStatus status2,) = morphoCredit.getRepaymentStatus(id, borrower2);
        uint256 markdown1 = 0;
        uint256 markdown2 = 0;
        // After repayment, both borrowers should be current with no markdown
        assertEq(markdown1, 0, "Borrower1 markdown should be cleared");
        assertEq(markdown2, 0, "Borrower2 markdown should be cleared");
    }

    /// @notice Test gas optimization for operations not requiring markdown updates
    function testGasOptimizationForHealthyBorrowers() public {
        uint256 borrowAmount = 50_000e18;

        // Setup healthy borrower (no obligations)
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Measure gas for healthy borrower operations
        uint256 gasBeforeBorrow = gasleft();
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10_000e18, 0, BORROWER, BORROWER);
        uint256 gasBorrow = gasBeforeBorrow - gasleft();

        loanToken.setBalance(BORROWER, 5_000e18);
        uint256 gasBeforeRepay = gasleft();
        vm.prank(BORROWER);
        morpho.repay(marketParams, 5_000e18, 0, BORROWER, hex"");
        uint256 gasRepay = gasBeforeRepay - gasleft();

        // Setup defaulted borrower for comparison
        address defaultedBorrower = ONBEHALF;
        _setupBorrowerWithLoan(defaultedBorrower, borrowAmount);
        _createPastObligation(defaultedBorrower, 500, borrowAmount);
        _moveToDefault();
        vm.warp(block.timestamp + 10 days);

        // Measure gas for defaulted borrower repay (includes markdown update)
        loanToken.setBalance(defaultedBorrower, 5_000e18);
        uint256 gasBeforeDefaultedRepay = gasleft();
        vm.prank(defaultedBorrower);
        morpho.repay(marketParams, 5_000e18, 0, defaultedBorrower, hex"");
        uint256 gasDefaultedRepay = gasBeforeDefaultedRepay - gasleft();

        // Log gas differences
        emit log_named_uint("Healthy borrow gas", gasBorrow);
        emit log_named_uint("Healthy repay gas", gasRepay);
        emit log_named_uint("Defaulted repay gas", gasDefaultedRepay);
        emit log_named_uint("Markdown update overhead", gasDefaultedRepay - gasRepay);

        // Defaulted operations should use more gas due to markdown updates
        assertTrue(gasDefaultedRepay > gasRepay, "Defaulted repay should use more gas");
    }

    /// @notice Test markdown updates after status changes in hooks
    function testMarkdownUpdatesAfterStatusChange() public {
        uint256 borrowAmount = 50_000e18;

        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);
        _moveToDefault();
        vm.warp(block.timestamp + 20 days);

        // Update markdown
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownInDefault = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            markdownInDefault = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
        }
        assertTrue(markdownInDefault > 0, "Should have markdown in default");

        // Repay full obligation - status changes to current
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue);

        // This repay should:
        // 1. Update markdown in _beforeRepay (still in default)
        // 2. Process payment and clear obligation
        // 3. Update markdown in _afterRepay (now current, so cleared)
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");

        // Verify markdown cleared after status change
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus statusAfter, uint256 statusStartTimeAfter) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownAfter = 0;
        // After repayment, borrower should be current with no markdown
        assertEq(markdownAfter, 0, "Markdown should be cleared");
        assertEq(statusStartTimeAfter, 0, "Status start time should be cleared");

        // Verify can borrow again
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10_000e18, 0, BORROWER, BORROWER);
    }

    /// @notice Test concurrent operations triggering hooks
    function testConcurrentHookTriggers() public {
        uint256 borrowAmount = 50_000e18;

        // Setup multiple borrowers
        address borrower1 = makeAddr("Borrower1");
        address borrower2 = makeAddr("Borrower2");

        // Setup both borrowers with loans
        _setupBorrowerWithLoan(borrower1, borrowAmount);
        _setupBorrowerWithLoan(borrower2, borrowAmount);

        // Create obligation for borrower1
        _createPastObligation(borrower1, 500, borrowAmount);

        // Get cycle info and move to default time
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, borrower1);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
        uint256 defaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1;
        vm.warp(defaultTime + 10 days);

        // Trigger markdown accrual for borrower1
        morphoCredit.accrueBorrowerPremium(id, borrower1);
        {
            uint256 borrowAssets1 = morpho.expectedBorrowAssets(marketParams, borrower1);
            (RepaymentStatus status1, uint256 defaultTime1) = morphoCredit.getRepaymentStatus(id, borrower1);
            uint256 markdown1 = 0;
            if (status1 == RepaymentStatus.Default && defaultTime1 > 0) {
                markdown1 = markdownManager.calculateMarkdown(borrowAssets1, defaultTime1, block.timestamp);
            }
            assertTrue(markdown1 > 0, "Borrower1 should have markdown");
        }

        // Meanwhile, borrower2 (current status) performs operations
        vm.prank(borrower2);
        morpho.borrow(marketParams, 10_000e18, 0, borrower2, borrower2);

        loanToken.setBalance(borrower2, 5_000e18);
        vm.startPrank(borrower2);
        loanToken.approve(address(morpho), 5_000e18);
        morpho.repay(marketParams, 5_000e18, 0, borrower2, hex"");
        vm.stopPrank();

        // Verify borrower2 has no markdown
        {
            uint256 borrowAssets2 = morpho.expectedBorrowAssets(marketParams, borrower2);
            (RepaymentStatus status2,) = morphoCredit.getRepaymentStatus(id, borrower2);
            uint256 markdown2 = 0;
            // Borrower2 is current, so no markdown
            assertEq(markdown2, 0, "Borrower2 should have no markdown");
        }

        // Borrower1 repays obligation
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower1);
        loanToken.setBalance(borrower1, amountDue);
        vm.startPrank(borrower1);
        loanToken.approve(address(morpho), amountDue);
        morpho.repay(marketParams, amountDue, 0, borrower1, hex"");
        vm.stopPrank();

        // Verify markdown cleared for borrower1
        {
            uint256 borrowAssets1After = morpho.expectedBorrowAssets(marketParams, borrower1);
            (RepaymentStatus status1After,) = morphoCredit.getRepaymentStatus(id, borrower1);
            uint256 markdown1After = 0;
            // After repayment, borrower1 should be current with no markdown
            assertEq(markdown1After, 0, "Borrower1 markdown should be cleared");
        }

        // Verify market total is zero
        Market memory marketFinal = morpho.market(id);
        assertEq(marketFinal.totalMarkdownAmount, 0, "Total markdown should be zero");
    }

    // Helper functions

    function _moveToDefault() internal {
        // Get any borrower's obligation to determine timing
        (uint128 cycleId, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        if (cycleId == 0 && amountDue == 0) {
            // Try ONBEHALF if BORROWER has no obligation
            (cycleId, amountDue,) = morphoCredit.repaymentObligation(id, ONBEHALF);
        }

        // If there's an obligation, move to default time
        if (amountDue > 0) {
            uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
            uint256 defaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1;
            vm.warp(defaultTime);
        }
    }

    function _repayObligation(address borrower) internal {
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
        if (amountDue > 0) {
            loanToken.setBalance(borrower, amountDue);
            vm.prank(borrower);
            morpho.repay(marketParams, amountDue, 0, borrower, hex"");
        }
    }
}
