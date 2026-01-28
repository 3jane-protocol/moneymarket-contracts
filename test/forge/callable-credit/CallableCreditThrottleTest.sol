// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";

/// @title CallableCreditThrottleTest
/// @notice Tests for CallableCredit notional throttle functionality
contract CallableCreditThrottleTest is CallableCreditBaseTest {
    uint256 constant THROTTLE_PERIOD = 1 days;
    uint256 constant THROTTLE_LIMIT = 500_000e6; // 500k USDC per day

    // ============ Setup Helpers ============

    function _setThrottle(uint256 period, uint256 limit) internal {
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_THROTTLE_PERIOD, period);
        protocolConfig.setConfig(ProtocolConfigLib.CC_THROTTLE_LIMIT, limit);
        vm.stopPrank();
    }

    // ============ Disabled Throttle Tests ============

    function testNoThrottleWhenPeriodIsZero() public {
        _setThrottle(0, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Should succeed even for large amounts
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, THROTTLE_LIMIT + 100_000e6);

        // Throttle state should not be updated
        (uint64 periodStart, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodStart, 0);
        assertEq(periodUsdc, 0);
    }

    function testNoThrottleWhenLimitIsZero() public {
        _setThrottle(THROTTLE_PERIOD, 0);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Should succeed even for large amounts
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 600_000e6);

        // Throttle state should not be updated
        (uint64 periodStart, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodStart, 0);
        assertEq(periodUsdc, 0);
    }

    function testNoThrottleByDefault() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Should succeed without throttle configured
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Throttle state should not be updated
        (uint64 periodStart, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodStart, 0);
        assertEq(periodUsdc, 0);
    }

    // ============ Basic Throttle Tests ============

    function testThrottleTracksUsage() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (uint64 periodStart, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodStart, block.timestamp);
        assertEq(periodUsdc, DEFAULT_OPEN_AMOUNT);
    }

    function testThrottleAccumulatesAcrossOpens() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 100_000e6);
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 100_000e6);

        (, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodUsdc, 200_000e6);
    }

    function testThrottleRevertsWhenLimitExceeded() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // First open uses 400k of 500k limit
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 400_000e6);

        // Second open tries to use 200k more, exceeds 500k limit
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.ThrottleLimitExceeded.selector);
        callableCredit.open(BORROWER_1, 200_000e6);
    }

    function testThrottleAllowsExactLimit() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Should succeed at exactly the limit
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, THROTTLE_LIMIT);

        (, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodUsdc, THROTTLE_LIMIT);
    }

    // ============ Period Reset Tests ============

    function testThrottleResetsAfterPeriod() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Use full limit
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, THROTTLE_LIMIT);

        // Warp past the period
        vm.warp(block.timestamp + THROTTLE_PERIOD + 1);

        // Should succeed - new period started
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Period should be reset
        (uint64 periodStart, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodStart, block.timestamp);
        assertEq(periodUsdc, DEFAULT_OPEN_AMOUNT);
    }

    function testThrottleDoesNotResetBeforePeriodEnds() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Use full limit
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, THROTTLE_LIMIT);
        (uint64 initialPeriodStart,) = callableCredit.throttle();

        // Warp almost to the end but not past
        vm.warp(block.timestamp + THROTTLE_PERIOD - 1);

        // Should still revert - period not ended
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.ThrottleLimitExceeded.selector);
        callableCredit.open(BORROWER_1, 1e6);

        // Period start should be unchanged
        (uint64 periodStart,) = callableCredit.throttle();
        assertEq(periodStart, initialPeriodStart);
    }

    function testThrottleResetsExactlyAtPeriodEnd() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Use full limit
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, THROTTLE_LIMIT);

        // Warp exactly to period end
        vm.warp(block.timestamp + THROTTLE_PERIOD);

        // Should succeed - new period starts
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    // ============ Multi-Borrower Tests ============

    function testThrottleIsGlobalAcrossBorrowers() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // Borrower 1 uses 300k
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 300_000e6);

        // Borrower 2 tries to use 300k more, exceeds 500k global limit
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.ThrottleLimitExceeded.selector);
        callableCredit.open(BORROWER_2, 300_000e6);

        // Borrower 2 can use 200k (bringing total to 500k)
        _openPosition(COUNTER_PROTOCOL, BORROWER_2, 200_000e6);

        (, uint64 periodUsdc) = callableCredit.throttle();
        assertEq(periodUsdc, 500_000e6);
    }

    // ============ Multi-Silo Tests ============

    function testThrottleIsGlobalAcrossSilos() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Authorize second counter-protocol
        vm.prank(OWNER);
        callableCredit.setAuthorizedCounterProtocol(COUNTER_PROTOCOL_2, true);

        // Counter-protocol 1 uses 300k
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, 300_000e6);

        // Counter-protocol 2 tries to use 300k more, exceeds global limit
        vm.prank(COUNTER_PROTOCOL_2);
        vm.expectRevert(ErrorsLib.ThrottleLimitExceeded.selector);
        callableCredit.open(BORROWER_1, 300_000e6);
    }

    // ============ First Open Tests ============

    function testFirstOpenInitializesPeriod() public {
        _setThrottle(THROTTLE_PERIOD, THROTTLE_LIMIT);
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Initially zero
        (uint64 periodStart,) = callableCredit.throttle();
        assertEq(periodStart, 0);

        // First open initializes period
        _openPosition(COUNTER_PROTOCOL, BORROWER_1, DEFAULT_OPEN_AMOUNT);

        (periodStart,) = callableCredit.throttle();
        assertEq(periodStart, block.timestamp);
    }
}
