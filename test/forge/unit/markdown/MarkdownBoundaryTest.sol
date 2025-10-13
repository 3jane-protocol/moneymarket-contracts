// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {Market} from "../../../../src/interfaces/IMorpho.sol";

/// @title MarkdownBoundaryTest
/// @notice Tests for markdown behavior at exact boundaries and edge cases
contract MarkdownBoundaryTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoCreditLib for IMorphoCredit;
    using SharesMathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    uint256 constant FULL_MARKDOWN_DURATION = 70 days;

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);

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

        // Enable markdown for test borrowers
        markdownManager.setEnableMarkdown(BORROWER, true);

        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 1_000_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1_000_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test markdown at exactly day 0 (instant default)
    function testBoundary_Day0() public {
        uint256 borrowAmount = 10_000e18;

        // Time = 0
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 0);
        assertEq(markdown, 0, "Markdown at day 0 should be 0");
    }

    /// @notice Test markdown at 1 second into default
    function testBoundary_OneSecond() public {
        uint256 borrowAmount = 10_000e18;

        // Time = 1 second
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 1);

        // Expected: (10_000e18 * 1) / (70 * 86400) ≈ 1.65e15 wei
        uint256 expected = (borrowAmount * 1) / FULL_MARKDOWN_DURATION;
        assertEq(markdown, expected, "Markdown at 1 second should be minimal");
        assertGt(markdown, 0, "Markdown should be non-zero after 1 second");
    }

    /// @notice Test markdown at exactly day 70 (100% markdown)
    function testBoundary_Day70Exact() public {
        uint256 borrowAmount = 10_000e18;

        // Time = exactly 70 days
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, FULL_MARKDOWN_DURATION);
        assertEq(markdown, borrowAmount, "Markdown at day 70 should be 100%");
    }

    /// @notice Test markdown 1 second before day 70
    function testBoundary_OneSecondBeforeDay70() public {
        uint256 borrowAmount = 10_000e18;

        // Time = 70 days - 1 second
        uint256 timeInDefault = FULL_MARKDOWN_DURATION - 1;
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);

        // Should be slightly less than 100%
        assertLt(markdown, borrowAmount, "Markdown should be less than 100% before day 70");

        // Should be very close to 100%
        uint256 difference = borrowAmount - markdown;
        assertLt(difference, borrowAmount / 1000, "Should be within 0.1% of full markdown");
    }

    /// @notice Test markdown at day 71 and beyond (should cap at 100%)
    function testBoundary_Day71AndBeyond() public {
        uint256 borrowAmount = 10_000e18;

        // Day 71
        uint256 markdown71 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 71 days);
        assertEq(markdown71, borrowAmount, "Markdown at day 71 should cap at 100%");

        // Day 100
        uint256 markdown100 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 100 days);
        assertEq(markdown100, borrowAmount, "Markdown at day 100 should cap at 100%");

        // Day 365
        uint256 markdown365 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 365 days);
        assertEq(markdown365, borrowAmount, "Markdown at day 365 should cap at 100%");

        // Max time
        uint256 markdownMax = markdownManager.calculateMarkdown(BORROWER, borrowAmount, type(uint256).max);
        assertEq(markdownMax, borrowAmount, "Markdown at max time should cap at 100%");
    }

    /// @notice Test markdown with very small amounts (1 wei)
    function testBoundary_OneWeiBorrow() public {
        uint256 borrowAmount = 1; // 1 wei

        // At half duration
        uint256 timeInDefault = FULL_MARKDOWN_DURATION / 2;
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);
        assertEq(markdown, 0, "1 wei markdown at half duration rounds down to 0");

        // At full duration
        markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, FULL_MARKDOWN_DURATION);
        assertEq(markdown, 1, "1 wei markdown at full duration should be 1 wei");
    }

    /// @notice Test markdown with amounts that cause rounding
    function testBoundary_RoundingEdgeCases() public {
        // Test case where (amount * time) / duration has remainder
        uint256 borrowAmount = 1000000000000000003; // Prime number of wei
        uint256 timeInDefault = 1 days;

        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);
        uint256 expected = (borrowAmount * timeInDefault) / FULL_MARKDOWN_DURATION;

        assertEq(markdown, expected, "Markdown should round down consistently");

        // Verify no overflow with calculation
        uint256 product = borrowAmount * timeInDefault;
        assertTrue(product / borrowAmount == timeInDefault, "Should not overflow");
    }

    /// @notice Test markdown with maximum safe values
    function testBoundary_MaxSafeValues() public {
        // Use max uint128 to avoid overflow in multiplication
        uint256 borrowAmount = type(uint128).max;
        uint256 timeInDefault = 35 days; // Half of 70 days

        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);

        // Should be approximately 50% of max uint128
        uint256 expected = borrowAmount / 2;
        assertApproxEqRel(markdown, expected, 0.01e18, "Should be approximately 50%");
    }

    /// @notice Test exact midpoint (day 35)
    function testBoundary_ExactMidpoint() public {
        uint256 borrowAmount = 10_000e18;
        uint256 timeInDefault = 35 days; // Exactly half of 70 days

        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);
        uint256 expected = borrowAmount / 2; // Should be exactly 50%

        assertEq(markdown, expected, "Markdown at day 35 should be exactly 50%");
    }

    /// @notice Test transitions at each day boundary
    function testBoundary_DailyTransitions() public {
        uint256 borrowAmount = 70_000e18; // Use 70k so each day = 1k

        for (uint256 day = 0; day <= 70; day++) {
            uint256 timeInDefault = day * 1 days;
            uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);

            uint256 expected = day >= 70 ? borrowAmount : (borrowAmount * day) / 70;
            assertEq(markdown, expected, string.concat("Day ", vm.toString(day), " markdown incorrect"));
        }
    }

    /// @notice Test markdown with zero borrow amount
    function testBoundary_ZeroBorrowAmount() public {
        uint256 borrowAmount = 0;

        // At various times
        uint256 markdown0 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 0);
        uint256 markdown35 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 35 days);
        uint256 markdown70 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 70 days);
        uint256 markdownMax = markdownManager.calculateMarkdown(BORROWER, borrowAmount, type(uint256).max);

        assertEq(markdown0, 0, "Zero borrow at day 0 should be 0");
        assertEq(markdown35, 0, "Zero borrow at day 35 should be 0");
        assertEq(markdown70, 0, "Zero borrow at day 70 should be 0");
        assertEq(markdownMax, 0, "Zero borrow at max time should be 0");
    }

    /// @notice Test share conversion at boundaries
    function testBoundary_ShareConversionEdgeCases() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Move to exactly day 70 in default
        uint256 defaultStartTime = block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1;
        _continueMarketCycles(id, defaultStartTime + 70 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get market state
        Market memory market = morpho.market(id);
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);

        // At day 70, markdown should equal borrow amount
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);

            // Markdown should be capped at borrow assets
            assertLe(markdown, borrowAssets, "Markdown should not exceed borrow assets");
        }
    }

    /// @notice Test precision loss with very large durations
    function testBoundary_PrecisionWithLargeDurations() public {
        uint256 borrowAmount = 1e36; // Very large amount

        // Test at 1 second with large amount
        uint256 markdown1s = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 1);
        assertGt(markdown1s, 0, "Should have non-zero markdown even with large amounts");

        // Test proportionality is maintained
        uint256 markdown1d = markdownManager.calculateMarkdown(BORROWER, borrowAmount, 1 days);
        uint256 ratio = markdown1d / markdown1s;
        assertEq(ratio, 86400, "Daily markdown should be 86400x the per-second markdown");
    }
}
