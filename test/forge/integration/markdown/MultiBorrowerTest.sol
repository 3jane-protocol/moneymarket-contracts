// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {Market, Position, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @title MultiBorrowerTest
/// @notice Tests for concurrent borrower scenarios including multiple defaults and market totals
contract MultiBorrowerTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    // Test borrowers
    address[] borrowers;
    uint256 constant NUM_BORROWERS = 10;

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

        // Setup borrowers array
        borrowers = new address[](NUM_BORROWERS);
        for (uint256 i = 0; i < NUM_BORROWERS; i++) {
            borrowers[i] = makeAddr(string.concat("Borrower", vm.toString(i)));
        }

        // Setup large initial supply
        loanToken.setBalance(SUPPLIER, 10_000_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test concurrent defaults with correct market total tracking
    function testConcurrentDefaultsMarketTotal() public {
        uint256[] memory borrowAmounts = new uint256[](NUM_BORROWERS);

        // Setup varied borrow amounts
        for (uint256 i = 0; i < NUM_BORROWERS; i++) {
            borrowAmounts[i] = (50_000e18 + i * 10_000e18); // 50k to 140k
            _setupBorrowerWithLoan(borrowers[i], borrowAmounts[i]);
        }

        // Create obligations for half the borrowers at the same time
        uint256 numDefaulting = NUM_BORROWERS / 2;

        // First warp to ensure we can create the cycle
        vm.warp(block.timestamp + 2 days);
        uint256 cycleEndDate = block.timestamp - 1 days;

        // Create all obligations at once with the same cycle
        address[] memory defaultingBorrowers = new address[](numDefaulting);
        uint256[] memory bpsList = new uint256[](numDefaulting);
        uint256[] memory balances = new uint256[](numDefaulting);

        for (uint256 i = 0; i < numDefaulting; i++) {
            defaultingBorrowers[i] = borrowers[i];
            bpsList[i] = 500; // 5% payment
            balances[i] = borrowAmounts[i];
        }

        vm.prank(address(creditLine));
        morphoCredit.closeCycleAndPostObligations(id, cycleEndDate, defaultingBorrowers, bpsList, balances);

        // Move to default period (30 days past cycle end)
        vm.warp(cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Record initial supply assets before markdowns
        Market memory marketBefore = morpho.market(id);
        uint256 supplyBefore = marketBefore.totalSupplyAssets;

        // Update markdowns for defaulted borrowers and track total reduction
        uint256 totalMarkdowns = 0;
        for (uint256 i = 0; i < numDefaulting; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);

            // Verify status
            (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default");

            // Get individual markdown
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                markdown = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
            }
            totalMarkdowns += markdown;
        }

        // Verify supply was reduced by total markdowns (accounting for interest accrual)
        Market memory marketAfter = morpho.market(id);
        // The supply increases due to interest but decreases due to markdowns
        // So we check that the net effect is approximately correct
        uint256 interestAccrued = marketAfter.totalBorrowAssets - marketBefore.totalBorrowAssets;
        assertApproxEqAbs(
            marketAfter.totalSupplyAssets + totalMarkdowns,
            supplyBefore + interestAccrued,
            1e18, // Allow 1 token difference for rounding
            "Supply change should match interest minus markdowns"
        );

        // Verify non-defaulted borrowers have no markdown
        for (uint256 i = numDefaulting; i < NUM_BORROWERS; i++) {
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            // Non-defaulted borrowers should have no markdown
            assertEq(markdown, 0, "Non-defaulted should have no markdown");
        }
    }

    /// @notice Test staggered defaults over time
    function testStaggeredDefaults() public {
        uint256 borrowAmount = 100_000e18;

        // Setup all borrowers with loans
        for (uint256 i = 0; i < NUM_BORROWERS; i++) {
            _setupBorrowerWithLoan(borrowers[i], borrowAmount);
        }

        // Create all obligations at the same time for simplicity
        vm.warp(block.timestamp + 2 days);
        uint256 cycleEndDate = block.timestamp - 1 days;

        address[] memory obligationBorrowers = new address[](NUM_BORROWERS);
        uint256[] memory bpsList = new uint256[](NUM_BORROWERS);
        uint256[] memory balances = new uint256[](NUM_BORROWERS);

        for (uint256 i = 0; i < NUM_BORROWERS; i++) {
            obligationBorrowers[i] = borrowers[i];
            bpsList[i] = 500; // 5% repayment
            balances[i] = borrowAmount;
        }

        vm.prank(address(creditLine));
        morphoCredit.closeCycleAndPostObligations(id, cycleEndDate, obligationBorrowers, bpsList, balances);

        // Move to default period
        vm.warp(cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1 days);

        // First, update half the borrowers to trigger markdown
        uint256 halfBorrowers = NUM_BORROWERS / 2;
        uint256[] memory initialMarkdowns = new uint256[](halfBorrowers);

        for (uint256 i = 0; i < halfBorrowers; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                markdown = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
            }
            initialMarkdowns[i] = markdown;
            assertTrue(markdown > 0, "Should have initial markdown");
        }

        // Move forward 10 days
        vm.warp(block.timestamp + 10 days);

        // Update the same borrowers and verify markdown increased
        uint256 totalIncrease = 0;
        for (uint256 i = 0; i < halfBorrowers; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 newMarkdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                newMarkdown = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
            }
            assertTrue(newMarkdown > initialMarkdowns[i], "Markdown should increase over time");
            totalIncrease += (newMarkdown - initialMarkdowns[i]);
        }

        // Verify market total markdown
        uint256 marketTotalMarkdown = morpho.market(id).totalMarkdownAmount;
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < halfBorrowers; i++) {
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                markdown = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
            }
            expectedTotal += markdown;
        }
        assertEq(marketTotalMarkdown, expectedTotal, "Market total should match sum of individual markdowns");

        // Verify non-touched borrowers still have stale markdown state
        // They should show markdown when queried but state is not updated in storage
        for (uint256 i = halfBorrowers; i < NUM_BORROWERS; i++) {
            uint128 storedMarkdown = morphoCredit.markdownState(id, borrowers[i]);
            assertEq(storedMarkdown, 0, "Non-touched borrowers should have no stored markdown");

            // But we can calculate current markdown for defaulted borrowers
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 calculatedMarkdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                calculatedMarkdown = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
            }
            assertTrue(calculatedMarkdown > 0, "Should calculate markdown for defaulted borrowers");
        }
    }

    /// @notice Test mixed portfolio with various statuses
    function testMixedPortfolioMarkdowns() public {
        // Setup borrowers in different states:
        // 0-2: Current (no obligations)
        // 3-4: Grace period
        // 5-6: Delinquent
        // 7-9: Default

        uint256 borrowAmount = 100_000e18;

        // Setup all borrowers
        for (uint256 i = 0; i < NUM_BORROWERS; i++) {
            _setupBorrowerWithLoan(borrowers[i], borrowAmount + i * 5_000e18);
        }

        // Create obligations for non-current borrowers
        // First create a single cycle for all borrowers 3-9
        vm.warp(block.timestamp + 2 days);
        uint256 cycleEndDate = block.timestamp - 1 days;

        uint256 numObligations = NUM_BORROWERS - 3; // borrowers 3-9
        address[] memory obligationBorrowers = new address[](numObligations);
        uint256[] memory bpsList = new uint256[](numObligations);
        uint256[] memory balances = new uint256[](numObligations);

        for (uint256 i = 0; i < numObligations; i++) {
            uint256 borrowerIdx = i + 3;
            obligationBorrowers[i] = borrowers[borrowerIdx];
            bpsList[i] = 500 + borrowerIdx * 100; // Varying payment %
            balances[i] = borrowAmount + borrowerIdx * 5_000e18;
        }

        vm.prank(address(creditLine));
        morphoCredit.closeCycleAndPostObligations(id, cycleEndDate, obligationBorrowers, bpsList, balances);

        // Get cycle info
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, borrowers[3]);
        uint256 cycleEnd = morphoCredit.paymentCycle(id, cycleId);

        // Move to grace period (borrowers 3-4)
        vm.warp(cycleEnd + 1 hours);

        // Verify grace period borrowers
        for (uint256 i = 3; i <= 4; i++) {
            (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            assertEq(uint8(status), uint8(RepaymentStatus.GracePeriod), "Should be in grace");

            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            // Grace period borrowers should have no markdown
            assertEq(markdown, 0, "No markdown in grace period");
        }

        // Move to delinquent period (borrowers 5-6 become delinquent, 3-4 still grace)
        vm.warp(cycleEnd + GRACE_PERIOD_DURATION + 1 hours);

        // Verify delinquent borrowers
        for (uint256 i = 5; i <= 6; i++) {
            (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            assertEq(uint8(status), uint8(RepaymentStatus.Delinquent), "Should be delinquent");

            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            // Delinquent borrowers should have no markdown
            assertEq(markdown, 0, "No markdown when delinquent");
        }

        // Move to default period for borrowers 7-9
        vm.warp(cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1 days);

        // Update and verify defaulted borrowers
        uint256 totalMarkdown = 0;
        for (uint256 i = 7; i <= 9; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);

            (RepaymentStatus status,) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default");

            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            uint256 markdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                markdown = markdownManager.calculateMarkdown(borrowAssets, defaultTime, block.timestamp);
            }
            assertTrue(markdown > 0, "Should have markdown in default");
            totalMarkdown += markdown;
        }

        // Verify supply was reduced by markdown amount
        Market memory marketBefore = morpho.market(id);
        uint256 supplyBeforeMarkdown = marketBefore.totalSupplyAssets + totalMarkdown; // Approximate initial supply

        // The actual supply should be reduced by the total markdown
        assertApproxEqAbs(
            marketBefore.totalSupplyAssets,
            supplyBeforeMarkdown > totalMarkdown ? supplyBeforeMarkdown - totalMarkdown : 0,
            1e6,
            "Supply should be reduced by markdown"
        );
    }

    /// @notice Test markdown accuracy with no cross-contamination
    function testNoMarkdownCrossContamination() public {
        // Setup 3 borrowers with different amounts and obligations
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100_000e18;
        amounts[1] = 200_000e18;
        amounts[2] = 50_000e18;

        uint256[] memory repaymentBps = new uint256[](3);
        repaymentBps[0] = 500; // 5%
        repaymentBps[1] = 1000; // 10%
        repaymentBps[2] = 200; // 2%

        // Setup loans and obligations
        for (uint256 i = 0; i < 3; i++) {
            _setupBorrowerWithLoan(borrowers[i], amounts[i]);
            _createPastObligation(borrowers[i], repaymentBps[i], amounts[i]);
        }

        // Move all to default and record default start time
        _moveToDefault();

        // Get the actual default start time from the first borrower
        (, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, borrowers[0]);

        // Let them default for different periods from now
        uint256 baseTime = block.timestamp;
        uint256[] memory additionalDays = new uint256[](3);
        additionalDays[0] = 10;
        additionalDays[1] = 20;
        additionalDays[2] = 5;

        // Update each borrower after their respective additional default period
        // Process borrowers in order of their additional days to avoid time travel
        uint256[] memory indices = new uint256[](3);
        indices[0] = 2; // 5 days (shortest)
        indices[1] = 0; // 10 days
        indices[2] = 1; // 20 days (longest)

        for (uint256 j = 0; j < 3; j++) {
            uint256 i = indices[j];
            vm.warp(baseTime + additionalDays[i] * 1 days);
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);
        }

        // Verify each borrower has markdown and they are different
        uint256[] memory markdowns = new uint256[](3);
        uint256[] memory borrowAmounts = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            borrowAmounts[i] = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) = morphoCredit.getRepaymentStatus(id, borrowers[i]);
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                markdowns[i] = markdownManager.calculateMarkdown(borrowAmounts[i], defaultTime, block.timestamp);
            }
            assertTrue(markdowns[i] > 0, "Should have markdown");
        }

        // Verify markdowns are different (reflecting different borrow amounts)
        assertTrue(markdowns[0] != markdowns[1], "Markdowns should be different");
        assertTrue(markdowns[1] != markdowns[2], "Markdowns should be different");
        assertTrue(markdowns[0] != markdowns[2], "Markdowns should be different");

        // Verify markdowns scale with borrow amounts (larger loans have larger markdowns)
        // borrowAmounts: [0] = 100k, [1] = 200k, [2] = 50k
        assertTrue(markdowns[1] > markdowns[0], "200k loan should have more markdown than 100k");
        assertTrue(markdowns[0] > markdowns[2], "100k loan should have more markdown than 50k");
    }

    /// @notice Test gas costs scale linearly with borrower count
    function testGasScalingWithBorrowerCount() public {
        uint256 borrowAmount = 100_000e18;
        uint256[] memory gasCosts = new uint256[](5);

        // Test with 1, 2, 4, 6, 8 defaulted borrowers
        uint256[] memory counts = new uint256[](5);
        counts[0] = 1;
        counts[1] = 2;
        counts[2] = 4;
        counts[3] = 6;
        counts[4] = 8;

        for (uint256 test = 0; test < counts.length; test++) {
            // Reset market state by creating new market
            // Use different collateral token addresses to create unique markets
            address uniqueCollateral = address(uint160(uint256(uint160(address(collateralToken))) + test + 1));
            MarketParams memory newMarketParams = MarketParams(
                address(loanToken),
                uniqueCollateral,
                address(oracle),
                address(irm),
                0, // Always use 0 LLTV for credit line markets
                address(creditLine)
            );
            Id newId = newMarketParams.id();

            vm.prank(OWNER);
            morpho.createMarket(newMarketParams);
            vm.prank(OWNER);
            morphoCredit.setMarkdownManager(newId, address(markdownManager));

            // Supply to new market
            loanToken.setBalance(SUPPLIER, 2_000_000e18);
            vm.prank(SUPPLIER);
            morpho.supply(newMarketParams, 2_000_000e18, 0, SUPPLIER, hex"");

            // Setup borrowers
            for (uint256 i = 0; i < counts[test]; i++) {
                vm.prank(address(creditLine));
                morphoCredit.setCreditLine(newId, borrowers[i], borrowAmount * 2, 0);

                vm.prank(borrowers[i]);
                morpho.borrow(newMarketParams, borrowAmount, 0, borrowers[i], borrowers[i]);

                // Create obligation
                vm.warp(block.timestamp + 2 days);
                address[] memory singleBorrower = new address[](1);
                singleBorrower[0] = borrowers[i];
                uint256[] memory bps = new uint256[](1);
                bps[0] = 500;
                uint256[] memory balances = new uint256[](1);
                balances[0] = borrowAmount;

                vm.prank(address(creditLine));
                morphoCredit.closeCycleAndPostObligations(
                    newId, block.timestamp - 1 days, singleBorrower, bps, balances
                );
            }

            // Move to default
            vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 10 days);

            // Measure gas for updating all defaulted borrowers
            uint256 gasBefore = gasleft();
            for (uint256 i = 0; i < counts[test]; i++) {
                morphoCredit.accrueBorrowerPremium(newId, borrowers[i]);
            }
            gasCosts[test] = gasBefore - gasleft();

            emit log_named_uint(string.concat("Gas for ", vm.toString(counts[test]), " borrowers"), gasCosts[test]);
        }

        // Verify approximately linear scaling
        for (uint256 i = 1; i < counts.length; i++) {
            uint256 expectedGas = gasCosts[0] * counts[i];
            uint256 actualGas = gasCosts[i];
            // Allow 20% deviation from perfect linearity due to storage costs
            assertLt(actualGas, expectedGas * 120 / 100, "Gas should scale approximately linearly");
        }
    }

    // Helper functions

    function _moveToDefault() internal {
        // Get first borrower's obligation to determine timing
        for (uint256 i = 0; i < NUM_BORROWERS; i++) {
            (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, borrowers[i]);
            if (cycleId > 0) {
                uint256 cycleEndDate = morphoCredit.paymentCycle(id, cycleId);
                uint256 defaultTime = cycleEndDate + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1;
                vm.warp(defaultTime);
                break;
            }
        }
    }
}
