// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";

/// @title CallableCreditFeeTest
/// @notice Tests for CallableCredit origination fee functionality
contract CallableCreditFeeTest is CallableCreditBaseTest {
    address internal CC_FEE_RECIPIENT_ADDR;
    uint256 constant FEE_BPS = 100; // 1% fee

    function setUp() public override {
        super.setUp();
        CC_FEE_RECIPIENT_ADDR = makeAddr("CcFeeRecipient");
    }

    // ============ Setup Helpers ============

    function _setOriginationFee(uint256 bps, address recipient) internal {
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS, bps);
        protocolConfig.setConfig(ProtocolConfigLib.CC_FEE_RECIPIENT, uint256(uint160(recipient)));
        vm.stopPrank();
    }

    // ============ No Fee Tests ============

    function testNoFeeWhenBpsIsZero() public {
        _setOriginationFee(0, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(CC_FEE_RECIPIENT_ADDR);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // No fee should be sent
        assertEq(usdc.balanceOf(CC_FEE_RECIPIENT_ADDR), recipientBalanceBefore);
    }

    function testNoFeeWhenRecipientIsZero() public {
        _setOriginationFee(FEE_BPS, address(0));
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Position should open without issues
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Silo should have the full waUSDC amount
        (,, uint128 totalWaUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalWaUsdcHeld, wausdc.previewWithdraw(DEFAULT_OPEN_AMOUNT));
    }

    function testNoFeeByDefault() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(CC_FEE_RECIPIENT_ADDR);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // No fee should be sent (config not set)
        assertEq(usdc.balanceOf(CC_FEE_RECIPIENT_ADDR), recipientBalanceBefore);
    }

    // ============ Fee Charging Tests ============

    function testFeeChargedOnOpen() public {
        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(CC_FEE_RECIPIENT_ADDR);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Fee should be 1% of 100k = 1k USDC
        uint256 expectedFee = (DEFAULT_OPEN_AMOUNT * FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(CC_FEE_RECIPIENT_ADDR), recipientBalanceBefore + expectedFee);
    }

    function testFeeIsAdditionalCharge() public {
        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Silo should have full principal (not reduced by fee)
        (uint128 totalPrincipal,,) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalPrincipal, DEFAULT_OPEN_AMOUNT);

        // Silo should have waUSDC for the position (not including fee which was sent away)
        (,, uint128 totalWaUsdcHeld) = callableCredit.silos(COUNTER_PROTOCOL);
        assertEq(totalWaUsdcHeld, wausdc.previewWithdraw(DEFAULT_OPEN_AMOUNT));
    }

    function testBorrowerDebtIncludesFee() public {
        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Borrower's debt in MorphoCredit should include the fee
        uint256 expectedFeeUsdc = (DEFAULT_OPEN_AMOUNT * FEE_BPS) / 10000;
        uint256 expectedTotalWaUsdc =
            wausdc.previewWithdraw(DEFAULT_OPEN_AMOUNT) + wausdc.previewWithdraw(expectedFeeUsdc);

        uint256 borrowerDebt = _getBorrowerDebt(BORROWER_1);
        // Debt should be approximately position + fee (may differ slightly due to share math)
        assertApproxEqAbs(borrowerDebt, expectedTotalWaUsdc, 2);
    }

    function testFeeDoesNotCountTowardCaps() public {
        // Set tight global cap: 10% of 1M = 100k
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, 1_000_000e6);
        protocolConfig.setConfig(ProtocolConfigLib.CC_DEBT_CAP_BPS, 1000); // 10%
        vm.stopPrank();

        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Open 99k position + 1% fee
        // Fee is not tracked since it's sent away immediately
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 99_000e6);

        // Tracking should only include position, not fee
        uint256 expectedWaUsdc = wausdc.previewWithdraw(99_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), expectedWaUsdc);
    }

    function testCloseReleasesFullTrackingWithFee() public {
        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Open position with fee
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);
        uint256 trackingAfterOpen = callableCredit.totalCcWaUsdc();
        assertGt(trackingAfterOpen, 0);

        // Close position
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        // Tracking should be fully released (no stale fee debt)
        assertEq(callableCredit.totalCcWaUsdc(), 0);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 0);
    }

    function testFeeWithDifferentBps() public {
        // Test with 2.5% fee (250 bps)
        _setOriginationFee(250, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(CC_FEE_RECIPIENT_ADDR);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Fee should be 2.5% of 100k = 2.5k USDC
        uint256 expectedFee = (DEFAULT_OPEN_AMOUNT * 250) / 10000;
        assertEq(usdc.balanceOf(CC_FEE_RECIPIENT_ADDR), recipientBalanceBefore + expectedFee);
    }

    // ============ Event Tests ============

    function testPositionOpenedEventIncludesFee() public {
        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 expectedFee = (DEFAULT_OPEN_AMOUNT * FEE_BPS) / 10000;
        // Shares for first position: amount * (0 + 1e6) / (0 + 1) = amount * 1e6
        uint256 expectedShares = DEFAULT_OPEN_AMOUNT * 1e6;

        vm.expectEmit(true, true, false, true);
        emit ICallableCredit.PositionOpened(
            COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT, expectedShares, expectedFee
        );

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    function testPositionOpenedEventZeroFeeWhenNotConfigured() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Shares for first position: amount * (0 + 1e6) / (0 + 1) = amount * 1e6
        uint256 expectedShares = DEFAULT_OPEN_AMOUNT * 1e6;

        vm.expectEmit(true, true, false, true);
        emit ICallableCredit.PositionOpened(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT, expectedShares, 0);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    // ============ Multiple Opens Tests ============

    function testFeeChargedOnEachOpen() public {
        _setOriginationFee(FEE_BPS, CC_FEE_RECIPIENT_ADDR);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        uint256 recipientBalanceBefore = usdc.balanceOf(CC_FEE_RECIPIENT_ADDR);

        // First open
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Second open
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Fee should be charged twice
        uint256 expectedTotalFee = 2 * (DEFAULT_OPEN_AMOUNT * FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(CC_FEE_RECIPIENT_ADDR), recipientBalanceBefore + expectedTotalFee);
    }
}
