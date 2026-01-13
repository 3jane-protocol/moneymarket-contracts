// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";

/// @title CallableCreditSharesTest
/// @notice Tests for share accounting accuracy
contract CallableCreditSharesTest is CallableCreditBaseTest {
    // ============ First Deposit Tests ============

    function testFirstDepositSharesCalculatedCorrectly() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint128 totalPrincipal, uint128 totalShares) = callableCredit.silos(COUNTER_PROTOCOL);

        // SharesMathLib uses virtual shares (1e6) and virtual assets (1) for inflation protection
        // For first deposit: shares = assets * (0 + 1e6) / (0 + 1) = assets * 1e6
        // So shares will be much larger than principal due to virtual shares
        assertGt(totalShares, 0, "Should have shares");
        assertGt(totalPrincipal, 0, "Should have principal");

        // Verify the principal can be retrieved correctly
        uint256 borrowerPrincipal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(borrowerPrincipal, totalPrincipal, "Borrower principal should match total");
    }

    function testSecondDepositSharePriceConsistent() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // First deposit
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint128 principalAfterFirst, uint128 sharesAfterFirst) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 sharePriceAfterFirst = (uint256(principalAfterFirst) * 1e18) / sharesAfterFirst;

        // Second deposit of same amount
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);

        (uint128 principalAfterSecond, uint128 sharesAfterSecond) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 sharePriceAfterSecond = (uint256(principalAfterSecond) * 1e18) / sharesAfterSecond;

        // Share price should remain consistent
        assertEq(sharePriceAfterSecond, sharePriceAfterFirst, "Share price should remain consistent");
    }

    // ============ Share Price After Pro-Rata Draw ============

    function testSharePriceDecreasesAfterProRataDraw() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint128 principalBefore, uint128 sharesBefore) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 sharePriceBefore = (uint256(principalBefore) * 1e18) / sharesBefore;

        // Pro-rata draw reduces principal but not shares
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        (uint128 principalAfter, uint128 sharesAfter) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 sharePriceAfter = (uint256(principalAfter) * 1e18) / sharesAfter;

        assertEq(sharesAfter, sharesBefore, "Shares should be unchanged after pro-rata draw");
        assertLt(sharePriceAfter, sharePriceBefore, "Share price should decrease after pro-rata draw");
    }

    function testSharePriceAfterMultipleProRataDraws() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (, uint128 sharesBeforeDraws) = callableCredit.silos(COUNTER_PROTOCOL);

        uint256 drawAmount = DEFAULT_OPEN_AMOUNT / 10;

        // Perform multiple pro-rata draws
        vm.startPrank(COUNTER_PROTOCOL);
        for (uint256 i = 0; i < 5; i++) {
            callableCredit.draw(drawAmount, RECIPIENT);
        }
        vm.stopPrank();

        (uint128 principalAfter, uint128 sharesAfter) = callableCredit.silos(COUNTER_PROTOCOL);

        // Principal should be reduced by 50%
        uint256 expectedPrincipal = DEFAULT_OPEN_AMOUNT / 2;
        assertApproxEqRel(principalAfter, expectedPrincipal, 0.01e18, "Principal should be ~50%");

        // Shares should be unchanged (pro-rata draw doesn't burn shares)
        assertEq(sharesAfter, sharesBeforeDraws, "Shares should be unchanged");
    }

    // ============ getBorrowerPrincipal Accuracy ============

    function testGetBorrowerPrincipalAccuracySingleBorrower() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 principal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);

        // Should be approximately equal to what was opened (in waUSDC terms)
        assertApproxEqRel(principal, DEFAULT_OPEN_AMOUNT, 0.01e18, "Principal should match opened amount");
    }

    function testGetBorrowerPrincipalAccuracyMultipleBorrowers() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT / 2);
        vm.stopPrank();

        uint256 principal1 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);

        // Principal 1 should be ~2x principal 2
        assertApproxEqRel(principal1, principal2 * 2, 0.01e18, "Principal 1 should be ~2x principal 2");
    }

    function testGetBorrowerPrincipalAfterProRataDraw() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);
        vm.stopPrank();

        uint256 principal1Before = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);

        // Pro-rata draw of 50% of total
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT, RECIPIENT);

        uint256 principal1After = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);

        // Each borrower's principal should decrease by ~50%
        assertApproxEqRel(principal1After, principal1Before / 2, 0.01e18, "Principal should decrease by ~50%");
    }

    function testGetBorrowerPrincipalReturnsZeroForNonExistent() public {
        uint256 principal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(principal, 0, "Non-existent borrower should have 0 principal");
    }

    // ============ Shares Consistency Tests ============

    function testSharesConsistentAcrossOpenDrawClose() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Open
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 sharesAfterOpen = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(sharesAfterOpen, 0, "Should have shares after open");

        // Targeted draw (burns shares)
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 4, RECIPIENT);

        uint256 sharesAfterDraw = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertLt(sharesAfterDraw, sharesAfterOpen, "Shares should decrease after targeted draw");
        assertGt(sharesAfterDraw, 0, "Should still have shares");

        // Close
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        uint256 sharesAfterClose = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfterClose, 0, "Should have 0 shares after close");
    }

    function testTotalSharesMatchBorrowerSharesSum() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT / 3);
        vm.stopPrank();

        (, uint128 totalShares) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 shares1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        assertEq(totalShares, shares1 + shares2, "Total shares should equal sum of borrower shares");
    }

    function testTotalSharesAfterPartialClose() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);
        vm.stopPrank();

        uint256 shares2 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        // Close borrower 1's position
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        (, uint128 totalSharesAfter) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 shares1After = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        assertEq(shares1After, 0, "Borrower 1 should have 0 shares");
        assertEq(totalSharesAfter, shares2, "Total shares should equal remaining borrower's shares");
    }

    // ============ Edge Cases ============

    function testSmallAmountShareCalculation() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Open with minimum amount
        uint256 smallAmount = 1e6; // 1 USDC

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, smallAmount);

        uint256 shares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);

        assertGt(shares, 0, "Should have shares even for small amount");
        assertGt(principal, 0, "Should have principal even for small amount");
    }

    function testLargeAmountShareCalculation() public {
        // Set up a large credit line
        uint256 largeAmount = 10_000_000e6; // 10M USDC
        _setupBorrowerWithCreditLine(BORROWER_1, largeAmount * 2);

        // Need more liquidity
        _supplyLiquidity(largeAmount * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, largeAmount);

        (uint128 totalPrincipal, uint128 totalShares) = callableCredit.silos(COUNTER_PROTOCOL);

        // Should handle large amounts without overflow
        assertGt(totalPrincipal, 0, "Should have principal");
        assertGt(totalShares, 0, "Should have shares");

        // Verify principal retrieval works correctly
        uint256 borrowerPrincipal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        assertApproxEqRel(borrowerPrincipal, largeAmount, 0.01e18, "Principal should match deposited amount");
    }
}
