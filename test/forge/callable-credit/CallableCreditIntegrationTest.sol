// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";

/// @title CallableCreditIntegrationTest
/// @notice Integration tests for CallableCredit open, close, and draw operations
contract CallableCreditIntegrationTest is CallableCreditBaseTest {
    // ============ Open Position Tests ============

    function testOpenSuccess() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 initialSupply = wausdc.balanceOf(address(callableCredit));

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Verify silo updated
        (uint128 totalPrincipal, uint128 totalShares) = callableCredit.silos(COUNTER_PROTOCOL);
        assertGt(totalPrincipal, 0, "Silo principal should be > 0");
        assertGt(totalShares, 0, "Silo shares should be > 0");

        // Verify borrower shares
        uint256 shares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(shares, totalShares, "Borrower should have all shares");

        // Verify CallableCredit received waUSDC
        uint256 finalSupply = wausdc.balanceOf(address(callableCredit));
        assertEq(finalSupply - initialSupply, totalPrincipal, "CallableCredit should hold the waUSDC");

        // Verify borrower has debt in MorphoCredit
        uint256 debt = _getBorrowerDebt(BORROWER_1);
        assertGt(debt, 0, "Borrower should have debt");
    }

    function testOpenRevertsZeroAmount() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.ZeroAmount.selector);
        callableCredit.open(BORROWER_1, 0);
    }

    function testOpenRevertsNoCreditLine() public {
        // BORROWER_1 has no credit line set up

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.NoCreditLine.selector);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    function testOpenMultipleTimesAccumulatesShares() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        uint256 sharesAfterFirst = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        uint256 sharesAfterSecond = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        vm.stopPrank();

        assertGt(sharesAfterSecond, sharesAfterFirst, "Shares should accumulate");
    }

    function testOpenMultipleBorrowersSeparateShares() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT / 2);
        vm.stopPrank();

        uint256 shares1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        assertGt(shares1, shares2, "Borrower 1 should have more shares");
        assertGt(shares2, 0, "Borrower 2 should have shares");
    }

    // ============ Close Position Tests ============

    function testCloseSuccess() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(sharesBefore, 0, "Should have shares before close");

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        // Verify shares cleared
        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfter, 0, "Shares should be cleared");

        // Verify debt repaid (should be 0 or near 0 if interest accrued)
        uint256 debtAfter = _getBorrowerDebt(BORROWER_1);
        assertEq(debtAfter, 0, "Debt should be fully repaid");
    }

    function testCloseRevertsNoPosition() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        // Don't open a position

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.NoPosition.selector);
        callableCredit.close(BORROWER_1);
    }

    function testCloseExcessWhenBorrowerRepaidDirectly() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Borrower repays half directly to MorphoCredit
        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);
        uint256 repayAmount = debtBefore / 2;
        _repayDirectToMorpho(BORROWER_1, repayAmount);

        uint256 borrowerUsdcBefore = usdc.balanceOf(BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.close(BORROWER_1);

        // Borrower should receive excess funds
        assertGt(usdcSent + waUsdcSent, 0, "Borrower should receive excess");

        uint256 borrowerUsdcAfter = usdc.balanceOf(BORROWER_1);
        assertGe(borrowerUsdcAfter, borrowerUsdcBefore, "Borrower USDC should increase or stay same");
    }

    function testCloseFullExcessWhenDebtIsZero() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Borrower repays ALL debt directly
        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);
        _repayDirectToMorpho(BORROWER_1, debtBefore);

        uint256 debtAfterRepay = _getBorrowerDebt(BORROWER_1);
        assertEq(debtAfterRepay, 0, "Debt should be zero after full repay");

        uint256 borrowerUsdcBefore = usdc.balanceOf(BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.close(BORROWER_1);

        // All principal should be returned as excess
        assertGt(usdcSent + waUsdcSent, 0, "Should receive full principal as excess");

        uint256 borrowerUsdcAfter = usdc.balanceOf(BORROWER_1);
        assertGt(borrowerUsdcAfter, borrowerUsdcBefore, "Borrower should receive USDC");
    }

    // ============ Targeted Draw Tests ============

    function testDrawSuccess() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 drawAmount = 10_000e6;
        uint256 recipientBalanceBefore = usdc.balanceOf(RECIPIENT);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        // Verify recipient received funds
        uint256 recipientBalanceAfter = usdc.balanceOf(RECIPIENT);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, usdcSent, "Recipient should receive USDC");
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Should send approximately requested amount");
    }

    function testDrawRevertsZeroAmount() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.ZeroAmount.selector);
        callableCredit.draw(BORROWER_1, 0, RECIPIENT);
    }

    function testDrawRevertsNoPosition() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        // Don't open a position

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.NoPosition.selector);
        callableCredit.draw(BORROWER_1, 10_000e6, RECIPIENT);
    }

    function testDrawRevertsInsufficientPrincipal() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Try to draw more than the position
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.InsufficientPrincipal.selector);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT * 2, RECIPIENT);
    }

    function testDrawBurnsSharesCorrectly() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertLt(sharesAfter, sharesBefore, "Shares should decrease after draw");
    }

    function testDrawPartialAmount() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 drawAmount = DEFAULT_OPEN_AMOUNT / 4;

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        // Should still have shares remaining
        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(sharesAfter, 0, "Should have shares remaining");

        // Can still close the position
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        uint256 sharesAfterClose = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfterClose, 0, "Shares should be zero after close");
    }

    // ============ Pro-Rata Draw Tests ============

    function testProRataDrawSuccess() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 drawAmount = 10_000e6;
        uint256 recipientBalanceBefore = usdc.balanceOf(RECIPIENT);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(drawAmount, RECIPIENT);

        uint256 recipientBalanceAfter = usdc.balanceOf(RECIPIENT);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, usdcSent, "Recipient should receive USDC");
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Should send approximately requested amount");
    }

    function testProRataDrawRevertsZeroAmount() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.ZeroAmount.selector);
        callableCredit.draw(0, RECIPIENT);
    }

    function testProRataDrawRevertsInsufficientPrincipal() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.InsufficientPrincipal.selector);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT * 2, RECIPIENT);
    }

    function testProRataDrawSharesUnchanged() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        // Pro-rata draw does NOT burn shares - it just reduces principal
        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfter, sharesBefore, "Shares should be unchanged after pro-rata draw");
    }

    function testProRataDrawReducesPrincipal() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint128 principalBefore,) = callableCredit.silos(COUNTER_PROTOCOL);

        uint256 drawAmount = DEFAULT_OPEN_AMOUNT / 4;
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(drawAmount, RECIPIENT);

        (uint128 principalAfter,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertLt(principalAfter, principalBefore, "Principal should decrease");
    }

    function testProRataDrawAffectsAllBorrowersProportionally() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);
        vm.stopPrank();

        uint256 principal1Before = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2Before = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);

        // Pro-rata draw of half the total
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT, RECIPIENT);

        uint256 principal1After = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2After = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);

        // Both should be reduced proportionally (approximately half)
        assertLt(principal1After, principal1Before, "Borrower 1 principal should decrease");
        assertLt(principal2After, principal2Before, "Borrower 2 principal should decrease");

        // The reduction should be proportional
        uint256 reduction1 = principal1Before - principal1After;
        uint256 reduction2 = principal2Before - principal2After;
        // Allow for small rounding differences
        assertApproxEqRel(reduction1, reduction2, 0.01e18, "Reductions should be approximately equal");
    }
}
