// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {Market, MarkdownState, RepaymentStatus, PaymentCycle} from "../../../../src/interfaces/IMorpho.sol";

/// @title MarkdownStateTest
/// @notice Tests for markdown state management including default timestamp tracking and state transitions
contract MarkdownStateTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    event DefaultStarted(Id indexed id, address indexed borrower, uint256 timestamp);
    event DefaultCleared(Id indexed id, address indexed borrower);
    event BorrowerMarkdownUpdated(Id indexed id, address indexed borrower, uint256 oldMarkdown, uint256 newMarkdown);

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
        creditLine.setMm(address(markdownManager));
        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test that default timestamp is set when borrower enters default status
    function testDefaultStartTimeTracking() public {
        // Setup borrower with credit line
        _setupBorrowerWithLoan(BORROWER, 10_000e18);

        // Create past obligation to trigger default
        _createPastObligation(BORROWER, 500, 10_000e18); // 5% repayment

        // Get cycle info to calculate correct timing
        (uint128 paymentCycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, paymentCycleId);
        uint256 expectedDefaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        // Verify not in default initially
        (RepaymentStatus status, uint256 statusStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertTrue(status != RepaymentStatus.Default, "Should not be in default initially");
        // Note: statusStartTime may not be 0 if borrower is in grace/delinquent status

        // Move directly to default period (add 1 day for markdown to accrue)
        _continueMarketCycles(id, expectedDefaultTime + 1 days);

        // Expect DefaultStarted event
        vm.expectEmit(true, true, false, true);
        emit DefaultStarted(id, BORROWER, expectedDefaultTime);

        // Trigger update - should set default timestamp
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify default timestamp was set correctly
        (, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(defaultStartTime, expectedDefaultTime, "Should set default time when entering default");

        // Verify markdown is being calculated
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        uint256 timeInDefault = block.timestamp > expectedDefaultTime ? block.timestamp - expectedDefaultTime : 0;
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        assertTrue(markdown > 0, "Should have markdown in default");
    }

    /// @notice Test that default timestamp is cleared when returning to current status
    function testDefaultTimestampClearedOnRecovery() public {
        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Fast forward to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify in default with timestamp set
        uint128 lastCalculatedMarkdown = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus statusBefore, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(statusBefore), uint8(RepaymentStatus.Default), "Should be in default");
        assertTrue(defaultStartTime > 0, "Should have default timestamp");
        assertTrue(lastCalculatedMarkdown > 0, "Should have markdown calculated");

        // Get obligation details
        (uint128 cycleId, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);

        // Repay the full obligation
        loanToken.setBalance(BORROWER, amountDue);

        // Expect DefaultCleared event during repay
        vm.expectEmit(true, true, false, false);
        emit DefaultCleared(id, BORROWER);

        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");

        // Check status should be current after repayment
        (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Current), "Should be current after repayment");

        // Trigger update to ensure markdown state is fully cleared
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify default timestamp and markdown cleared
        lastCalculatedMarkdown = morphoCredit.markdownState(id, BORROWER);
        (, uint256 statusStartTimeAfter) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(statusStartTimeAfter, 0, "Status start time should be cleared");
        assertEq(lastCalculatedMarkdown, 0, "Markdown should be cleared");
    }

    /// @notice Test that markdown only updates when borrower is touched (lazy evaluation)
    function testLazyMarkdownEvaluation() public {
        // Setup two borrowers in default
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _setupBorrowerWithLoan(ONBEHALF, 10_000e18);

        _createPastObligation(BORROWER, 500, 10_000e18);
        _createPastObligation(ONBEHALF, 500, 10_000e18);

        // Fast forward to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Touch only BORROWER
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Check BORROWER has markdown
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus borrowerStatus, uint256 borrowerDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 borrowerMarkdown = 0;
        if (borrowerStatus == RepaymentStatus.Default && borrowerDefaultTime > 0) {
            uint256 timeInDefault = block.timestamp > borrowerDefaultTime ? block.timestamp - borrowerDefaultTime : 0;
            borrowerMarkdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(borrowerMarkdown > 0, "BORROWER should have markdown");

        // Check ONBEHALF has no markdown (not touched)
        uint128 onbehalfLastMarkdown = morphoCredit.markdownState(id, ONBEHALF);
        assertEq(onbehalfLastMarkdown, 0, "ONBEHALF should not have markdown (not touched)");

        // Forward time significantly
        _continueMarketCycles(id, block.timestamp + 10 days);

        // BORROWER's markdown should still be stale (not updated)
        uint128 borrowerLastMarkdown = morphoCredit.markdownState(id, BORROWER);
        assertEq(borrowerLastMarkdown, borrowerMarkdown, "BORROWER markdown should be stale");

        // Touch BORROWER again - should update
        uint256 oldMarkdown = borrowerMarkdown;

        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown increased
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (borrowerStatus, borrowerDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 newBorrowerMarkdown = 0;
        if (borrowerStatus == RepaymentStatus.Default && borrowerDefaultTime > 0) {
            uint256 timeInDefault = block.timestamp > borrowerDefaultTime ? block.timestamp - borrowerDefaultTime : 0;
            newBorrowerMarkdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(newBorrowerMarkdown > oldMarkdown, "Markdown should increase over time");
    }

    /// @notice Test market total markdown accumulation with multiple borrowers
    function testMarketTotalMarkdownAccumulation() public {
        // Setup multiple borrowers
        address[] memory borrowers = new address[](3);
        borrowers[0] = BORROWER;
        borrowers[1] = ONBEHALF;
        borrowers[2] = RECEIVER;

        uint256[] memory borrowAmounts = new uint256[](3);
        borrowAmounts[0] = 10_000e18;
        borrowAmounts[1] = 15_000e18;
        borrowAmounts[2] = 5_000e18;

        // Setup all borrowers with loans and obligations
        for (uint256 i = 0; i < borrowers.length; i++) {
            _setupBorrowerWithLoan(borrowers[i], borrowAmounts[i]);
            _createPastObligation(borrowers[i], 500, borrowAmounts[i]);
        }

        // Fast forward to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Get initial market state
        Market memory marketBefore = morpho.market(id);
        assertEq(marketBefore.totalMarkdownAmount, 0, "Should start with no markdown");

        // Touch each borrower and verify running total
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);

            // Get individual markdown
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
                markdown = markdownManager.calculateMarkdown(borrowers[i], borrowAssets, timeInDefault);
            }
            expectedTotal += markdown;

            // Verify market total
            Market memory marketAfter = morpho.market(id);
            assertEq(marketAfter.totalMarkdownAmount, expectedTotal, "Market total should match sum");
        }

        // Forward time and update one borrower
        _continueMarketCycles(id, block.timestamp + 5 days);

        // Get stored markdown for first borrower before update
        uint128 storedMarkdown = morphoCredit.markdownState(id, borrowers[0]);

        // Update first borrower
        morphoCredit.accrueBorrowerPremium(id, borrowers[0]);

        // Get new markdown after update
        uint256 borrower0Assets = morpho.expectedBorrowAssets(marketParams, borrowers[0]);
        (RepaymentStatus borrower0Status, uint256 borrower0DefaultTime) =
            morphoCredit.getRepaymentStatus(id, borrowers[0]);
        uint256 newMarkdown = 0;
        if (borrower0Status == RepaymentStatus.Default && borrower0DefaultTime > 0) {
            uint256 timeInDefault = block.timestamp > borrower0DefaultTime ? block.timestamp - borrower0DefaultTime : 0;
            newMarkdown = markdownManager.calculateMarkdown(borrowers[0], borrower0Assets, timeInDefault);
        }
        uint256 markdownIncrease = newMarkdown - storedMarkdown;

        // Verify market total increased by the difference
        Market memory marketFinal = morpho.market(id);
        assertEq(
            marketFinal.totalMarkdownAmount, expectedTotal + markdownIncrease, "Market total should increase correctly"
        );
    }

    /// @notice Test multiple status transitions over time
    function testMultipleStatusTransitions() public {
        _setupBorrowerWithLoan(BORROWER, 10_000e18);

        // Cycle 1: Create obligation
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Go to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        uint128 markdown1 = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus status1, uint256 defaultTime1) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status1), uint8(RepaymentStatus.Default), "Should be in default");
        assertTrue(defaultTime1 > 0, "Should have default time");
        assertTrue(markdown1 > 0, "Should have markdown");

        // Repay to clear default
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue);
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");

        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        uint128 markdown2 = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus status2, uint256 statusStartTime2) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status2), uint8(RepaymentStatus.Current), "Should be current after repay");
        assertEq(statusStartTime2, 0, "Should have no status start time after repay");
        assertEq(markdown2, 0, "Should have no markdown after repay");

        // Cycle 2: Create new obligation and default again
        _continueMarketCycles(id, block.timestamp + 10 days);
        _createPastObligation(BORROWER, 1000, 10_000e18); // 10% repayment this time

        // Go to default again
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        uint128 markdown3 = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus status3, uint256 defaultTime3) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status3), uint8(RepaymentStatus.Default), "Should be in default again");
        assertTrue(defaultTime3 > defaultTime1, "New default time should be later");
        assertTrue(markdown3 > 0, "Should have markdown again");

        // Market total should only reflect current markdown
        Market memory market = morpho.market(id);
        assertEq(market.totalMarkdownAmount, markdown3, "Market total should only include current markdown");
    }

    /// @notice Test that non-defaulted borrowers have no markdown
    function testNoMarkdownForNonDefaultedBorrowers() public {
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Get cycle info to properly time the test
        (uint128 paymentCycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, paymentCycleId);

        // Already past cycle end date due to _createPastObligation, so already in grace period
        (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.GracePeriod), "Should be in grace period");

        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        uint128 markdown = morphoCredit.markdownState(id, BORROWER);
        assertEq(markdown, 0, "Grace period borrower should have no markdown");

        // Test Delinquent
        _continueMarketCycles(id, cycleEndDate + GRACE_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        markdown = morphoCredit.markdownState(id, BORROWER);
        assertEq(markdown, 0, "Delinquent borrower should have no markdown");
    }
}
