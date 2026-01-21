// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";

/// @title CallableCreditAllowanceTest
/// @notice Tests for borrower allowance functionality
contract CallableCreditAllowanceTest is CallableCreditBaseTest {
    // ============ Approve Tests ============

    function testApproveSetsBorrowerAllowance() public {
        uint256 approveAmount = 50_000e6;

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, approveAmount);

        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            approveAmount,
            "Allowance should match approved amount"
        );
    }

    function testApproveEmitsEvent() public {
        uint256 approveAmount = 50_000e6;

        vm.expectEmit(true, true, false, true);
        emit ICallableCredit.Approval(BORROWER_1, COUNTER_PROTOCOL, approveAmount);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, approveAmount);
    }

    function testApproveCanOverwritePreviousAllowance() public {
        vm.startPrank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);
        callableCredit.approve(COUNTER_PROTOCOL, 50_000e6);
        vm.stopPrank();

        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 50_000e6, "Allowance should be overwritten"
        );
    }

    function testApproveCanSetToZero() public {
        vm.startPrank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);
        callableCredit.approve(COUNTER_PROTOCOL, 0);
        vm.stopPrank();

        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Allowance should be zero");
    }

    function testApproveIsPerCounterProtocol() public {
        _authorizeCounterProtocol(COUNTER_PROTOCOL_2);

        vm.startPrank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);
        callableCredit.approve(COUNTER_PROTOCOL_2, 50_000e6);
        vm.stopPrank();

        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 100_000e6, "CP1 allowance should be 100k"
        );
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL_2), 50_000e6, "CP2 allowance should be 50k"
        );
    }

    // ============ Open With Allowance Tests ============

    function testOpenConsumesAllowance() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 60_000e6);

        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            40_000e6,
            "Allowance should be reduced by open amount"
        );
    }

    function testOpenRevertsWhenAllowanceInsufficient() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 50_000e6);

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.InsufficientBorrowerAllowance.selector);
        callableCredit.open(BORROWER_1, 60_000e6);
    }

    function testOpenRevertsWhenNoAllowance() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);
        // Don't grant any allowance

        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.InsufficientBorrowerAllowance.selector);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
    }

    function testOpenAtExactAllowance() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 50_000e6);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 50_000e6);

        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Allowance should be fully consumed"
        );
    }

    function testMultipleOpensConsumeAllowanceCumulatively() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 30_000e6);
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 70_000e6, "After first open");

        callableCredit.open(BORROWER_1, 40_000e6);
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 30_000e6, "After second open");

        callableCredit.open(BORROWER_1, 30_000e6);
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "After third open");
        vm.stopPrank();
    }

    // ============ Draw Does Not Restore Allowance Tests ============

    function testDrawDoesNotRestoreAllowance() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 100_000e6);
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Allowance consumed");

        // Draw from the position
        callableCredit.draw(BORROWER_1, 50_000e6, RECIPIENT);

        // Allowance should still be zero
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Draw should not restore allowance");
        vm.stopPrank();
    }

    function testCloseDoesNotRestoreAllowance() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 100_000e6);
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Allowance consumed");

        // Close the position
        callableCredit.close(BORROWER_1);

        // Allowance should still be zero
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Close should not restore allowance"
        );
        vm.stopPrank();
    }

    // ============ Open-Draw-Open Attack Prevention Tests ============

    function testOpenDrawOpenAttackPrevented() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        // Borrower grants only 50k allowance
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 50_000e6);

        vm.startPrank(COUNTER_PROTOCOL);

        // Open 50k
        callableCredit.open(BORROWER_1, 50_000e6);
        assertEq(callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL), 0, "Allowance exhausted");

        // Draw 50k (position closed)
        callableCredit.draw(BORROWER_1, 50_000e6, RECIPIENT);

        // Attempt to open again should fail - allowance is not restored
        vm.expectRevert(ErrorsLib.InsufficientBorrowerAllowance.selector);
        callableCredit.open(BORROWER_1, 50_000e6);
        vm.stopPrank();
    }

    function testOpenCloseOpenRequiresNewAllowance() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        // First approval
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 50_000e6);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 50_000e6);
        callableCredit.close(BORROWER_1);

        // Can't open again without new approval
        vm.expectRevert(ErrorsLib.InsufficientBorrowerAllowance.selector);
        callableCredit.open(BORROWER_1, 50_000e6);
        vm.stopPrank();

        // Borrower grants new allowance
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 50_000e6);

        // Now can open again
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 50_000e6);
    }

    // ============ Multi-Counter-Protocol Tests ============

    function testAllowanceIsPerCounterProtocol() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);
        _authorizeCounterProtocol(COUNTER_PROTOCOL_2);

        vm.startPrank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);
        callableCredit.approve(COUNTER_PROTOCOL_2, 50_000e6);
        vm.stopPrank();

        // CP1 opens 100k
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 100_000e6);

        // CP2's allowance should be unaffected
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL_2),
            50_000e6,
            "CP2 allowance should be unaffected"
        );

        // CP2 can still open up to their allowance
        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_1, 50_000e6);
    }

    // ============ Edge Cases ============

    function testApproveMaxUint() public {
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, type(uint256).max);

        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            type(uint256).max,
            "Allowance should be max uint"
        );
    }

    function testMaxAllowanceIsNotDecremented() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, type(uint256).max);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Max allowance should remain unchanged (infinite approval)
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            type(uint256).max,
            "Max allowance should not be decremented"
        );
    }

    // ============ Fee-Inclusive Allowance Tests ============

    function testAllowanceMustCoverFee() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        // Configure 1% origination fee
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS, 100); // 1%
        protocolConfig.setConfig(ProtocolConfigLib.CC_FEE_RECIPIENT, uint256(uint160(RECIPIENT)));
        vm.stopPrank();

        // Approve exactly 100k (not enough for 100k principal + 1k fee)
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 100_000e6);

        // Should revert - need 101k for 100k principal + 1% fee
        vm.prank(COUNTER_PROTOCOL);
        vm.expectRevert(ErrorsLib.InsufficientBorrowerAllowance.selector);
        callableCredit.open(BORROWER_1, 100_000e6);
    }

    function testAllowanceConsumesIncludingFee() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        // Configure 1% origination fee
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS, 100); // 1%
        protocolConfig.setConfig(ProtocolConfigLib.CC_FEE_RECIPIENT, uint256(uint160(RECIPIENT)));
        vm.stopPrank();

        // Approve 101k (enough for 100k principal + 1k fee)
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 101_000e6);

        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 100_000e6);

        // Allowance should be reduced by 101k (principal + fee)
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            0,
            "Allowance should be consumed including fee"
        );
    }

    function testAllowanceWithFeePartialConsumption() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        // Configure 2% origination fee
        vm.startPrank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.CC_ORIGINATION_FEE_BPS, 200); // 2%
        protocolConfig.setConfig(ProtocolConfigLib.CC_FEE_RECIPIENT, uint256(uint160(RECIPIENT)));
        vm.stopPrank();

        // Approve 200k
        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, 200_000e6);

        // Open 50k principal → consumes 51k (50k + 2% fee)
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 50_000e6);

        // Remaining: 200k - 51k = 149k
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            149_000e6,
            "Allowance should be reduced by principal + fee"
        );
    }

    function testMaxAllowanceAllowsUnlimitedOpens() public {
        creditLine.setCreditLine(ccMarketId, BORROWER_1, CREDIT_LINE_AMOUNT, 0);

        vm.prank(BORROWER_1);
        callableCredit.approve(COUNTER_PROTOCOL, type(uint256).max);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, 100_000e6);
        callableCredit.close(BORROWER_1);

        // Can open again without re-approving
        callableCredit.open(BORROWER_1, 100_000e6);
        callableCredit.close(BORROWER_1);

        // And again
        callableCredit.open(BORROWER_1, 100_000e6);
        vm.stopPrank();

        // Allowance still max
        assertEq(
            callableCredit.borrowerAllowance(BORROWER_1, COUNTER_PROTOCOL),
            type(uint256).max,
            "Max allowance should persist"
        );
    }
}
