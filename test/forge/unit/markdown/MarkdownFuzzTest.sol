// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {Market} from "../../../../src/interfaces/IMorpho.sol";

/// @title MarkdownFuzzTest
/// @notice Property-based fuzz testing for markdown calculations
contract MarkdownFuzzTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoCreditLib for IMorphoCredit;

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

    /// @notice Fuzz test: markdown should never exceed borrow amount
    function testFuzz_MarkdownNeverExceedsBorrowAmount(uint256 borrowAmount, uint256 timeInDefault) public {
        // Bound inputs to reasonable ranges
        borrowAmount = bound(borrowAmount, 1e18, 100_000e18);
        timeInDefault = bound(timeInDefault, 0, 365 days);

        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);

        // Property: markdown <= borrowAmount
        assertLe(markdown, borrowAmount, "Markdown should never exceed borrow amount");

        // Property: markdown at or after FULL_MARKDOWN_DURATION equals borrowAmount
        if (timeInDefault >= FULL_MARKDOWN_DURATION) {
            assertEq(markdown, borrowAmount, "Markdown should equal borrow amount after full duration");
        }
    }

    /// @notice Fuzz test: markdown increases linearly with time
    function testFuzz_MarkdownLinearProgression(uint256 borrowAmount, uint256 time1, uint256 time2) public {
        // Bound inputs
        borrowAmount = bound(borrowAmount, 1e18, 100_000e18);
        time1 = bound(time1, 0, FULL_MARKDOWN_DURATION);
        time2 = bound(time2, 0, FULL_MARKDOWN_DURATION);

        // Ensure time2 > time1
        if (time2 <= time1) {
            (time1, time2) = (time2, time1);
        }
        if (time1 == time2) {
            time2 = time1 + 1;
        }

        uint256 markdown1 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, time1);
        uint256 markdown2 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, time2);

        // Property: markdown increases monotonically with time
        assertGe(markdown2, markdown1, "Markdown should increase with time");

        // Property: rate of increase is linear (within rounding)
        if (time2 < FULL_MARKDOWN_DURATION && time1 < FULL_MARKDOWN_DURATION) {
            uint256 expectedDiff = (borrowAmount * (time2 - time1)) / FULL_MARKDOWN_DURATION;
            uint256 actualDiff = markdown2 - markdown1;

            // Allow 1 wei difference for rounding
            assertApproxEqAbs(actualDiff, expectedDiff, 1, "Markdown should increase linearly");
        }
    }

    /// @notice Fuzz test: markdown calculation is deterministic
    function testFuzz_MarkdownDeterministic(uint256 borrowAmount, uint256 timeInDefault) public {
        // Bound inputs
        borrowAmount = bound(borrowAmount, 0, type(uint128).max);
        timeInDefault = bound(timeInDefault, 0, 365 days);

        uint256 markdown1 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);
        uint256 markdown2 = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);

        // Property: same inputs always produce same output
        assertEq(markdown1, markdown2, "Markdown calculation should be deterministic");
    }

    /// @notice Fuzz test: disabled borrowers always have zero markdown
    function testFuzz_DisabledBorrowerZeroMarkdown(address borrower, uint256 borrowAmount, uint256 timeInDefault)
        public
    {
        // Don't test with the enabled BORROWER
        vm.assume(borrower != BORROWER);

        // Bound inputs
        borrowAmount = bound(borrowAmount, 0, type(uint128).max);
        timeInDefault = bound(timeInDefault, 0, 365 days);

        // Ensure borrower is not enabled
        assertFalse(markdownManager.markdownEnabled(borrower), "Borrower should not be enabled");

        uint256 markdown = markdownManager.calculateMarkdown(borrower, borrowAmount, timeInDefault);

        // Property: disabled borrowers always have zero markdown
        assertEq(markdown, 0, "Disabled borrowers should have zero markdown");
    }

    /// @notice Fuzz test: markdown proportionality
    function testFuzz_MarkdownProportionality(uint256 amount1, uint256 amount2, uint256 timeInDefault) public {
        // Bound inputs
        amount1 = bound(amount1, 1e18, 100_000e18);
        amount2 = bound(amount2, 1e18, 100_000e18);
        timeInDefault = bound(timeInDefault, 1, FULL_MARKDOWN_DURATION - 1);

        uint256 markdown1 = markdownManager.calculateMarkdown(BORROWER, amount1, timeInDefault);
        uint256 markdown2 = markdownManager.calculateMarkdown(BORROWER, amount2, timeInDefault);

        // Property: markdown is proportional to borrow amount
        // markdown1 / amount1 ≈ markdown2 / amount2
        // Cross multiply to avoid division: markdown1 * amount2 ≈ markdown2 * amount1

        uint256 product1 = markdown1 * amount2;
        uint256 product2 = markdown2 * amount1;

        // Allow small difference for rounding (0.01%)
        uint256 tolerance = (product1 > product2 ? product1 : product2) / 10000;
        assertApproxEqAbs(product1, product2, tolerance, "Markdown should be proportional to amount");
    }

    /// @notice Fuzz test: extreme values handling
    function testFuzz_ExtremeValues() public {
        // Test with 0
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, 0, 1000 days);
        assertEq(markdown, 0, "Zero borrow should have zero markdown");

        // Test with max uint256 (should not overflow)
        markdown = markdownManager.calculateMarkdown(BORROWER, type(uint256).max, 1 seconds);
        assertLe(markdown, type(uint256).max, "Should handle max uint256");

        // Test with max time
        markdown = markdownManager.calculateMarkdown(BORROWER, 1e18, type(uint256).max);
        assertEq(markdown, 1e18, "Max time should cap at 100% markdown");
    }

    /// @notice Fuzz test: markdown in actual borrowing scenario
    function testFuzz_MarkdownInBorrowingScenario(uint256 borrowAmount, uint256 defaultDelay) public {
        // Bound inputs
        borrowAmount = bound(borrowAmount, 1000e18, 100_000e18);
        defaultDelay = bound(defaultDelay, 1 days, 100 days);

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Create past obligation
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Move to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + defaultDelay);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get markdown through actual system
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);

        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);

            // Property: markdown in real scenario follows same rules
            assertLe(markdown, borrowAssets, "Markdown should not exceed actual borrow assets");

            // Property: market tracks markdown correctly
            uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
            assertEq(totalMarkdown, markdown, "Market should track individual markdown");
        }
    }

    /// @notice Fuzz test: custom markdown override
    function testFuzz_CustomMarkdownOverride(uint256 borrowAmount, uint256 timeInDefault, uint256 customMarkdown)
        public
    {
        // Bound inputs
        borrowAmount = bound(borrowAmount, 1e18, 100_000e18);
        timeInDefault = bound(timeInDefault, 0, 365 days);
        customMarkdown = bound(customMarkdown, 0, borrowAmount * 2);

        // Set custom markdown
        vm.prank(OWNER);
        markdownManager.setCustomMarkdown(BORROWER, customMarkdown);

        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAmount, timeInDefault);

        // Property: custom markdown overrides calculation but caps at borrowAmount
        uint256 expected;
        if (customMarkdown == 0) {
            // When custom markdown is 0, it's not considered "set", so falls back to regular calculation
            uint256 duration = 70 days; // FULL_MARKDOWN_DURATION
            if (timeInDefault >= duration) {
                expected = borrowAmount;
            } else {
                expected = (borrowAmount * timeInDefault) / duration;
            }
        } else {
            expected = customMarkdown > borrowAmount ? borrowAmount : customMarkdown;
        }
        assertEq(markdown, expected, "Custom markdown should override but cap at borrow amount");
    }
}
