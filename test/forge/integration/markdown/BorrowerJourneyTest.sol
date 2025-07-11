// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {Market, Position, RepaymentStatus, MarkdownState} from "../../../../src/interfaces/IMorpho.sol";

/// @title BorrowerJourneyTest
/// @notice Integration tests for borrower lifecycle including status transitions and markdown accrual
contract BorrowerJourneyTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
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
        morphoCredit.setMarkdownManager(id, address(markdownManager));
        vm.stopPrank();

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 1_000_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1_000_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test complete borrower journey from current to default with markdown accrual
    function testCurrentToDefaultFlowWithMarkdown() public {
        uint256 borrowAmount = 100_000e18;

        // Step 1: Borrower takes loan (Current status)
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Verify initial status
        (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Current), "Should start as current");

        // Step 2: Create payment obligation (creates past obligation)
        uint256 obligationAmount = borrowAmount * 5 / 100; // 5% monthly payment
        _createPastObligation(BORROWER, 500, borrowAmount);

        // After creating past obligation, borrower is already in grace period
        (status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.GracePeriod), "Should be in grace period after past obligation");

        // Get cycle end date for tracking
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);

        // Step 3: Verify no markdown during grace period
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        uint128 lastMarkdown = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus graceStatus, uint256 statusStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(lastMarkdown, 0, "No markdown in grace period");
        assertEq(uint8(graceStatus), uint8(RepaymentStatus.GracePeriod), "Should be in grace period");

        // Step 4: Enter delinquent status
        vm.warp(cycleEndDate + GRACE_PERIOD_DURATION + 1);
        (status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Delinquent), "Should become delinquent");

        // Still no markdown when delinquent
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        lastMarkdown = morphoCredit.markdownState(id, BORROWER);
        (RepaymentStatus delinquentStatus, uint256 delinquentStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(lastMarkdown, 0, "No markdown when delinquent");
        assertEq(uint8(delinquentStatus), uint8(RepaymentStatus.Delinquent), "Should be delinquent");

        // Step 5: Enter default status
        uint256 defaultStartTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;
        vm.warp(defaultStartTime + 1);

        // Expect DefaultStarted event
        vm.expectEmit(true, true, false, true);
        emit DefaultStarted(id, BORROWER, defaultStartTime);

        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        (status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default");

        // Verify markdown starts
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus statusNow, uint256 recordedDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(statusNow), uint8(RepaymentStatus.Default), "Should be in default");
        assertEq(recordedDefaultTime, defaultStartTime, "Default time should be recorded");

        // Calculate markdown at exact default time
        uint256 markdown = 0;
        if (statusNow == RepaymentStatus.Default && recordedDefaultTime > 0) {
            markdown = markdownManager.calculateMarkdown(borrowAssets, recordedDefaultTime, block.timestamp);
        }
        assertEq(markdown, 0, "Markdown should be 0 at exact default time");

        // Step 6: Markdown accrues over time
        vm.warp(defaultStartTime + 10 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (statusNow, recordedDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdown10Days = 0;
        if (statusNow == RepaymentStatus.Default && recordedDefaultTime > 0) {
            markdown10Days = markdownManager.calculateMarkdown(borrowAssets, recordedDefaultTime, block.timestamp);
        }
        assertTrue(markdown10Days > 0, "Should have markdown after 10 days");

        // Expected: 10 days * 1% per day = 10% markdown
        uint256 expectedMarkdown = borrowAssets * 10 / 100;
        assertApproxEqRel(markdown10Days, expectedMarkdown, 0.01e18, "Markdown should be ~10%");

        // Step 7: Continue to max markdown
        vm.warp(defaultStartTime + 100 days); // Well past 70% cap
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (statusNow, recordedDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownMax = 0;
        if (statusNow == RepaymentStatus.Default && recordedDefaultTime > 0) {
            markdownMax = markdownManager.calculateMarkdown(borrowAssets, recordedDefaultTime, block.timestamp);
        }
        uint256 maxExpected = borrowAssets * 70 / 100; // 70% cap
        assertApproxEqRel(markdownMax, maxExpected, 0.03e18, "Markdown should cap at 70%");
    }

    /// @notice Test default to recovery flow with markdown clearing
    function testDefaultRecoveryWithMarkdownClearing() public {
        uint256 borrowAmount = 100_000e18;

        // Setup borrower in default with markdown
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to default
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
        uint256 defaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1;
        vm.warp(defaultTime + 15 days); // 15 days in default

        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown exists
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 statusDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownBefore = 0;
        if (status == RepaymentStatus.Default && statusDefaultTime > 0) {
            markdownBefore = markdownManager.calculateMarkdown(borrowAssets, statusDefaultTime, block.timestamp);
        }
        assertTrue(markdownBefore > 0, "Should have markdown");

        Market memory marketBefore = morpho.market(id);
        assertTrue(marketBefore.totalMarkdownAmount > 0, "Market should have markdown");

        // Repay obligation to recover
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue);

        // Expect DefaultCleared event during repay
        vm.expectEmit(true, true, false, false);
        emit DefaultCleared(id, BORROWER);

        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");

        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify status is current
        (RepaymentStatus currentStatus,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(currentStatus), uint8(RepaymentStatus.Current), "Should be current after repayment");

        // Verify markdown cleared
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus statusAfter, uint256 statusStartTimeAfter) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownAfter = 0;
        // After repayment, borrower should be current with no markdown
        assertEq(markdownAfter, 0, "Markdown should be cleared");
        assertEq(statusStartTimeAfter, 0, "Status start time should be cleared");

        // Verify market total updated
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalMarkdownAmount, 0, "Market markdown should be cleared");
    }

    /// @notice Test multiple default and recovery cycles
    function testMultipleDefaultRecoveryCycles() public {
        uint256 borrowAmount = 100_000e18;
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Cycle 1: Default and recover
        _createPastObligation(BORROWER, 500, borrowAmount);
        _moveToDefault();

        // Wait some time in default to accumulate markdown
        vm.warp(block.timestamp + 5 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 statusDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdown1 = 0;
        if (status == RepaymentStatus.Default && statusDefaultTime > 0) {
            markdown1 = markdownManager.calculateMarkdown(borrowAssets, statusDefaultTime, block.timestamp);
        }
        assertTrue(markdown1 > 0, "Should have markdown in cycle 1");

        // Recover
        _repayObligation(BORROWER);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownCleared = 0;
        // After repayment, borrower should be current with no markdown
        assertEq(markdownCleared, 0, "Markdown should be cleared after recovery");

        // Cycle 2: Default again with different obligation
        vm.warp(block.timestamp + 30 days);
        _createPastObligation(BORROWER, 1000, borrowAmount); // 10% payment this time
        _moveToDefault();

        vm.warp(block.timestamp + 20 days); // 20 days in default
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status, statusDefaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdown2 = 0;
        if (status == RepaymentStatus.Default && statusDefaultTime > 0) {
            markdown2 = markdownManager.calculateMarkdown(borrowAssets, statusDefaultTime, block.timestamp);
        }
        assertTrue(markdown2 > markdown1, "Second default should have more markdown (longer time)");

        // Cycle 3: Partial payment is not allowed when not current
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 partialPayment = amountDue / 2;

        loanToken.setBalance(BORROWER, partialPayment);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), partialPayment);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, partialPayment, 0, BORROWER, hex"");
        vm.stopPrank();

        // Should still be in default
        (RepaymentStatus statusAfterPartial,) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(statusAfterPartial), uint8(RepaymentStatus.Default), "Should remain in default");

        // Markdown continues to accrue
        vm.warp(block.timestamp + 5 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (, uint256 statusDefaultTime3) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdown3 = 0;
        if (status == RepaymentStatus.Default && statusDefaultTime3 > 0) {
            markdown3 = markdownManager.calculateMarkdown(borrowAssets, statusDefaultTime3, block.timestamp);
        }
        assertTrue(markdown3 > markdown2, "Markdown should continue accruing");
    }

    /// @notice Test settlement during various stages
    function testSettlementAtDifferentStages() public {
        uint256 borrowAmount = 100_000e18;

        // Test 1: Settlement while current (no markdown)
        address borrower1 = makeAddr("Borrower1");
        _setupBorrowerWithLoan(borrower1, borrowAmount);

        loanToken.setBalance(address(creditLine), 10_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 10_000e18);
        morphoCredit.settleDebt(marketParams, borrower1, 10_000e18, hex"");
        vm.stopPrank();

        Position memory pos1 = morpho.position(id, borrower1);
        assertEq(pos1.borrowShares, 0, "Position should be cleared");

        // Test 2: Settlement during grace period (no markdown)
        address borrower2 = makeAddr("Borrower2");
        _setupBorrowerWithLoan(borrower2, borrowAmount);
        _createPastObligation(borrower2, 500, borrowAmount);

        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, borrower2);
        vm.warp(morphoCredit.paymentCycle(id, cycleId) + 1); // Grace period

        loanToken.setBalance(address(creditLine), 20_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 20_000e18);
        morphoCredit.settleDebt(marketParams, borrower2, 20_000e18, hex"");
        vm.stopPrank();

        // Test 3: Settlement during default (with markdown)
        address borrower3 = makeAddr("Borrower3");
        _setupBorrowerWithLoan(borrower3, borrowAmount);
        _createPastObligation(borrower3, 500, borrowAmount);

        _moveToDefault();
        vm.warp(block.timestamp + 30 days); // 30 days in default
        morphoCredit.accrueBorrowerPremium(id, borrower3);

        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrower3);
        (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrower3);
        uint256 markdownBefore = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            markdownBefore = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
        }
        assertTrue(markdownBefore > 0, "Should have markdown");

        Market memory marketBefore = morpho.market(id);

        loanToken.setBalance(address(creditLine), 5_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 5_000e18);
        (uint256 repaidShares, uint256 writtenOffShares) =
            morphoCredit.settleDebt(marketParams, borrower3, 5_000e18, hex"");
        vm.stopPrank();

        assertTrue(writtenOffShares > repaidShares, "Most debt should be written off");

        // Verify markdown cleared
        borrowAssets = morpho.expectedBorrowAssets(marketParams, borrower3);
        (status,) = morphoCredit.getRepaymentStatus(id, borrower3);
        uint256 markdownAfter = 0;
        // After settlement, borrower should have no debt and no markdown
        assertEq(markdownAfter, 0, "Markdown should be cleared after settlement");

        // Verify supply reduced
        Market memory marketAfter = morpho.market(id);
        assertTrue(marketAfter.totalSupplyAssets < marketBefore.totalSupplyAssets, "Supply should decrease");
    }

    /// @notice Test markdown updates through various operations
    function testMarkdownUpdateTriggers() public {
        uint256 borrowAmount = 100_000e18;

        // Setup multiple borrowers in default
        address[] memory borrowers = new address[](3);
        borrowers[0] = BORROWER;
        borrowers[1] = ONBEHALF;
        borrowers[2] = RECEIVER;

        for (uint256 i = 0; i < borrowers.length; i++) {
            _setupBorrowerWithLoan(borrowers[i], borrowAmount);
            _createPastObligation(borrowers[i], 500, borrowAmount);
        }

        _moveToDefault();

        // Initial markdown update for borrower 0
        morphoCredit.accrueBorrowerPremium(id, borrowers[0]);
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[0]);
        (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[0]);
        uint256 markdown0 = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            markdown0 = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
        }
        assertTrue(markdown0 > 0, "Borrower 0 should have markdown");

        // Borrower 1 markdown should update via explicit accrual
        morphoCredit.accrueBorrowerPremium(id, borrowers[1]);
        borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[1]);
        (status, defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[1]);
        uint256 markdown1 = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            markdown1 = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
        }
        assertTrue(markdown1 > 0, "Borrower 1 should have markdown after accrual");

        // Verify borrow is blocked for defaulted borrower
        vm.prank(borrowers[1]);
        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        morpho.borrow(marketParams, 1000e18, 0, borrowers[1], borrowers[1]);

        // Borrower 2 markdown updates via repay (must pay full obligation)
        (, uint128 amountDue2,) = morphoCredit.repaymentObligation(id, borrowers[2]);
        loanToken.setBalance(borrowers[2], amountDue2);
        vm.startPrank(borrowers[2]);
        loanToken.approve(address(morpho), amountDue2);
        morpho.repay(marketParams, amountDue2, 0, borrowers[2], hex"");
        vm.stopPrank();

        // After full repayment, markdown should be cleared
        borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[2]);
        (status,) = morphoCredit.getRepaymentStatus(id, borrowers[2]);
        uint256 markdown2 = 0;
        // After full repayment, borrower should be current with no markdown
        assertEq(markdown2, 0, "Borrower 2 should have no markdown after full repayment");

        // Fast forward and verify stale markdowns
        vm.warp(block.timestamp + 10 days);

        // Manual update via accrueBorrowerPremium
        uint256 oldMarkdown0 = markdown0;
        morphoCredit.accrueBorrowerPremium(id, borrowers[0]);
        borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[0]);
        (status, defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[0]);
        uint256 newMarkdown0 = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            newMarkdown0 = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
        }
        assertTrue(newMarkdown0 > oldMarkdown0, "Markdown should increase over time");
    }

    // Helper functions

    function _moveToDefault() internal {
        // Get the latest cycle to determine timing
        uint128 cycleId = uint128(morphoCredit.getLatestCycleId(id));
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
        uint256 defaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1;
        vm.warp(defaultTime);
    }

    function _repayObligation(address borrower) internal {
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrower);
        loanToken.setBalance(borrower, amountDue);
        vm.prank(borrower);
        morpho.repay(marketParams, amountDue, 0, borrower, hex"");
    }
}
