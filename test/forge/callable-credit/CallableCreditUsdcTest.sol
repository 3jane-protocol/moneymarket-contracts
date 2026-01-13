// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";

/// @title CallableCreditUsdcTest
/// @notice Tests for USDC/waUSDC conversion and maxRedeem handling
contract CallableCreditUsdcTest is CallableCreditBaseTest {
    // ============ Full Redemption Tests ============

    function testWithdrawFullRedemptionToUsdc() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // maxRedeem is unlimited by default, so all should come as USDC
        uint256 drawAmount = 10_000e6;

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        assertGt(usdcSent, 0, "Should send USDC");
        assertEq(waUsdcSent, 0, "Should not send waUSDC when full redemption possible");
        assertGe(usdcSent, drawAmount - 1, "Should send approximately requested amount");
    }

    // ============ Partial Redemption Tests ============

    function testWithdrawPartialRedemption() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Limit maxRedeem to half of what we'll draw
        uint256 drawAmount = 10_000e6;
        _setMaxRedeem(drawAmount / 2);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        assertGt(usdcSent, 0, "Should send some USDC");
        assertGt(waUsdcSent, 0, "Should send some waUSDC");
        // Total should equal approximately drawAmount
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Total should be approximately requested amount");
    }

    function testWithdrawZeroRedemption() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Set maxRedeem to 0 - no USDC can be redeemed from Aave
        _setMaxRedeem(0);

        uint256 drawAmount = 10_000e6;

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        assertEq(usdcSent, 0, "Should not send USDC when maxRedeem is 0");
        assertGt(waUsdcSent, 0, "Should send all as waUSDC");
    }

    // ============ Return Value Tests ============

    function testDrawReturnValuesCorrect() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 drawAmount = 10_000e6;
        uint256 recipientUsdcBefore = usdc.balanceOf(RECIPIENT);
        uint256 recipientWaUsdcBefore = wausdc.balanceOf(RECIPIENT);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        uint256 recipientUsdcAfter = usdc.balanceOf(RECIPIENT);
        uint256 recipientWaUsdcAfter = wausdc.balanceOf(RECIPIENT);

        assertEq(recipientUsdcAfter - recipientUsdcBefore, usdcSent, "Return value should match actual USDC sent");
        assertEq(
            recipientWaUsdcAfter - recipientWaUsdcBefore, waUsdcSent, "Return value should match actual waUSDC sent"
        );
    }

    function testCloseReturnValuesCorrect() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Repay all debt so close returns excess
        uint256 debt = _getBorrowerDebt(BORROWER_1);
        _repayDirectToMorpho(BORROWER_1, debt);

        uint256 borrowerUsdcBefore = usdc.balanceOf(BORROWER_1);
        uint256 borrowerWaUsdcBefore = wausdc.balanceOf(BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.close(BORROWER_1);

        uint256 borrowerUsdcAfter = usdc.balanceOf(BORROWER_1);
        uint256 borrowerWaUsdcAfter = wausdc.balanceOf(BORROWER_1);

        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, usdcSent, "Return value should match actual USDC sent");
        assertEq(borrowerWaUsdcAfter - borrowerWaUsdcBefore, waUsdcSent, "Return value should match actual waUSDC sent");
    }

    // ============ Pro-Rata Draw USDC Tests ============

    function testProRataDrawFullRedemption() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 drawAmount = 10_000e6;

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(drawAmount, RECIPIENT);

        assertGt(usdcSent, 0, "Should send USDC");
        assertEq(waUsdcSent, 0, "Should not send waUSDC when full redemption possible");
    }

    function testProRataDrawPartialRedemption() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        uint256 drawAmount = 10_000e6;
        _setMaxRedeem(drawAmount / 2);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(drawAmount, RECIPIENT);

        assertGt(usdcSent, 0, "Should send some USDC");
        assertGt(waUsdcSent, 0, "Should send some waUSDC");
    }

    // ============ Close With Limited Redemption ============

    function testClosePartialRedemption() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Repay all debt so close returns excess
        uint256 debt = _getBorrowerDebt(BORROWER_1);
        _repayDirectToMorpho(BORROWER_1, debt);

        // Limit how much can be redeemed
        _setMaxRedeem(DEFAULT_OPEN_AMOUNT / 4);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.close(BORROWER_1);

        assertGt(usdcSent, 0, "Should send some USDC");
        assertGt(waUsdcSent, 0, "Should send remaining as waUSDC");
    }

    // ============ Exchange Rate Tests ============

    function testDrawWithAppreciatedExchangeRate() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Simulate 10% waUSDC appreciation
        _setExchangeRate(1.1e18);

        uint256 drawAmount = 10_000e6;

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        // Should still receive approximately the requested USDC amount
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Should receive approximately requested amount");
    }

    function testOpenWithAppreciatedExchangeRate() public {
        // Set exchange rate to 1.1 USDC per waUSDC before opening
        _setExchangeRate(1.1e18);

        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // The waUSDC borrowed should be less than the USDC amount due to appreciation
        (uint128 totalPrincipal,) = callableCredit.silos(COUNTER_PROTOCOL);

        // With 1.1 exchange rate, 100,000 USDC should result in ~90,909 waUSDC
        uint256 expectedWaUsdc = (DEFAULT_OPEN_AMOUNT * 1e18) / 1.1e18;
        assertApproxEqRel(totalPrincipal, expectedWaUsdc, 0.01e18, "waUSDC should reflect exchange rate");
    }
}
