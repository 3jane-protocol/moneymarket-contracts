// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./CallableCreditBaseTest.sol";

/// @title CallableCreditMultiSiloTest
/// @notice Tests for multi-counter-protocol silo isolation
contract CallableCreditMultiSiloTest is CallableCreditBaseTest {
    function setUp() public override {
        super.setUp();

        // Authorize second counter-protocol
        _authorizeCounterProtocol(COUNTER_PROTOCOL_2);
    }

    // ============ Silo Isolation Tests ============

    function testSilosAreIsolated() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // Counter-protocol 1 opens position with borrower 1
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Counter-protocol 2 opens position with borrower 2
        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT / 2);

        // Verify silos are separate
        (uint128 principal1, uint128 shares1) = callableCredit.silos(COUNTER_PROTOCOL);
        (uint128 principal2, uint128 shares2) = callableCredit.silos(COUNTER_PROTOCOL_2);

        assertGt(principal1, principal2, "Silo 1 should have more principal");
        assertGt(shares1, shares2, "Silo 1 should have more shares");

        // Verify borrower shares are in correct silos
        uint256 b1InSilo1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 b1InSilo2 = callableCredit.borrowerShares(COUNTER_PROTOCOL_2, BORROWER_1);
        uint256 b2InSilo1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);
        uint256 b2InSilo2 = callableCredit.borrowerShares(COUNTER_PROTOCOL_2, BORROWER_2);

        assertGt(b1InSilo1, 0, "Borrower 1 should have shares in silo 1");
        assertEq(b1InSilo2, 0, "Borrower 1 should NOT have shares in silo 2");
        assertEq(b2InSilo1, 0, "Borrower 2 should NOT have shares in silo 1");
        assertGt(b2InSilo2, 0, "Borrower 2 should have shares in silo 2");
    }

    function testSameBorrowerDifferentSilos() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Same borrower opens positions with two different counter-protocols
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2);

        // Verify borrower has shares in both silos
        uint256 sharesInSilo1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 sharesInSilo2 = callableCredit.borrowerShares(COUNTER_PROTOCOL_2, BORROWER_1);

        assertGt(sharesInSilo1, 0, "Should have shares in silo 1");
        assertGt(sharesInSilo2, 0, "Should have shares in silo 2");
        assertGt(sharesInSilo1, sharesInSilo2, "Silo 1 should have more shares");
    }

    function testCounterProtocolCannotAccessOtherSilo() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Counter-protocol 1 opens position
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        // Counter-protocol 2 tries to close borrower 1's position (should fail - no position)
        vm.prank(COUNTER_PROTOCOL_2);
        vm.expectRevert(CallableCredit.NoPosition.selector);
        callableCredit.close(BORROWER_1);

        // Counter-protocol 2 tries to draw from borrower 1 (should fail - no position)
        vm.prank(COUNTER_PROTOCOL_2);
        vm.expectRevert(CallableCredit.NoPosition.selector);
        callableCredit.draw(BORROWER_1, 1000e6, RECIPIENT);
    }

    function testProRataDrawOnlyAffectsOwnSilo() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // Both counter-protocols open positions
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);

        (uint128 principal1Before,) = callableCredit.silos(COUNTER_PROTOCOL);
        (uint128 principal2Before,) = callableCredit.silos(COUNTER_PROTOCOL_2);

        // Counter-protocol 1 does pro-rata draw
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        (uint128 principal1After,) = callableCredit.silos(COUNTER_PROTOCOL);
        (uint128 principal2After,) = callableCredit.silos(COUNTER_PROTOCOL_2);

        // Only silo 1 should be affected
        assertLt(principal1After, principal1Before, "Silo 1 principal should decrease");
        assertEq(principal2After, principal2Before, "Silo 2 principal should be unchanged");
    }

    function testCloseOnlyAffectsOwnSilo() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);

        // Same borrower in both silos
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);

        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2);

        uint256 sharesInSilo1Before = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 sharesInSilo2Before = callableCredit.borrowerShares(COUNTER_PROTOCOL_2, BORROWER_1);

        // Counter-protocol 2 closes their position
        vm.prank(COUNTER_PROTOCOL_2);
        callableCredit.close(BORROWER_1);

        uint256 sharesInSilo1After = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 sharesInSilo2After = callableCredit.borrowerShares(COUNTER_PROTOCOL_2, BORROWER_1);

        // Silo 1 should be unaffected
        assertEq(sharesInSilo1After, sharesInSilo1Before, "Silo 1 shares should be unchanged");
        assertEq(sharesInSilo2After, 0, "Silo 2 shares should be cleared");
    }

    function testMultipleBorrowersInSameSilo() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        // Same counter-protocol opens positions for two borrowers
        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT / 2);
        vm.stopPrank();

        (uint128 totalPrincipal, uint128 totalShares) = callableCredit.silos(COUNTER_PROTOCOL);

        uint256 shares1 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2 = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        // Total shares should equal sum of borrower shares
        assertEq(totalShares, shares1 + shares2, "Total shares should equal sum of borrower shares");

        // Get borrower principals
        uint256 principal1 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_1);
        uint256 principal2 = callableCredit.getBorrowerPrincipal(COUNTER_PROTOCOL, BORROWER_2);

        // Sum of principals should approximately equal total (may have small rounding)
        assertApproxEqAbs(principal1 + principal2, totalPrincipal, 2, "Sum of principals should equal total");
    }

    function testDrawFromSpecificBorrowerInMultiBorrowerSilo() public {
        _setupBorrowerWithCreditLine(BORROWER_1, CREDIT_LINE_AMOUNT);
        _setupBorrowerWithCreditLine(BORROWER_2, CREDIT_LINE_AMOUNT);

        vm.startPrank(COUNTER_PROTOCOL);
        callableCredit.open(BORROWER_1, DEFAULT_OPEN_AMOUNT);
        callableCredit.open(BORROWER_2, DEFAULT_OPEN_AMOUNT);
        vm.stopPrank();

        uint256 shares1Before = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2Before = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        // Draw from borrower 1 only
        vm.prank(COUNTER_PROTOCOL);
        callableCredit.draw(BORROWER_1, DEFAULT_OPEN_AMOUNT / 2, RECIPIENT);

        uint256 shares1After = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_1);
        uint256 shares2After = callableCredit.borrowerShares(COUNTER_PROTOCOL, BORROWER_2);

        // Only borrower 1's shares should decrease
        assertLt(shares1After, shares1Before, "Borrower 1 shares should decrease");
        assertEq(shares2After, shares2Before, "Borrower 2 shares should be unchanged");
    }
}
