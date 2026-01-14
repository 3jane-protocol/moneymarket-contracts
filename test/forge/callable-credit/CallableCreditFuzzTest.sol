// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";

/// @title CallableCreditFuzzTest
/// @notice Fuzz tests for CallableCredit operations
contract CallableCreditFuzzTest is CallableCreditBaseTest {
    using SharesMathLib for uint256;

    uint256 constant MIN_OPEN_AMOUNT = 1e6; // 1 USDC
    uint256 constant MAX_OPEN_AMOUNT = 1_000_000e6; // 1M USDC

    function setUp() public override {
        super.setUp();
        // Supply additional liquidity for large fuzz tests
        _supplyLiquidity(100_000_000e6); // 100M USDC
    }

    // ============ Open Fuzz Tests ============

    /// @notice Fuzz test for open() with varying amounts
    function testFuzz_OpenWithVaryingAmounts(uint256 usdcAmount) public {
        usdcAmount = bound(usdcAmount, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT);

        _setupBorrowerWithCreditLine(BORROWER_1, usdcAmount * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, usdcAmount);

        // Verify silo state
        (uint128 totalPrincipal, uint128 totalShares, uint128 totalWaUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);

        assertEq(totalPrincipal, usdcAmount, "Principal should match opened amount");
        assertGt(totalShares, 0, "Should have shares");
        assertGt(totalWaUsdcHeld, 0, "Should have waUSDC held");

        // Verify borrower shares
        uint256 borrowerSharesAmount = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(borrowerSharesAmount, totalShares, "Borrower should have all shares");

        // Verify tracking
        assertEq(callableCredit.totalCcWaUsdc(), totalWaUsdcHeld, "Total CC waUSDC should match silo");
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), totalWaUsdcHeld, "Borrower CC waUSDC should match");
    }

    /// @notice Fuzz test for multiple opens by same borrower
    function testFuzz_MultipleOpensAccumulateShares(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT / 2);
        amount2 = bound(amount2, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT / 2);

        _setupBorrowerWithCreditLine(BORROWER_1, (amount1 + amount2) * 2);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, amount1);
        uint256 sharesAfterFirst = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        callableCredit.open(BORROWER_1, amount2);
        uint256 sharesAfterSecond = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        vm.stopPrank();

        assertGt(sharesAfterSecond, sharesAfterFirst, "Shares should accumulate");

        (uint128 totalPrincipal,,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalPrincipal, amount1 + amount2, "Total principal should equal sum");
    }

    /// @notice Fuzz test for open with origination fee
    function testFuzz_OpenWithOriginationFee(uint256 usdcAmount, uint256 feeBps) public {
        usdcAmount = bound(usdcAmount, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT);
        feeBps = bound(feeBps, 1, 1000); // 0.01% to 10%

        address feeRecipient = makeAddr("FeeRecipient");

        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS, feeBps);
        protocolConfig.setConfig(ProtocolConfigLib.CC_FEE_RECIPIENT, uint256(uint160(feeRecipient)));
        vm.stopPrank();

        _setupBorrowerWithCreditLine(BORROWER_1, usdcAmount * 2);

        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, usdcAmount);

        uint256 expectedFee = (usdcAmount * feeBps) / 10000;
        uint256 actualFee = usdc.balanceOf(feeRecipient) - recipientBalanceBefore;

        assertEq(actualFee, expectedFee, "Fee should match expected");

        // Principal should not include fee
        (uint128 totalPrincipal,,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalPrincipal, usdcAmount, "Principal should not include fee");
    }

    /// @notice Fuzz test for open with throttle
    function testFuzz_OpenRespectsThrottle(uint256 throttleLimit, uint256 openAmount) public {
        throttleLimit = bound(throttleLimit, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT);
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT, throttleLimit);

        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_THROTTLE_PERIOD, 1 days);
        protocolConfig.setConfig(ProtocolConfigLib.CC_THROTTLE_LIMIT, throttleLimit);
        vm.stopPrank();

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, openAmount);

        assertEq(callableCredit.throttlePeriodUsdc(), openAmount, "Throttle should track usage");
    }

    // ============ Close Fuzz Tests ============

    /// @notice Fuzz test for full close
    function testFuzz_FullClose(uint256 openAmount) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT);

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertGt(sharesBefore, 0, "Should have shares before close");

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfter, 0, "Should have no shares after close");

        // Verify tracking cleared
        assertEq(callableCredit.totalCcWaUsdc(), 0, "Total tracking should be zero");
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 0, "Borrower tracking should be zero");
    }

    /// @notice Fuzz test for partial close
    function testFuzz_PartialClose(uint256 openAmount, uint256 closeFraction) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT);
        closeFraction = bound(closeFraction, 1, 99); // 1-99%

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        uint256 closeAmount = (openAmount * closeFraction) / 100;
        if (closeAmount == 0) closeAmount = 1e6; // Minimum close

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        (uint128 principalBefore,,) = callableCredit.silos(COUNTER_PROTOCOL);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, closeAmount);

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        (uint128 principalAfter,,) = callableCredit.silos(COUNTER_PROTOCOL);

        assertLt(sharesAfter, sharesBefore, "Shares should decrease");
        assertLt(principalAfter, principalBefore, "Principal should decrease");

        // Verify remaining position is valid
        if (sharesAfter > 0) {
            assertGt(principalAfter, 0, "Principal should remain with shares");
        }
    }

    /// @notice Fuzz test for close when borrower repaid directly
    function testFuzz_CloseWithExcess(uint256 openAmount, uint256 repayFraction) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT / 10);
        repayFraction = bound(repayFraction, 10, 100); // 10-100% repaid directly

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        uint256 debtBefore = _getBorrowerDebt(BORROWER_1);
        uint256 repayAmount = (debtBefore * repayFraction) / 100;

        if (repayAmount > 0) {
            _repayDirectToMorpho(BORROWER_1, repayAmount);
        }

        uint256 borrowerUsdcBefore = usdc.balanceOf(BORROWER_1);
        uint256 borrowerWaUsdcBefore = wausdc.balanceOf(BORROWER_1);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.close(BORROWER_1);

        uint256 borrowerUsdcAfter = usdc.balanceOf(BORROWER_1);
        uint256 borrowerWaUsdcAfter = wausdc.balanceOf(BORROWER_1);

        // Verify return values match actual transfers
        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, usdcSent, "USDC sent should match");
        assertEq(borrowerWaUsdcAfter - borrowerWaUsdcBefore, waUsdcSent, "waUSDC sent should match");

        // If fully repaid, should receive excess
        if (repayFraction == 100) {
            assertGt(usdcSent + waUsdcSent, 0, "Should receive excess when fully repaid");
        }
    }

    // ============ Draw Fuzz Tests ============

    /// @notice Fuzz test for targeted draw
    function testFuzz_TargetedDraw(uint256 openAmount, uint256 drawFraction) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT);
        drawFraction = bound(drawFraction, 1, 99); // 1-99%

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        uint256 drawAmount = (openAmount * drawFraction) / 100;
        if (drawAmount == 0) drawAmount = 1e6;

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 recipientBalanceBefore = usdc.balanceOf(RECIPIENT);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);

        assertLt(sharesAfter, sharesBefore, "Shares should decrease after targeted draw");
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Should receive approximately requested amount");

        uint256 recipientBalanceAfter = usdc.balanceOf(RECIPIENT);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, usdcSent, "Recipient should receive USDC");
    }

    /// @notice Fuzz test for pro-rata draw
    function testFuzz_ProRataDraw(uint256 openAmount, uint256 drawFraction) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT);
        drawFraction = bound(drawFraction, 1, 99); // 1-99%

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        uint256 drawAmount = (openAmount * drawFraction) / 100;
        if (drawAmount == 0) drawAmount = 1e6;

        uint256 sharesBefore = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        (uint128 principalBefore,,) = callableCredit.silos(COUNTER_PROTOCOL);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(drawAmount, RECIPIENT);

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        (uint128 principalAfter,,) = callableCredit.silos(COUNTER_PROTOCOL);

        // Pro-rata draw does NOT burn shares
        assertEq(sharesAfter, sharesBefore, "Shares should be unchanged after pro-rata draw");
        assertLt(principalAfter, principalBefore, "Principal should decrease");
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Should receive approximately requested amount");
    }

    /// @notice Fuzz test for pro-rata draw affecting multiple borrowers proportionally
    function testFuzz_ProRataDrawAffectsBothBorrowers(uint256 amount1, uint256 amount2, uint256 drawFraction) public {
        amount1 = bound(amount1, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT / 2);
        amount2 = bound(amount2, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT / 2);
        drawFraction = bound(drawFraction, 10, 90);

        _setupBorrowerWithCreditLine(BORROWER_1, amount1 * 2);
        _setupBorrowerWithCreditLine(BORROWER_2, amount2 * 2);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, amount1);
        callableCredit.open(BORROWER_2, amount2);
        vm.stopPrank();

        uint256 principal1Before = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2Before = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);

        uint256 totalPrincipal = amount1 + amount2;
        uint256 drawAmount = (totalPrincipal * drawFraction) / 100;

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(drawAmount, RECIPIENT);

        uint256 principal1After = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2After = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);

        // Both principals should decrease proportionally
        assertLt(principal1After, principal1Before, "Borrower 1 principal should decrease");
        assertLt(principal2After, principal2Before, "Borrower 2 principal should decrease");

        // Reductions should be proportional to initial amounts
        uint256 reduction1 = principal1Before - principal1After;
        uint256 reduction2 = principal2Before - principal2After;

        // Allow for rounding errors
        if (amount1 == amount2) {
            assertApproxEqRel(reduction1, reduction2, 0.01e18, "Equal positions should reduce equally");
        }
    }

    // ============ Cap Fuzz Tests ============

    /// @notice Fuzz test for global CC cap enforcement
    function testFuzz_GlobalCcCapEnforcement(uint256 debtCap, uint256 ccCapBps, uint256 openAmount) public {
        debtCap = bound(debtCap, 100_000e6, 10_000_000e6);
        ccCapBps = bound(ccCapBps, 100, 9999); // 1% to 99.99%
        uint256 maxCc = (debtCap * ccCapBps) / 10000;
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT, maxCc);

        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, debtCap);
        protocolConfig.setConfig(ProtocolConfigLib.CC_DEBT_CAP_BPS, ccCapBps);
        vm.stopPrank();

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, openAmount);

        uint256 totalCcWaUsdc = callableCredit.totalCcWaUsdc();
        uint256 maxCcWaUsdc = (debtCap * ccCapBps) / 10000;

        assertLe(totalCcWaUsdc, maxCcWaUsdc, "Should not exceed global CC cap");
    }

    /// @notice Fuzz test for per-borrower CC cap enforcement
    function testFuzz_BorrowerCcCapEnforcement(uint256 creditLine, uint256 ccLineBps, uint256 openAmount) public {
        creditLine = bound(creditLine, 100_000e6, 10_000_000e6);
        ccLineBps = bound(ccLineBps, 100, 9999); // 1% to 99.99%
        uint256 maxBorrowerCc = (creditLine * ccLineBps) / 10000;
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT, maxBorrowerCc);

        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_CREDIT_LINE_BPS, ccLineBps);

        _setupBorrowerWithCreditLine(BORROWER_1, creditLine);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, openAmount);

        uint256 borrowerCcWaUsdc = callableCredit.borrowerTotalCcWaUsdc(BORROWER_1);
        uint256 maxBorrowerCcWaUsdc = (creditLine * ccLineBps) / 10000;

        assertLe(borrowerCcWaUsdc, maxBorrowerCcWaUsdc, "Should not exceed borrower CC cap");
    }

    // ============ Exchange Rate Fuzz Tests ============

    /// @notice Fuzz test for open with varying exchange rates
    function testFuzz_OpenWithExchangeRate(uint256 openAmount, uint256 exchangeRate) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT / 2);
        exchangeRate = bound(exchangeRate, 0.9e18, 1.5e18); // 0.9x to 1.5x

        _setExchangeRate(exchangeRate);
        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, openAmount);

        (uint128 totalPrincipal,, uint128 totalWaUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);

        // Principal should be exact USDC amount
        assertEq(totalPrincipal, openAmount, "Principal should be exact USDC");

        // waUSDC should be adjusted by exchange rate
        uint256 expectedWaUsdc = wausdc.previewWithdraw(openAmount);
        assertEq(totalWaUsdcHeld, expectedWaUsdc, "waUSDC should reflect exchange rate");
    }

    /// @notice Fuzz test for draw with varying exchange rates
    function testFuzz_DrawWithExchangeRate(uint256 openAmount, uint256 drawFraction, uint256 exchangeRate) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT / 2);
        drawFraction = bound(drawFraction, 10, 90);
        exchangeRate = bound(exchangeRate, 0.9e18, 1.5e18);

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        // Change exchange rate after open
        _setExchangeRate(exchangeRate);

        uint256 drawAmount = (openAmount * drawFraction) / 100;
        uint256 recipientBalanceBefore = usdc.balanceOf(RECIPIENT);

        vm.prank(COUNTER_PROTOCOL);
        (uint256 usdcSent, uint256 waUsdcSent) = callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        // Should receive approximately the requested USDC amount
        assertGe(usdcSent + waUsdcSent, drawAmount - 1, "Should receive approximately requested amount");
    }

    // ============ Share Math Edge Cases ============

    /// @notice Fuzz test for share calculation consistency
    function testFuzz_ShareMathConsistency(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT / 2);
        amount2 = bound(amount2, MIN_OPEN_AMOUNT, MAX_OPEN_AMOUNT / 2);

        _setupBorrowerWithCreditLine(BORROWER_1, amount1 * 2);
        _setupBorrowerWithCreditLine(BORROWER_2, amount2 * 2);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, amount1);
        callableCredit.open(BORROWER_2, amount2);
        vm.stopPrank();

        (, uint128 totalShares,) = callableCredit.silos(COUNTER_PROTOCOL);
        uint256 shares1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        // Total shares should equal sum of borrower shares
        assertEq(totalShares, shares1 + shares2, "Total shares should equal sum");

        // Principal retrievals should sum to total
        uint256 principal1 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);
        (uint128 totalPrincipal,,) = callableCredit.silos(COUNTER_PROTOCOL);

        // Allow for small rounding errors
        assertApproxEqAbs(principal1 + principal2, totalPrincipal, 2, "Principals should sum to total");
    }

    /// @notice Fuzz test for small amount share calculations
    function testFuzz_SmallAmountShares(uint256 smallAmount) public {
        smallAmount = bound(smallAmount, 1e6, 100e6); // 1 to 100 USDC

        _setupBorrowerWithCreditLine(BORROWER_1, smallAmount * 2);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, smallAmount);

        uint256 shares = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);

        assertGt(shares, 0, "Should have shares for small amount");
        assertGt(principal, 0, "Should have principal for small amount");
        assertApproxEqAbs(principal, smallAmount, 1, "Principal should match deposited");
    }

    // ============ Multi-Operation Fuzz Tests ============

    /// @notice Fuzz test for sequence of opens and partial closes
    function testFuzz_OpenCloseSequence(
        uint256 openAmount1,
        uint256 openAmount2,
        uint256 closeFraction1,
        uint256 closeFraction2
    ) public {
        openAmount1 = bound(openAmount1, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT / 4);
        openAmount2 = bound(openAmount2, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT / 4);
        // Limit fractions so total doesn't exceed 80% to leave room for final close
        closeFraction1 = bound(closeFraction1, 10, 35);
        closeFraction2 = bound(closeFraction2, 10, 35);

        _setupBorrowerWithCreditLine(BORROWER_1, (openAmount1 + openAmount2) * 2);

        // Open twice
        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, openAmount1);
        callableCredit.open(BORROWER_1, openAmount2);
        vm.stopPrank();

        uint256 totalOpened = openAmount1 + openAmount2;
        uint256 closeAmount1 = (totalOpened * closeFraction1) / 100;
        uint256 closeAmount2 = (totalOpened * closeFraction2) / 100;

        // First partial close
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, closeAmount1);

        uint256 sharesAfterFirst = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        // After first close, shares may or may not be zero depending on rounding
        if (sharesAfterFirst == 0) {
            // Position was fully closed by rounding up
            return;
        }
        assertGt(sharesAfterFirst, 0, "Should have shares after first partial close");

        // Get remaining principal for second close
        uint256 remainingPrincipal = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        if (closeAmount2 > remainingPrincipal) {
            closeAmount2 = remainingPrincipal / 2; // Adjust to not exceed remaining
        }
        if (closeAmount2 == 0) closeAmount2 = 1e6;

        // Second partial close
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, closeAmount2);

        uint256 sharesAfterSecond = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        // After second close, may be fully closed
        if (sharesAfterSecond == 0) {
            return;
        }
        assertLe(sharesAfterSecond, sharesAfterFirst, "Shares should decrease or stay same");

        // Full close remaining
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        uint256 sharesAfterFull = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfterFull, 0, "Should have no shares after full close");
    }

    /// @notice Fuzz test for draws followed by close
    function testFuzz_DrawThenClose(uint256 openAmount, uint256 drawFraction) public {
        openAmount = bound(openAmount, MIN_OPEN_AMOUNT * 10, MAX_OPEN_AMOUNT);
        drawFraction = bound(drawFraction, 10, 80);

        _setupBorrowerWithCreditLine(BORROWER_1, openAmount * 2);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, openAmount);

        uint256 drawAmount = (openAmount * drawFraction) / 100;

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, drawAmount, RECIPIENT);

        // Should still be able to close remaining
        callableCredit.close(BORROWER_1);
        vm.stopPrank();

        uint256 sharesAfter = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        assertEq(sharesAfter, 0, "Should have no shares after close");

        // After targeted draw and close, tracking reflects drawn amount
        // totalCcWaUsdc = opened - closed_proportional_to_waUsdc_held
        // Since draw burned shares and reduced waUsdc held, close only reduces by what's left
        // This is intentional: tracking is for capacity, not current holdings
        (,, uint128 siloWaUsdc) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(siloWaUsdc, 0, "Silo should have no waUSDC after close");
    }
}
