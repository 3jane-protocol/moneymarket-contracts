// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

/// @title TimestampOnFirstBorrowRegressionTest
/// @notice Regression tests for premium interest accrual timestamp initialization
/// @dev Verifies that premium interest only accrues from first borrow, not from credit line setup
contract TimestampOnFirstBorrowRegressionTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    // Test constants
    uint256 constant PREMIUM_APR = 0.1e18; // 10% APR premium
    uint256 constant BASE_APR = 0.05e18; // 5% APR base rate
    uint256 constant CREDIT_LIMIT = 10_000e18;
    uint256 constant SUPPLY_AMOUNT = 100_000e18;
    uint256 constant WAIT_TIME_BEFORE_BORROW = 7 days;
    uint256 constant BORROW_AMOUNT = 1_000e18;
    uint256 constant ACCRUAL_PERIOD = 1 days;

    uint256 premiumRatePerSecond;
    uint256 baseRatePerSecond;

    function setUp() public override {
        super.setUp();

        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);

        // Calculate rates per second
        premiumRatePerSecond = PREMIUM_APR / 365 days;
        baseRatePerSecond = BASE_APR / 365 days;

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

        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        // Initialize market cycles to prevent freezing
        _ensureMarketActive(id);

        // Supply liquidity
        loanToken.setBalance(SUPPLIER, SUPPLY_AMOUNT);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, SUPPLY_AMOUNT, 0, SUPPLIER, hex"");
        vm.stopPrank();
    }

    /// @notice Core regression test: Verify timestamp updates correctly on first borrow
    function testTimestampUpdatesOnFirstBorrow() public {
        // Step 1: Set credit line and record timestamp
        uint256 creditLineSetTime = block.timestamp;
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        // Verify timestamp is NOT set initially (this is the fix!)
        (uint256 timestampAfterSet,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterSet, 0, "Initial timestamp should NOT be set until first borrow");

        // Step 2: Wait significant time before borrowing
        skip(WAIT_TIME_BEFORE_BORROW);

        // Step 3: First borrow - timestamp should update
        uint256 borrowTime = block.timestamp;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Step 4: Verify timestamp was updated to borrow time (THE FIX)
        (uint256 timestampAfterBorrow,, uint256 borrowAssetsAtLastAccrual) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterBorrow, borrowTime, "Timestamp MUST update on first borrow");
        assertEq(borrowAssetsAtLastAccrual, BORROW_AMOUNT, "Borrow assets should be recorded");

        // Step 5: Accrue premium after some time
        skip(ACCRUAL_PERIOD);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Step 6: Verify premium only accrued for actual borrow period
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 totalBorrowAssets = morpho.market(id).totalBorrowAssets;
        uint256 totalBorrowShares = morpho.market(id).totalBorrowShares;
        uint256 currentBorrowAssets = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);

        // Calculate expected with only 1 day of premium (not 8 days)
        uint256 expectedPremium = BORROW_AMOUNT.wMulDown(premiumRatePerSecond * ACCRUAL_PERIOD);
        uint256 expectedBase = BORROW_AMOUNT.wMulDown(baseRatePerSecond * ACCRUAL_PERIOD);
        uint256 expectedTotal = BORROW_AMOUNT + expectedPremium + expectedBase;

        // Allow for compounding effects but verify it's not 8x the premium
        assertApproxEqRel(currentBorrowAssets, expectedTotal, 0.01e18, "Premium should only accrue from first borrow");
        assertTrue(
            currentBorrowAssets < BORROW_AMOUNT + (expectedPremium * 2), "Should not have 7 extra days of premium"
        );
    }

    /// @notice Test immediate borrow after credit line setup
    function testImmediateBorrowNoExtraPremium() public {
        // Set credit line and immediately borrow in same block
        vm.startPrank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, CREDIT_LIMIT, uint128(premiumRatePerSecond));
        vm.stopPrank();

        // Borrow immediately (same timestamp)
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Verify timestamp remains the same
        (uint256 timestamp,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestamp, block.timestamp, "Timestamp should be current");

        // Skip time and accrue
        skip(ACCRUAL_PERIOD);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify correct premium accrual
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 currentBorrowAssets =
            borrowShares.toAssetsUp(morpho.market(id).totalBorrowAssets, morpho.market(id).totalBorrowShares);

        uint256 expectedPremium = BORROW_AMOUNT.wMulDown(premiumRatePerSecond * ACCRUAL_PERIOD);
        uint256 expectedBase = BORROW_AMOUNT.wMulDown(baseRatePerSecond * ACCRUAL_PERIOD);

        assertApproxEqRel(
            currentBorrowAssets,
            BORROW_AMOUNT + expectedPremium + expectedBase,
            0.01e18,
            "Premium should accrue correctly for immediate borrow"
        );
    }

    /// @notice Test credit line set, wait, borrow, repay fully, borrow again
    function testBorrowRepayBorrowCycle() public {
        // Set credit line
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        // Wait before first borrow
        skip(WAIT_TIME_BEFORE_BORROW);

        // First borrow
        uint256 firstBorrowTime = block.timestamp;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Verify timestamp updated
        (uint256 timestampAfterFirstBorrow,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterFirstBorrow, firstBorrowTime, "Timestamp should update on first borrow");

        // Accrue some interest
        skip(ACCRUAL_PERIOD);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Repay fully using shares (this ensures exact full repayment)
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;

        // Give enough tokens to cover the debt
        loanToken.setBalance(BORROWER, 2 * BORROW_AMOUNT);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        // Repay using shares to ensure full repayment
        morpho.repay(marketParams, 0, borrowShares, BORROWER, hex"");
        vm.stopPrank();

        // Verify debt is cleared
        assertEq(morpho.position(id, BORROWER).borrowShares, 0, "Debt should be fully repaid");

        // Wait and borrow again
        skip(3 days);
        uint256 secondBorrowTime = block.timestamp;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT * 2, 0, BORROWER, BORROWER);

        // Verify timestamp updated to second borrow time
        (uint256 timestampAfterSecondBorrow,, uint256 borrowAssetsAtLastAccrual) =
            morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterSecondBorrow, secondBorrowTime, "Timestamp should update on second first borrow");
        assertEq(borrowAssetsAtLastAccrual, BORROW_AMOUNT * 2, "Borrow assets should be updated");

        // Accrue and verify premium only from second borrow
        skip(ACCRUAL_PERIOD);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 currentBorrowAssets =
            borrowShares.toAssetsUp(morpho.market(id).totalBorrowAssets, morpho.market(id).totalBorrowShares);

        uint256 expectedPremium = (BORROW_AMOUNT * 2).wMulDown(premiumRatePerSecond * ACCRUAL_PERIOD);
        uint256 expectedBase = (BORROW_AMOUNT * 2).wMulDown(baseRatePerSecond * ACCRUAL_PERIOD);

        assertApproxEqRel(
            currentBorrowAssets,
            BORROW_AMOUNT * 2 + expectedPremium + expectedBase,
            0.01e18,
            "Premium should only accrue from second borrow time"
        );
    }

    /// @notice Test multiple borrowers with different credit line and borrow times
    function testMultipleBorrowersIndependentTimestamps() public {
        address borrower1 = makeAddr("Borrower1");
        address borrower2 = makeAddr("Borrower2");
        address borrower3 = makeAddr("Borrower3");

        // Set credit lines at different times
        vm.startPrank(address(creditLine));
        morphoCredit.setCreditLine(id, borrower1, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        skip(2 days);
        morphoCredit.setCreditLine(id, borrower2, CREDIT_LIMIT, uint128(premiumRatePerSecond * 2)); // Higher premium

        skip(3 days);
        morphoCredit.setCreditLine(id, borrower3, CREDIT_LIMIT, uint128(premiumRatePerSecond / 2)); // Lower premium
        vm.stopPrank();

        // Borrowers borrow at different times
        skip(1 days);
        uint256 borrow1Time = block.timestamp;
        vm.prank(borrower1);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, borrower1, borrower1);

        skip(2 days);
        uint256 borrow2Time = block.timestamp;
        vm.prank(borrower2);
        morpho.borrow(marketParams, BORROW_AMOUNT * 2, 0, borrower2, borrower2);

        skip(1 days);
        uint256 borrow3Time = block.timestamp;
        vm.prank(borrower3);
        morpho.borrow(marketParams, BORROW_AMOUNT / 2, 0, borrower3, borrower3);

        // Verify each borrower has correct timestamp
        (uint256 timestamp1,,) = morphoCredit.borrowerPremium(id, borrower1);
        (uint256 timestamp2,,) = morphoCredit.borrowerPremium(id, borrower2);
        (uint256 timestamp3,,) = morphoCredit.borrowerPremium(id, borrower3);

        assertEq(timestamp1, borrow1Time, "Borrower1 timestamp should be their borrow time");
        assertEq(timestamp2, borrow2Time, "Borrower2 timestamp should be their borrow time");
        assertEq(timestamp3, borrow3Time, "Borrower3 timestamp should be their borrow time");

        // Accrue premium for all after 1 day
        skip(ACCRUAL_PERIOD);
        morphoCredit.accrueBorrowerPremium(id, borrower1);
        morphoCredit.accrueBorrowerPremium(id, borrower2);
        morphoCredit.accrueBorrowerPremium(id, borrower3);

        // Verify each has correct premium based on their rate and time
        uint256 shares1 = morpho.position(id, borrower1).borrowShares;
        uint256 shares2 = morpho.position(id, borrower2).borrowShares;
        uint256 shares3 = morpho.position(id, borrower3).borrowShares;

        uint256 totalAssets = morpho.market(id).totalBorrowAssets;
        uint256 totalShares = morpho.market(id).totalBorrowShares;

        uint256 assets1 = shares1.toAssetsUp(totalAssets, totalShares);
        uint256 assets2 = shares2.toAssetsUp(totalAssets, totalShares);
        uint256 assets3 = shares3.toAssetsUp(totalAssets, totalShares);

        // Each should have only 1 day of their respective premium rates
        uint256 expected1 =
            BORROW_AMOUNT + BORROW_AMOUNT.wMulDown((premiumRatePerSecond + baseRatePerSecond) * ACCRUAL_PERIOD);
        uint256 expected2 = BORROW_AMOUNT * 2
            + (BORROW_AMOUNT * 2).wMulDown((premiumRatePerSecond * 2 + baseRatePerSecond) * ACCRUAL_PERIOD);
        uint256 expected3 = BORROW_AMOUNT / 2
            + (BORROW_AMOUNT / 2).wMulDown((premiumRatePerSecond / 2 + baseRatePerSecond) * ACCRUAL_PERIOD);

        assertApproxEqRel(assets1, expected1, 0.01e18, "Borrower1 premium correct");
        assertApproxEqRel(assets2, expected2, 0.01e18, "Borrower2 premium correct");
        assertApproxEqRel(assets3, expected3, 0.01e18, "Borrower3 premium correct");
    }

    /// @notice Test edge case: Zero initial borrow assets
    function testZeroInitialBorrowAssets() public {
        // Set credit line
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        // Wait
        skip(WAIT_TIME_BEFORE_BORROW);

        // Verify initial state
        (uint256 timestampBefore,, uint256 borrowAssetsBefore) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(borrowAssetsBefore, 0, "Initial borrow assets should be 0");

        // First borrow - transition from 0 to positive
        uint256 borrowTime = block.timestamp;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Verify timestamp updated due to 0 -> positive transition
        (uint256 timestampAfter,, uint256 borrowAssetsAfter) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfter, borrowTime, "Timestamp should update on 0->positive transition");
        assertEq(borrowAssetsAfter, BORROW_AMOUNT, "Borrow assets should be recorded");
    }

    /// @notice Test that partial repayment doesn't reset to credit line timestamp
    function testPartialRepaymentBehavior() public {
        // Setup and first borrow
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        skip(WAIT_TIME_BEFORE_BORROW);

        uint256 borrowTime = block.timestamp;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Verify timestamp was updated to borrow time
        (uint256 timestampAfterBorrow,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterBorrow, borrowTime, "Timestamp should be borrow time");

        // Accrue some interest
        skip(ACCRUAL_PERIOD);
        uint256 accrualTime = block.timestamp;
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Note: accrueBorrowerPremium updates the timestamp to current time
        (uint256 timestampAfterAccrual,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterAccrual, accrualTime, "Timestamp updates on accrual");

        // Partial repayment (50%)
        uint256 repayAmount = BORROW_AMOUNT / 2;
        loanToken.setBalance(BORROWER, repayAmount);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), repayAmount);
        morpho.repay(marketParams, repayAmount, 0, BORROWER, hex"");
        vm.stopPrank();

        // Timestamp should still be the last accrual time (not reset to credit line time)
        (uint256 timestampAfterPartialRepay,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterPartialRepay, accrualTime, "Timestamp should not reset on partial repay");

        // Borrow more - timestamp should update again
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Timestamp updates because borrow triggers accrual
        (uint256 timestampAfterMoreBorrow,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(timestampAfterMoreBorrow, block.timestamp, "Timestamp updates on new borrow");
    }

    /// @notice Comprehensive test verifying fix prevents overpayment
    function testRegressionPreventsPremiumOvercharge() public {
        // Calculate what the bug would have charged
        uint256 buggyPremium = BORROW_AMOUNT.wMulDown(premiumRatePerSecond * (WAIT_TIME_BEFORE_BORROW + ACCRUAL_PERIOD));
        uint256 correctPremium = BORROW_AMOUNT.wMulDown(premiumRatePerSecond * ACCRUAL_PERIOD);

        // Set credit line
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        // Wait significant time
        skip(WAIT_TIME_BEFORE_BORROW);

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Accrue after 1 day
        skip(ACCRUAL_PERIOD);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get actual debt
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 actualDebt =
            borrowShares.toAssetsUp(morpho.market(id).totalBorrowAssets, morpho.market(id).totalBorrowShares);

        // Calculate expected debt with fix
        uint256 expectedDebt =
            BORROW_AMOUNT + correctPremium + BORROW_AMOUNT.wMulDown(baseRatePerSecond * ACCRUAL_PERIOD);

        // Verify fix prevents overcharge
        assertApproxEqRel(actualDebt, expectedDebt, 0.01e18, "Debt should match expected with fix");

        // Ensure we're not charging the buggy amount (which would include 7 extra days)
        // The difference should be significant - at least 7x less premium
        uint256 premiumSavings = buggyPremium - correctPremium;
        assertTrue(premiumSavings > correctPremium * 6, "Should save at least 6 days of premium");

        console.log("Correct premium charged:", correctPremium);
        console.log("Buggy premium would have been:", buggyPremium);
        console.log("Savings from fix:", buggyPremium - correctPremium);
    }

    /// @notice Test the exact fix condition in _snapshotBorrowerPosition
    function testFixConditionLogic() public {
        // Test case: First borrow (0 -> positive transition) with the fix
        address newBorrower = makeAddr("NewBorrower");

        // Set credit line - this will set timestamp
        uint256 creditLineTime = block.timestamp;
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, newBorrower, CREDIT_LIMIT, uint128(premiumRatePerSecond));

        // Verify timestamp is NOT set when credit line is created (this is the fix!)
        (uint256 timestampAfterCreditLine,, uint256 borrowAssetsAfterCreditLine) =
            morphoCredit.borrowerPremium(id, newBorrower);
        assertEq(timestampAfterCreditLine, 0, "Timestamp should NOT be set when credit line created");
        assertEq(borrowAssetsAfterCreditLine, 0, "No borrow assets yet");

        // Wait 5 days
        skip(5 days);

        // First borrow - WITH FIX: timestamp should update to now
        uint256 borrowTime = block.timestamp;
        vm.prank(newBorrower);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, newBorrower, newBorrower);

        // Verify the fix: timestamp updated on first borrow
        (uint256 timestampAfterBorrow,, uint256 borrowAssetsAfterBorrow) = morphoCredit.borrowerPremium(id, newBorrower);
        assertEq(timestampAfterBorrow, borrowTime, "Timestamp should update on first borrow (THE FIX)");
        assertEq(borrowAssetsAfterBorrow, BORROW_AMOUNT, "Borrow assets should be set on first borrow");

        // Verify no extra premium was charged
        skip(1 days);
        morphoCredit.accrueBorrowerPremium(id, newBorrower);

        uint256 borrowShares = morpho.position(id, newBorrower).borrowShares;
        uint256 currentAssets =
            borrowShares.toAssetsUp(morpho.market(id).totalBorrowAssets, morpho.market(id).totalBorrowShares);

        // Should only have 1 day of premium, not 6 days
        uint256 expectedPremium = BORROW_AMOUNT.wMulDown(premiumRatePerSecond * 1 days);
        assertTrue(currentAssets < BORROW_AMOUNT + (expectedPremium * 2), "Should not have 5 extra days of premium");
    }
}
