// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";
import {CallableCredit} from "../../../src/CallableCredit.sol";

/// @title CallableCreditCapsTest
/// @notice Tests for CallableCredit cap enforcement (tracking in waUSDC terms)
contract CallableCreditCapsTest is CallableCreditBaseTest {
    uint256 constant BPS = 10000;

    // ============ Setup Helpers ============

    function _setGlobalCcCap(uint256 bps) internal {
        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_DEBT_CAP_BPS, bps);
    }

    function _setBorrowerCcCap(uint256 bps) internal {
        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_CREDIT_LINE_BPS, bps);
    }

    function _setDebtCap(uint256 amount) internal {
        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, amount);
    }

    // ============ Global CC Cap Tests ============

    function testOpenRespectsGlobalCcCap() public {
        // Set debt cap to 1M and CC cap to 10% (100k max CC)
        _setDebtCap(1_000_000e6);
        _setGlobalCcCap(1000); // 10%

        _setupBorrowerWithCreditLine(BORROWER_1, 500_000e6);
        _setupBorrowerWithCreditLine(BORROWER_2, 500_000e6);

        // First open should succeed (50k < 100k cap)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 50_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 50_000e6);

        // Second open should fail (50k + 60k > 100k cap)
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_2, 60_000e6);

        // Third open at limit should succeed (50k + 50k = 100k)
        _openPosition(COUNTER_PROTOCOL, BORROWER_2, 50_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 100_000e6);
    }

    function testGlobalCcCapZeroMeansNoCC() public {
        // Set debt cap but CC cap to 0 (no CC allowed)
        _setDebtCap(1_000_000e6);
        _setGlobalCcCap(0);

        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Should fail - cap is 0, so no CC is allowed
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 1e6);
    }

    function testGlobalCcCapUnlimitedWhenMax() public {
        // Set debt cap and CC cap to 10000 (100% = unlimited)
        _setDebtCap(1_000_000e6);
        _setGlobalCcCap(10000);

        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Should succeed - cap is >= 10000, so unlimited
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 500_000e6);
        assertGt(callableCredit.totalCcWaUsdc(), 0);
    }

    // ============ Per-Borrower CC Cap Tests ============

    function testOpenRespectsBorrowerCcCap() public {
        // Set borrower cap to 50% of credit line
        _setBorrowerCcCap(5000); // 50%

        // Borrower has 100k credit line, max CC = 50k
        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);

        // First open should succeed (30k < 50k)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 30_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 30_000e6);

        // Second open should fail (30k + 25k > 50k)
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 25_000e6);

        // Third open at limit should succeed (30k + 20k = 50k)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 20_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 50_000e6);
    }

    function testBorrowerCcCapZeroMeansNoCC() public {
        // CC borrower cap to 0 (no CC allowed for any borrower)
        _setBorrowerCcCap(0);

        // Borrower has credit line
        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);

        // Should fail - cap is 0, so no CC is allowed
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 1e6);
    }

    function testBorrowerCcCapUnlimitedWhenMax() public {
        // CC borrower cap to 10000 (100% = unlimited)
        _setBorrowerCcCap(10000);

        // Borrower has credit line
        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);

        // Should succeed - cap is >= 10000, so unlimited
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 100_000e6);
        assertGt(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 0);
    }

    function testBorrowerCcCapAppliesPerBorrower() public {
        // Set borrower cap to 30%
        _setBorrowerCcCap(3000); // 30%

        // Both borrowers have 100k credit line, max CC = 30k each
        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);
        _setupBorrowerWithCreditLine(BORROWER_2, 100_000e6);

        // Borrower 1 can open 30k
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 30_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 30_000e6);

        // Borrower 2 can also open 30k (independent cap)
        _openPosition(COUNTER_PROTOCOL, BORROWER_2, 30_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_2), 30_000e6);

        // Global tracking shows 60k total
        assertEq(callableCredit.totalCcWaUsdc(), 60_000e6);
    }

    // ============ Cap Tracking on Close Tests ============

    function testCloseDecreasesTracking() public {
        _setGlobalCcCap(5000); // 50%
        _setDebtCap(1_000_000e6);

        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);

        // Open 50k position
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 50_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 50_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 50_000e6);

        // Close position
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1);

        // Tracking should be reset
        assertEq(callableCredit.totalCcWaUsdc(), 0);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 0);
    }

    function testPartialCloseDecreasesTrackingProportionally() public {
        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);

        // Open 50k position
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 50_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 50_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 50_000e6);

        // Partial close 20k
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, 20_000e6);

        // Tracking should decrease by 20k
        assertEq(callableCredit.totalCcWaUsdc(), 30_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 30_000e6);
    }

    function testCloseFreesCapacityForNewOpen() public {
        _setGlobalCcCap(1000); // 10%
        _setDebtCap(1_000_000e6); // max CC = 100k

        _setupBorrowerWithCreditLine(BORROWER_1, 200_000e6);
        _setupBorrowerWithCreditLine(BORROWER_2, 200_000e6);

        // Open 100k (at cap)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 100_000e6);

        // Can't open more
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_2, 1e6);

        // Close 50k
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.close(BORROWER_1, 50_000e6);

        // Now can open 50k
        _openPosition(COUNTER_PROTOCOL, BORROWER_2, 50_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 100_000e6);
    }

    // ============ Combined Cap Tests ============

    function testBothCapsEnforced() public {
        // Global cap: 50% of 1M = 500k
        _setDebtCap(1_000_000e6);
        _setGlobalCcCap(5000);

        // Borrower cap: 20% of credit line
        _setBorrowerCcCap(2000);

        // Borrower has 1M credit line, so borrower cap = 200k
        // Borrower cap (200k) < global cap (500k), so borrower cap is binding
        _setupBorrowerWithCreditLine(BORROWER_1, 1_000_000e6);

        // Try to open 250k (exceeds borrower cap of 200k)
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 250_000e6);

        // Open 200k (at borrower cap)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 200_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 200_000e6);
    }

    function testGlobalCapBindsBeforeBorrowerCap() public {
        // Global cap: 10% of 500k = 50k
        _setDebtCap(500_000e6);
        _setGlobalCcCap(1000);

        // Borrower cap: 50% of credit line = 100k
        _setBorrowerCcCap(5000);

        // Borrower has 200k credit line, borrower cap = 100k
        // Global cap (50k) < borrower cap (100k), so global cap is binding
        _setupBorrowerWithCreditLine(BORROWER_1, 200_000e6);

        // Try to open 60k (exceeds global cap of 50k)
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 60_000e6);

        // Open 50k (at global cap)
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 50_000e6);
        assertEq(callableCredit.totalCcWaUsdc(), 50_000e6);
    }

    // ============ Multi-Silo Cap Tests ============

    function testBorrowerCcCapAcrossMultipleSilos() public {
        // Authorize second counter-protocol
        _authorizeCounterProtocol(COUNTER_PROTOCOL_2);

        // Borrower cap: 30%
        _setBorrowerCcCap(3000);

        // Borrower has 100k credit line, cap = 30k across ALL silos
        _setupBorrowerWithCreditLine(BORROWER_1, 100_000e6);

        // Open 20k in silo 1
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 20_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 20_000e6);

        // Try to open 15k in silo 2 (20k + 15k > 30k cap)
        vm.prank(COUNTER_PROTOCOL_2);
        vm.expectRevert(ErrorsLib.CcCapExceeded.selector);
        callableCredit.open(BORROWER_1, 15_000e6);

        // Open 10k in silo 2 (20k + 10k = 30k)
        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_1, 10_000e6);
        assertEq(callableCredit.borrowerTotalCcWaUsdc(BORROWER_1), 30_000e6);
    }
}
