// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";

/// @title CallableCreditEdgeCasesTest
/// @notice Edge case tests for CallableCredit to cover boundary conditions
contract CallableCreditEdgeCasesTest is CallableCreditBaseTest {
    using SharesMathLib for uint256;

    // ============ Minimum Amount Edge Cases ============

    function testOpenMinimumAmount() public {
        uint256 minAmount = 1e6; // 1 USDC
        _setupBorrowerWithCreditLine(BORROWER_1, minAmount * 10);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, minAmount);

        uint256 shares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(shares, 0, "Should have shares for minimum amount");

        // Verify can close
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        assertEq(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1), 0, "Should close successfully");
    }

    function testDrawMinimumAmount() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 minDraw = 1e6; // 1 USDC

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, minDraw, RECIPIENT);

        assertGe(usdcSent + waUsdcSent, minDraw - 1, "Should draw minimum amount");
    }

    function testPartialCloseMinimumAmount() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 minClose = 1e6; // 1 USDC

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, minClose);

        // Should still have position
        uint256 shares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(shares, 0, "Should have remaining shares");
    }

    // ============ Maximum Amount Edge Cases ============

    function testOpenAtExactCreditLine() public {
        uint256 creditLine = 1_000_000e6;
        _setupBorrowerWithCreditLine(BORROWER_1, creditLine);

        // Set borrower cap to 100% (unlimited)
        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_CREDIT_LINE_BPS, 10000);

        // Supply more liquidity
        _supplyLiquidity(creditLine * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, creditLine);

        (uint128 totalPrincipal,,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalPrincipal, creditLine, "Should open at exact credit line");
    }

    function testDrawEntirePrincipal() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT, RECIPIENT);

        // Position should be empty
        (uint128 totalPrincipal, uint128 totalShares,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalPrincipal, 0, "Principal should be zero after full draw");
        assertEq(totalShares, 0, "Shares should be zero after full draw");
    }

    // ============ Rounding Edge Cases ============

    function testShareRoundingOnMultipleOpens() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // Open with slightly different amounts that may cause rounding
        uint256 amount1 = 123_456_789; // Odd amount
        uint256 amount2 = 987_654_321; // Different odd amount

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, amount1);
        callableCredit.open(BORROWER_2, amount2);
        vm.stopPrank();

        // Sum of principals should equal total
        (uint128 totalPrincipal, uint128 totalShares,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalPrincipal, amount1 + amount2, "Total principal should equal sum");

        // Sum of derived principals should approximately equal total
        uint256 derived1 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 derived2 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);
        assertApproxEqAbs(derived1 + derived2, totalPrincipal, 2, "Derived principals should sum to total");
    }

    function testShareRoundingOnPartialClose() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Close an odd amount that may cause rounding
        uint256 closeAmount = DEFAULT_OPEN_AMOUNT / 3; // Not evenly divisible

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, closeAmount);

        uint256 remainingShares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(remainingShares, 0, "Should have remaining shares");

        // Full close should still work
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        assertEq(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1), 0, "Should fully close");
    }

    // ============ Pro-Rata Draw Edge Cases ============

    function testProRataDrawDoesNotAffectOtherSilos() public {
        _authorizeCounterProtocol(COUNTER_PROTOCOL_2);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Open in both silos
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);
        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint128 silo1PrincipalBefore,,) = callableCredit.silos(COUNTER_PROTOCOL);
        (uint128 silo2PrincipalBefore,,) = callableCredit.silos(COUNTER_PROTOCOL_2);

        // Pro-rata draw from silo 1
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        (uint128 silo1PrincipalAfter,,) = callableCredit.silos(COUNTER_PROTOCOL);
        (uint128 silo2PrincipalAfter,,) = callableCredit.silos(COUNTER_PROTOCOL_2);

        assertLt(silo1PrincipalAfter, silo1PrincipalBefore, "Silo 1 should decrease");
        assertEq(silo2PrincipalAfter, silo2PrincipalBefore, "Silo 2 should be unchanged");
    }

    function testProRataDrawWithSingleBorrower() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        // Pro-rata draw with single borrower
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        // Shares should be unchanged (pro-rata doesn't burn shares)
        assertEq(sharesAfter, sharesBefore, "Shares should be unchanged");
    }

    // ============ Exchange Rate Edge Cases ============

    function testOpenAtHighExchangeRate() public {
        // 50% appreciation
        _setExchangeRate(1.5e18);

        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint128 totalPrincipal,, uint128 totalWaUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);

        // Principal should be exact
        assertEq(totalPrincipal, DEFAULT_OPEN_AMOUNT, "Principal should match");

        // waUSDC should be less due to appreciation
        uint256 expectedWaUsdc = wausdc.previewWithdraw(DEFAULT_OPEN_AMOUNT);
        assertEq(totalWaUsdcHeld, expectedWaUsdc, "waUSDC should be adjusted");
        assertLt(totalWaUsdcHeld, DEFAULT_OPEN_AMOUNT, "waUSDC should be less than principal");
    }

    function testDrawAfterExchangeRateChange() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Simulate appreciation after open
        _setExchangeRate(1.2e18);

        // Draw should still work
        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        assertGe(usdcSent + waUsdcSent, DEFAULT_OPEN_AMOUNT / 2 - 1, "Should receive requested amount");
    }

    // ============ Zero Balance Edge Cases ============

    function testCloseWhenMorphoDebtIsZero() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Fully repay to MorphoCredit directly
        uint256 debt = _getBorrowerDebt(BORROWER_1);
        _repayDirectToMorpho(BORROWER_1, debt);

        assertEq(_getBorrowerDebt(BORROWER_1), 0, "Debt should be zero");

        // Close should return full principal to borrower
        uint256 borrowerBalanceBefore = usdc.balanceOf(BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.close(BORROWER_1);

        uint256 borrowerBalanceAfter = usdc.balanceOf(BORROWER_1);

        assertGt(usdcSent + waUsdcSent, 0, "Should return excess");
        assertGe(borrowerBalanceAfter, borrowerBalanceBefore, "Balance should increase");
    }

    // ============ Sequential Operations Edge Cases ============

    function testOpenDrawCloseOpenAgain() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT * 2);

        // First cycle: open, draw, close
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        assertEq(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1), 0, "Should be closed");

        // Second cycle: open again
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 sharesSecondCycle = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(sharesSecondCycle, 0, "Should have shares in second cycle");

        // Clean up
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);
    }

    function testMultiplePartialClosesThenFullClose() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Multiple partial closes
        for (uint256 i = 0; i < 5; i++) {
            uint256 currentPrincipal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
            if (currentPrincipal < 1e6) break;

            uint256 closeAmount = currentPrincipal / 10;
            if (closeAmount == 0) closeAmount = 1e6;

            vm.prank(COUNTER_PROTOCOL);
            callableCredit.close(BORROWER_1, closeAmount);
        }

        // Full close remaining
        if (callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1) > 0) {
            vm.prank(COUNTER_PROTOCOL);
            callableCredit.close(BORROWER_1);
        }

        assertEq(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1), 0, "Should be fully closed");
    }

    // ============ Concurrent Multi-Borrower Edge Cases ============

    function testDrawFromOneBorrowerAffectsOnlyThatBorrower() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);
        vm.stopPrank();

        uint256 shares1Before = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2Before = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        // Draw only from borrower 1
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 shares1After = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2After = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        assertLt(shares1After, shares1Before, "Borrower 1 shares should decrease");
        assertEq(shares2After, shares2Before, "Borrower 2 shares should be unchanged");
    }

    // ============ Throttle Period Edge Cases ============

    function testOpenAtExactThrottlePeriodEnd() public {
        uint256 throttlePeriod = 1 days;
        uint256 throttleLimit = 500_000e6;

        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_THROTTLE_PERIOD, throttlePeriod);
        protocolConfig.setConfig(ProtocolConfigLib.CC_THROTTLE_LIMIT, throttleLimit);
        vm.stopPrank();

        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Use full throttle
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, throttleLimit);

        uint256 initialPeriodStart = callableCredit.throttlePeriodStart();

        // Warp to exact period end
        vm.warp(block.timestamp + throttlePeriod);

        // Should be able to open again (new period)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 newPeriodStart = callableCredit.throttlePeriodStart();
        assertGt(newPeriodStart, initialPeriodStart, "Period should reset");
    }

    // ============ Cap Boundary Edge Cases ============

    function testOpenAtExactGlobalCap() public {
        uint256 debtCap = 1_000_000e6;
        uint256 ccCapBps = 1000; // 10%
        uint256 maxCc = (debtCap * ccCapBps) / 10000; // 100k

        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, debtCap);
        protocolConfig.setConfig(ProtocolConfigLib.CC_DEBT_CAP_BPS, ccCapBps);
        vm.stopPrank();

        _setupBorrowerWithCreditLine(BORROWER_1, maxCc * 2);

        // Open at exact cap
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, maxCc);

        assertEq(callableCredit.totalCcWaUsdc(), maxCc, "Should be at exact cap");

        // Any more should fail
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 1e6);
    }

    function testOpenAtExactBorrowerCap() public {
        uint256 creditLine = 100_000e6;
        uint256 ccLineBps = 5000; // 50%
        uint256 maxBorrowerCc = (creditLine * ccLineBps) / 10000; // 50k

        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_CREDIT_LINE_BPS, ccLineBps);

        _setupBorrowerWithCreditLine(BORROWER_1, creditLine);

        // Open at exact borrower cap
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, maxBorrowerCc);

        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), maxBorrowerCc, "Should be at exact borrower cap");

        // Any more should fail
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(CallableCredit.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 1e6);
    }

    // ============ Dust Amount Handling ============

    function testCloseWithDustPrincipal() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Pro-rata draw almost everything, leaving dust
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT - 1, RECIPIENT);

        // Verify dust state
        (uint128 principalAfterDraw,,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(principalAfterDraw, 1, "Should have 1 wei principal");

        // Full close should handle dust correctly
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        (uint128 principalAfterClose, uint128 sharesAfterClose,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(principalAfterClose, 0, "Principal should be zero");
        assertEq(sharesAfterClose, 0, "Shares should be zero");
    }

    // ============ Appreciation Excess Handling ============

    /// @notice Full draw with appreciation should repay borrower's debt
    function testFullDrawWithAppreciationRepaysDebt() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);
        assertGt(debtBefore, 0, "Should have initial debt");

        // Simulate 10% appreciation
        _setExchangeRate(1.1e18);

        // Full draw - should repay some debt with excess waUSDC
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT, RECIPIENT);

        uint256 debtAfter = _getBorrowerDebt(BORROWER_1);
        assertLt(debtAfter, debtBefore, "Debt should be reduced by excess waUSDC");

        // Silo should be fully empty
        (uint128 principal, uint128 shares, uint128 waUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(principal, 0, "Principal should be zero");
        assertEq(shares, 0, "Shares should be zero");
        assertEq(waUsdcHeld, 0, "waUSDC held should be zero");

        // CC tracking should also be zero
        assertEq(callableCredit.totalCcWaUsdc(), 0, "Total CC tracking should be zero");
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 0, "Borrower CC tracking should be zero");
    }

    /// @notice Full draw with appreciation and zero debt should return excess to borrower
    function testFullDrawWithAppreciationReturnsExcessWhenNoDebt() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Repay all debt first
        uint256 debt = _getBorrowerDebt(BORROWER_1);
        _repayDirectToMorpho(BORROWER_1, debt);
        assertEq(_getBorrowerDebt(BORROWER_1), 0, "Debt should be zero");

        // Simulate 10% appreciation
        _setExchangeRate(1.1e18);

        uint256 borrowerBalanceBefore = usdc.balanceOf(BORROWER_1);

        // Full draw - excess should go to borrower
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT, RECIPIENT);

        uint256 borrowerBalanceAfter = usdc.balanceOf(BORROWER_1);
        assertGt(borrowerBalanceAfter, borrowerBalanceBefore, "Borrower should receive excess");

        // The excess should be approximately 10% of the USDC value
        uint256 received = borrowerBalanceAfter - borrowerBalanceBefore;
        // With 10% appreciation, the excess waUSDC (~9.1% of original) should be worth ~10% of USDC
        assertGt(received, DEFAULT_OPEN_AMOUNT / 20, "Should receive meaningful excess");
    }

    /// @notice Partial draw with appreciation should proportionally repay debt
    function testPartialDrawWithAppreciationRepaysDebt() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);

        // Simulate 10% appreciation
        _setExchangeRate(1.1e18);

        // Draw half the principal
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 debtAfter = _getBorrowerDebt(BORROWER_1);
        assertLt(debtAfter, debtBefore, "Debt should be reduced");

        // Borrower should still have shares for remaining position
        uint256 remainingShares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(remainingShares, 0, "Should have remaining shares");

        // Can still close remaining position
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);
        assertEq(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1), 0, "Should close fully");
    }

    /// @notice Draw without appreciation should not affect debt or return excess
    function testDrawWithoutAppreciationNoExcess() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);
        uint256 borrowerBalanceBefore = usdc.balanceOf(BORROWER_1);

        // No exchange rate change - stays at 1:1

        // Draw half the principal
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 debtAfter = _getBorrowerDebt(BORROWER_1);
        uint256 borrowerBalanceAfter = usdc.balanceOf(BORROWER_1);

        // Debt should be unchanged (or only slightly different due to interest accrual)
        assertApproxEqRel(debtAfter, debtBefore, 0.001e18, "Debt should be approximately unchanged");

        // Borrower should receive nothing (no excess)
        assertEq(borrowerBalanceAfter, borrowerBalanceBefore, "Borrower balance unchanged");
    }

    /// @notice Full draw with appreciation updates CC tracking correctly
    function testFullDrawWithAppreciationUpdatesTracking() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 totalCcBefore = callableCredit.totalCcWaUsdc();
        uint256 borrowerCcBefore = callableCredit.borrowerTotalCcWaUsdc(BORROWER_1);
        assertGt(totalCcBefore, 0, "Should have initial CC tracking");
        assertGt(borrowerCcBefore, 0, "Should have initial borrower CC tracking");

        // Simulate 10% appreciation
        _setExchangeRate(1.1e18);

        // Full draw
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT, RECIPIENT);

        // Tracking should be reduced to zero (full position unwound)
        assertEq(callableCredit.totalCcWaUsdc(), 0, "Total CC should be zero");
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 0, "Borrower CC should be zero");
    }

    /// @notice Multiple draws with appreciation should handle excess each time
    function testMultipleDrawsWithAppreciation() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);

        // Simulate 20% appreciation
        _setExchangeRate(1.2e18);

        // First draw: 25% of principal
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 4, RECIPIENT);

        uint256 debtAfterFirst = _getBorrowerDebt(BORROWER_1);
        assertLt(debtAfterFirst, debtBefore, "Debt should decrease after first draw");

        // Second draw: another 25% of principal
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 4, RECIPIENT);

        uint256 debtAfterSecond = _getBorrowerDebt(BORROWER_1);
        assertLt(debtAfterSecond, debtAfterFirst, "Debt should decrease after second draw");

        // Third draw: remaining 50%
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        // Position should be fully unwound
        (uint128 principal, uint128 shares, uint128 waUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(principal, 0, "Principal should be zero");
        assertEq(shares, 0, "Shares should be zero");
        assertEq(waUsdcHeld, 0, "waUSDC held should be zero");
    }

    // ============ Pro-Rata Draw Tracking ============

    /// @notice Pro-rata draw should update global CC tracking but not per-borrower
    function testProRataDrawUpdatesGlobalTrackingOnly() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_2, DEFAULT_OPEN_AMOUNT);

        uint256 totalCcBefore = callableCredit.totalCcWaUsdc();
        uint256 borrower1CcBefore = callableCredit.borrowerTotalCcWaUsdc(BORROWER_1);
        uint256 borrower2CcBefore = callableCredit.borrowerTotalCcWaUsdc(BORROWER_2);

        // Pro-rata draw half the silo
        uint256 drawAmount = DEFAULT_OPEN_AMOUNT;
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(drawAmount, RECIPIENT);

        uint256 totalCcAfter = callableCredit.totalCcWaUsdc();
        uint256 borrower1CcAfter = callableCredit.borrowerTotalCcWaUsdc(BORROWER_1);
        uint256 borrower2CcAfter = callableCredit.borrowerTotalCcWaUsdc(BORROWER_2);

        // Global tracking should decrease
        assertLt(totalCcAfter, totalCcBefore, "Global CC should decrease after pro-rata draw");

        // Per-borrower tracking should remain unchanged (origination-based upper bound)
        assertEq(borrower1CcAfter, borrower1CcBefore, "Borrower 1 CC should be unchanged");
        assertEq(borrower2CcAfter, borrower2CcBefore, "Borrower 2 CC should be unchanged");
    }

    /// @notice After pro-rata draw, new opens should succeed if global cap has room
    function testCanOpenAfterProRataDrawFreesGlobalCap() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // Open a position that uses most of the global cap
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 totalCcAfterOpen = callableCredit.totalCcWaUsdc();

        // Pro-rata draw reduces global tracking
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 totalCcAfterDraw = callableCredit.totalCcWaUsdc();
        assertLt(totalCcAfterDraw, totalCcAfterOpen, "Global CC should be lower after draw");

        // Should be able to open another position now that global cap has room
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT / 2);

        // Verify both positions exist
        assertGt(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1), 0, "Borrower 1 should have shares");
        assertGt(callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2), 0, "Borrower 2 should have shares");
    }
}
