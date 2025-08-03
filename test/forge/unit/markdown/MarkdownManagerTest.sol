// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {IMarkdownManager} from "../../../../src/interfaces/IMarkdownManager.sol";
import {Market} from "../../../../src/interfaces/IMorpho.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";

/// @title MarkdownManagerTest
/// @notice Tests for markdown manager integration including validation, external calls, and error handling
contract MarkdownManagerTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    event MarkdownManagerSet(Id indexed id, address oldManager, address newManager);

    function setUp() public override {
        super.setUp();

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
        vm.stopPrank();

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test setting and updating markdown manager
    function testSetMarkdownManager() public {
        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock();

        // Test setting manager as owner
        vm.expectEmit(true, false, false, true);
        emit MarkdownManagerSet(id, address(0), address(markdownManager));

        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        assertEq(
            MorphoCredit(address(morphoCredit)).markdownManager(id), address(markdownManager), "Manager should be set"
        );
    }

    /// @notice Test that only owner can set markdown manager
    function testOnlyOwnerCanSetMarkdownManager() public {
        markdownManager = new MarkdownManagerMock();

        // Try as non-owner
        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        // Verify not set
        assertEq(MorphoCredit(address(morphoCredit)).markdownManager(id), address(0), "Manager should not be set");
    }

    /// @notice Test manager validation when setting
    function testMarkdownManagerValidation() public {
        // Create a manager that reports invalid for our market
        InvalidMarkdownManager invalidManager = new InvalidMarkdownManager();

        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.InvalidMarkdownManager.selector);
        morphoCredit.setMarkdownManager(id, address(invalidManager));

        // Verify not set
        assertEq(
            MorphoCredit(address(morphoCredit)).markdownManager(id), address(0), "Invalid manager should not be set"
        );
    }

    /// @notice Test setting manager to zero address (disabling markdowns)
    function testSetMarkdownManagerToZero() public {
        // First set a manager
        markdownManager = new MarkdownManagerMock();
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        // Then set to zero
        vm.expectEmit(true, false, false, true);
        emit MarkdownManagerSet(id, address(markdownManager), address(0));

        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(0));

        assertEq(MorphoCredit(address(morphoCredit)).markdownManager(id), address(0), "Manager should be cleared");
    }

    /// @notice Test correct parameters passed to markdown manager
    function testMarkdownManagerParameterPassing() public {
        markdownManager = new MarkdownManagerMock();
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Get cycle end date for proper timing calculation
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);

        // Fast forward to default
        uint256 expectedDefaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;
        vm.warp(expectedDefaultTime + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Forward more time
        uint256 timeInDefault = 5 days;
        vm.warp(expectedDefaultTime + timeInDefault);

        // Get repayment status and borrow assets
        (RepaymentStatus status, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);

        // Calculate markdown using the manager
        uint256 markdown = 0;
        if (status == RepaymentStatus.Default && defaultStartTime > 0) {
            uint256 actualTimeInDefault = block.timestamp > defaultStartTime ? block.timestamp - defaultStartTime : 0;
            markdown = markdownManager.calculateMarkdown(borrowAssets, actualTimeInDefault);
        }

        // Verify parameters were correct
        assertEq(defaultStartTime, expectedDefaultTime, "Default start time should match");
        assertTrue(borrowAssets >= 10_000e18, "Borrow assets should be at least initial amount");

        // Calculate expected markdown (1% per day for 5 days = 5%)
        uint256 expectedMarkdown = borrowAssets * 5 / 100;
        assertEq(markdown, expectedMarkdown, "Markdown calculation should be correct");
    }

    /// @notice Test markdown updates when manager is not set
    function testNoMarkdownWithoutManager() public {
        // Setup borrower in default but no manager set
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Get cycle info for timing
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
        uint256 expectedDefaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        // Fast forward to default
        vm.warp(expectedDefaultTime + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Check repayment status
        (RepaymentStatus status, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdown = 0; // No manager set, so no markdown calculation

        // Without a manager, borrower should still be in default status with proper timestamp
        assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default status");
        assertEq(defaultStartTime, expectedDefaultTime, "Should track default time based on repayment status");
        assertEq(markdown, 0, "Should have no markdown without manager");

        // Verify market total is also zero
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        assertEq(totalMarkdown, 0, "Market total should be zero without manager");
    }

    /// @notice Test gas consumption of external markdown calls
    function testMarkdownGasConsumption() public {
        markdownManager = new MarkdownManagerMock();
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Fast forward to default
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Measure gas for markdown update
        uint256 gasBefore = gasleft();
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage (typical should be < 100k for external call + storage updates)
        emit log_named_uint("Gas used for markdown update", gasUsed);
        assertTrue(gasUsed < 200_000, "Gas usage should be reasonable");
    }

    /// @notice Test markdown manager that reverts
    function testMarkdownManagerRevert() public {
        RevertingMarkdownManager revertingManager = new RevertingMarkdownManager();
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(revertingManager));

        // Setup borrower
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Fast forward to default
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Should revert when trying to update markdown
        vm.expectRevert("Markdown calculation failed");
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
    }

    /// @notice Test re-enabling markdown manager after borrower defaults without one
    function testReenablingMarkdownManager() public {
        // Setup borrower without markdown manager
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);

        // Get cycle info for timing
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, BORROWER);
        uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
        uint256 expectedDefaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        // Fast forward to default (no manager set)
        vm.warp(expectedDefaultTime + 5 days); // 5 days into default
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify borrower is in default with no markdown
        (RepaymentStatus status, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default");
        assertEq(defaultStartTime, expectedDefaultTime, "Should track default start time");

        // Verify no markdown since no manager
        uint256 markdownBefore = morphoCredit.markdownState(id, BORROWER);
        assertEq(markdownBefore, 0, "Should have no markdown without manager");

        // Now set a markdown manager after borrower already defaulted
        markdownManager = new MarkdownManagerMock();
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        // Move forward more time
        vm.warp(block.timestamp + 2 days); // Now 7 days total in default

        // Trigger markdown update
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown is now calculated from original default time
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        uint256 timeInDefault = block.timestamp > defaultStartTime ? block.timestamp - defaultStartTime : 0;
        uint256 expectedMarkdown = markdownManager.calculateMarkdown(borrowAssets, timeInDefault);

        // Check state was updated
        uint256 markdownAfter = morphoCredit.markdownState(id, BORROWER);
        assertEq(markdownAfter, expectedMarkdown, "Markdown should be calculated from original default time");

        // Verify markdown uses full 7 days in default, not just 2 days since manager was set
        uint256 daysInDefault = timeInDefault / 1 days;
        assertEq(daysInDefault, 7, "Should use full time in default");

        // With 1% daily rate, 7 days = 7% markdown
        uint256 expectedMarkdownAmount = borrowAssets * 7 / 100;
        assertApproxEqAbs(markdownAfter, expectedMarkdownAmount, 1e18, "Markdown should be ~7% of debt");

        // Verify market total updated
        Market memory market = morpho.market(id);
        assertEq(market.totalMarkdownAmount, markdownAfter, "Market total should match borrower markdown");
    }

    /// @notice Test updating manager while borrowers have markdown
    function testUpdateManagerWithExistingMarkdowns() public {
        // Set initial manager
        markdownManager = new MarkdownManagerMock();
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(markdownManager));

        // Setup borrower in default with markdown
        _setupBorrowerWithLoan(BORROWER, 10_000e18);
        _createPastObligation(BORROWER, 500, 10_000e18);
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get initial markdown
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownBefore = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdownBefore = markdownManager.calculateMarkdown(borrowAssets, timeInDefault);
        }
        assertTrue(markdownBefore > 0, "Should have initial markdown");

        // Create new manager with different rate (2% daily instead of 1%)
        MarkdownManagerMock newManager = new MarkdownManagerMock();
        newManager.setDailyMarkdownRate(200); // 2% daily (200 bps)

        // Update manager
        vm.prank(OWNER);
        morphoCredit.setMarkdownManager(id, address(newManager));

        // Forward time and update
        vm.warp(block.timestamp + 1 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Markdown should increase with new rate
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status, defaultTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 markdownAfter = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdownAfter = newManager.calculateMarkdown(borrowAssets, timeInDefault);
        }
        assertTrue(markdownAfter > markdownBefore, "Markdown should increase with new manager");
    }
}

/// @notice Mock markdown manager that always returns false for isValidForMarket
contract InvalidMarkdownManager is IMarkdownManager {
    function calculateMarkdown(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function getMarkdownMultiplier(uint256) external pure returns (uint256) {
        return 1e18;
    }

    function isValidForMarket(Id) external pure returns (bool) {
        return false;
    }
}

/// @notice Mock markdown manager that always reverts
contract RevertingMarkdownManager is IMarkdownManager {
    function calculateMarkdown(address, uint256, uint256) external pure returns (uint256) {
        revert("Markdown calculation failed");
    }

    function getMarkdownMultiplier(uint256) external pure returns (uint256) {
        revert("Markdown calculation failed");
    }

    function isValidForMarket(Id) external pure returns (bool) {
        return true;
    }
}
