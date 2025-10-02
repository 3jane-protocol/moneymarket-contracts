// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PYTLockerSetup} from "./utils/PYTLockerSetup.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPYT} from "./mocks/MockPYT.sol";

contract PYTLockerIntegrationTest is PYTLockerSetup {
    // ============================================
    // Complete Lifecycle Tests
    // ============================================

    /// @notice Test complete lifecycle: add token, deposit, wait, withdraw
    function test_completeMultiTokenLifecycle() public {
        // Step 1: Owner adds multiple tokens with different expiries
        addMultipleTokens();

        // Step 2: Multiple users deposit different tokens
        deposit(alice, address(pyt1), 1000e18);
        deposit(alice, address(pyt2), 500e18);
        deposit(bob, address(pyt2), 750e18);
        deposit(bob, address(pyt3), 1000e18);
        deposit(charlie, address(pyt1), 300e18);
        deposit(charlie, address(pyt3), 600e18);

        // Step 3: Verify deposits
        assertEq(getLockedBalance(alice, address(pyt1)), 1000e18);
        assertEq(getLockedBalance(alice, address(pyt2)), 500e18);
        assertEq(getLockedBalance(bob, address(pyt2)), 750e18);
        assertEq(getLockedBalance(bob, address(pyt3)), 1000e18);
        assertEq(getLockedBalance(charlie, address(pyt1)), 300e18);
        assertEq(getLockedBalance(charlie, address(pyt3)), 600e18);

        // Verify total supplies
        assertEq(locker.totalSupply(address(pyt1)), 1300e18);
        assertEq(locker.totalSupply(address(pyt2)), 1250e18);
        assertEq(locker.totalSupply(address(pyt3)), 1600e18);

        // Step 4: Advance to first expiry (pyt1 - 1 week)
        advanceToExpiry(address(pyt1));
        assertTrue(locker.isExpired(address(pyt1)));
        assertFalse(locker.isExpired(address(pyt2)));
        assertFalse(locker.isExpired(address(pyt3)));

        // Step 5: Withdraw pyt1 tokens
        withdraw(alice, address(pyt1), 1000e18);
        withdraw(charlie, address(pyt1), 300e18);

        // Verify pyt1 cleared
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(getTokenBalance(alice, address(pyt1)), INITIAL_BALANCE);
        assertEq(getTokenBalance(charlie, address(pyt1)), INITIAL_BALANCE);

        // Cannot withdraw pyt2 yet
        vm.expectRevert(PYTLocker.TokenNotExpired.selector);
        withdraw(alice, address(pyt2), 500e18);

        // Step 6: Advance to second expiry (pyt2 - 1 month)
        advanceToExpiry(address(pyt2));

        // Withdraw pyt2 tokens
        withdraw(alice, address(pyt2), 500e18);
        withdraw(bob, address(pyt2), 750e18);

        // Step 7: Advance to final expiry (pyt3 - 2 months)
        advanceToExpiry(address(pyt3));

        // Withdraw pyt3 tokens
        withdraw(bob, address(pyt3), 1000e18);
        withdraw(charlie, address(pyt3), 600e18);

        // Step 8: Verify all balances cleared
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), 0);
        assertEq(locker.totalSupply(address(pyt3)), 0);
    }

    /// @notice Test dynamic token addition during operation
    function test_dynamicTokenAddition() public {
        // Start with one token
        addSupportedToken(address(pyt1));
        deposit(alice, address(pyt1), 500e18);

        // Advance some time
        advanceTime(ONE_DAY * 3);

        // Add second token while first is still locked
        addSupportedToken(address(pyt2));
        deposit(bob, address(pyt2), 750e18);

        // First token expires
        advanceToExpiry(address(pyt1));

        // Add third token after first expired
        addSupportedToken(address(pyt3));
        deposit(charlie, address(pyt3), 1000e18);

        // Alice withdraws expired pyt1
        withdraw(alice, address(pyt1), 500e18);

        // Bob deposits more pyt2
        deposit(bob, address(pyt2), 250e18);

        // Verify state
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), 1000e18);
        assertEq(locker.totalSupply(address(pyt3)), 1000e18);
        assertEq(locker.supportedTokenCount(), 3);
    }

    // ============================================
    // Multi-User Scenarios
    // ============================================

    /// @notice Test multiple users with overlapping token holdings
    function test_multiUserOverlappingTokens() public {
        addMultipleTokens();

        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1000e18; // alice
        amounts[1] = 750e18; // bob
        amounts[2] = 500e18; // charlie
        amounts[3] = 250e18; // dave (using charlie as substitute)

        // All users deposit in pyt1
        deposit(alice, address(pyt1), amounts[0]);
        deposit(bob, address(pyt1), amounts[1]);
        deposit(charlie, address(pyt1), amounts[2]);

        // Some users also deposit in pyt2
        deposit(alice, address(pyt2), amounts[3]);
        deposit(bob, address(pyt2), amounts[2]);

        // Verify total supplies
        assertEq(locker.totalSupply(address(pyt1)), amounts[0] + amounts[1] + amounts[2]);
        assertEq(locker.totalSupply(address(pyt2)), amounts[3] + amounts[2]);

        // Advance past pyt1 expiry
        advanceToExpiry(address(pyt1));

        // Users withdraw in different order
        withdraw(charlie, address(pyt1), amounts[2]);
        withdraw(alice, address(pyt1), amounts[0]);
        withdraw(bob, address(pyt1), amounts[1]);

        // Verify pyt1 cleared but pyt2 still locked
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), amounts[3] + amounts[2]);
    }

    /// @notice Test complex multi-user multi-token scenario
    function test_complexMultiUserMultiToken() public {
        addMultipleTokens();

        // Setup complex deposits
        // Alice: pyt1=100, pyt2=200
        deposit(alice, address(pyt1), 100e18);
        deposit(alice, address(pyt2), 200e18);

        // Bob: pyt2=150, pyt3=300
        deposit(bob, address(pyt2), 150e18);
        deposit(bob, address(pyt3), 300e18);

        // Charlie: pyt1=250, pyt3=350
        deposit(charlie, address(pyt1), 250e18);
        deposit(charlie, address(pyt3), 350e18);

        // Verify isolated balances
        assertEq(getLockedBalance(alice, address(pyt1)), 100e18);
        assertEq(getLockedBalance(alice, address(pyt2)), 200e18);
        assertEq(getLockedBalance(alice, address(pyt3)), 0);

        assertEq(getLockedBalance(bob, address(pyt1)), 0);
        assertEq(getLockedBalance(bob, address(pyt2)), 150e18);
        assertEq(getLockedBalance(bob, address(pyt3)), 300e18);

        assertEq(getLockedBalance(charlie, address(pyt1)), 250e18);
        assertEq(getLockedBalance(charlie, address(pyt2)), 0);
        assertEq(getLockedBalance(charlie, address(pyt3)), 350e18);

        // Staggered withdrawals based on expiries
        advanceToExpiry(address(pyt1));
        withdraw(alice, address(pyt1), 100e18);
        withdraw(charlie, address(pyt1), 250e18);

        advanceToExpiry(address(pyt2));
        withdraw(alice, address(pyt2), 200e18);
        withdraw(bob, address(pyt2), 150e18);

        advanceToExpiry(address(pyt3));
        withdraw(bob, address(pyt3), 300e18);
        withdraw(charlie, address(pyt3), 350e18);

        // All should be cleared
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), 0);
        assertEq(locker.totalSupply(address(pyt3)), 0);
    }

    // ============================================
    // Edge Cases and Boundary Conditions
    // ============================================

    /// @notice Test deposit and withdrawal at expiry boundary
    function test_expiryBoundaryEdgeCase() public {
        // Create a token that expires in 1 day
        MockPYT boundaryPYT = new MockPYT("BOUNDARY-PYT", "BPYT", block.timestamp + ONE_DAY);
        boundaryPYT.mint(alice, 1000e18);

        // Add token to locker
        vm.prank(owner);
        locker.addSupportedToken(address(boundaryPYT));

        // Deposit just before expiry (1 second before)
        advanceTime(ONE_DAY - 1);
        deposit(alice, address(boundaryPYT), 500e18);
        assertFalse(locker.isExpired(address(boundaryPYT)));

        // Try to deposit at exact expiry (should fail)
        advanceTime(1);
        assertTrue(locker.isExpired(address(boundaryPYT)));

        approveToken(alice, address(boundaryPYT), 500e18);
        vm.expectRevert(PYTLocker.TokenExpired.selector);
        vm.prank(alice);
        locker.deposit(address(boundaryPYT), 500e18);

        // But withdrawal should work
        withdraw(alice, address(boundaryPYT), 500e18);
        assertEq(boundaryPYT.balanceOf(alice), 1000e18);
    }

    /// @notice Test partial withdrawals across multiple tokens
    function test_partialWithdrawals() public {
        addMultipleTokens();

        // Alice deposits in multiple tokens
        deposit(alice, address(pyt1), 1000e18);
        deposit(alice, address(pyt2), 800e18);

        // Advance past pyt1 expiry
        advanceToExpiry(address(pyt1));

        // Alice makes multiple partial withdrawals from pyt1
        uint256 aliceInitialPyt1 = getTokenBalance(alice, address(pyt1));

        withdraw(alice, address(pyt1), 100e18);
        assertEq(getLockedBalance(alice, address(pyt1)), 900e18);

        withdraw(alice, address(pyt1), 200e18);
        assertEq(getLockedBalance(alice, address(pyt1)), 700e18);

        withdraw(alice, address(pyt1), 300e18);
        assertEq(getLockedBalance(alice, address(pyt1)), 400e18);

        withdraw(alice, address(pyt1), 400e18);
        assertEq(getLockedBalance(alice, address(pyt1)), 0);

        assertEq(getTokenBalance(alice, address(pyt1)), aliceInitialPyt1 + 1000e18);

        // pyt2 still locked
        assertEq(getLockedBalance(alice, address(pyt2)), 800e18);
    }

    // ============================================
    // Gas Optimization Tests
    // ============================================

    /// @notice Test gas costs for batch operations
    function test_batchOperationsGas() public {
        addSupportedToken(address(pyt1));

        uint256 gasUsed;
        uint256 gasBefore;

        // Measure deposit gas
        approveToken(alice, address(pyt1), 1000e18);
        gasBefore = gasleft();
        vm.prank(alice);
        locker.deposit(address(pyt1), 1000e18);
        gasUsed = gasBefore - gasleft();

        assertTrue(gasUsed < 100_000, "Single deposit gas too high");

        // Batch deposits from different users
        gasBefore = gasleft();
        for (uint256 i = 0; i < 5; i++) {
            deposit(bob, address(pyt1), 100e18);
        }
        gasUsed = (gasBefore - gasleft()) / 5;

        assertTrue(gasUsed < 100_000, "Average batch deposit gas too high");

        // Advance past expiry
        advanceToExpiry(address(pyt1));

        // Measure withdrawal gas
        gasBefore = gasleft();
        withdraw(alice, address(pyt1), 1000e18);
        gasUsed = gasBefore - gasleft();

        assertTrue(gasUsed < 80_000, "Single withdrawal gas too high");
    }

    /// @notice Test gas with many supported tokens
    function test_gasWithManyTokens() public {
        // Add 10 tokens
        MockPYT[] memory tokens = new MockPYT[](10);
        for (uint256 i = 0; i < 10; i++) {
            tokens[i] = new MockPYT(
                string.concat("PYT", vm.toString(i)),
                string.concat("P", vm.toString(i)),
                block.timestamp + ONE_WEEK * (i + 1)
            );
            tokens[i].mint(alice, 100e18);

            vm.prank(owner);
            locker.addSupportedToken(address(tokens[i]));
        }

        // Deposit in 5th token (middle of set)
        uint256 gasBefore = gasleft();
        deposit(alice, address(tokens[4]), 50e18);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(gasUsed < 150_000, "Deposit with many tokens gas too high");

        // Check enumeration gas
        gasBefore = gasleft();
        address[] memory supportedTokens = locker.getSupportedTokens();
        gasUsed = gasBefore - gasleft();

        assertEq(supportedTokens.length, 10);
        assertTrue(gasUsed < 50_000, "Enumeration gas too high");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    /// @notice Fuzz test for random deposit/withdraw amounts
    function testFuzz_randomAmounts(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);

        addSupportedToken(address(pyt1));

        // Deposit
        deposit(alice, address(pyt1), depositAmount);
        assertEq(getLockedBalance(alice, address(pyt1)), depositAmount);

        // Advance past expiry
        advanceToExpiry(address(pyt1));

        // Withdraw partial amount
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);
        withdraw(alice, address(pyt1), withdrawAmount);

        assertEq(getLockedBalance(alice, address(pyt1)), depositAmount - withdrawAmount);
    }

    /// @notice Fuzz test for multiple tokens with random expiries
    function testFuzz_multipleTokensRandomExpiries(uint256 expiry1, uint256 expiry2, uint256 expiry3) public {
        // Bound expiries to reasonable range
        expiry1 = bound(expiry1, block.timestamp + 1 days, block.timestamp + 30 days);
        expiry2 = bound(expiry2, block.timestamp + 31 days, block.timestamp + 60 days);
        expiry3 = bound(expiry3, block.timestamp + 61 days, block.timestamp + 365 days);

        // Create tokens with random expiries
        MockPYT token1 = new MockPYT("T1", "T1", expiry1);
        MockPYT token2 = new MockPYT("T2", "T2", expiry2);
        MockPYT token3 = new MockPYT("T3", "T3", expiry3);

        // Mint and add tokens
        token1.mint(alice, 100e18);
        token2.mint(alice, 100e18);
        token3.mint(alice, 100e18);

        vm.startPrank(owner);
        locker.addSupportedToken(address(token1));
        locker.addSupportedToken(address(token2));
        locker.addSupportedToken(address(token3));
        vm.stopPrank();

        // Deposit all
        approveToken(alice, address(token1), 100e18);
        approveToken(alice, address(token2), 100e18);
        approveToken(alice, address(token3), 100e18);

        vm.startPrank(alice);
        locker.deposit(address(token1), 100e18);
        locker.deposit(address(token2), 100e18);
        locker.deposit(address(token3), 100e18);
        vm.stopPrank();

        // Verify expiry ordering
        vm.warp(expiry1 + 1);
        assertTrue(locker.isExpired(address(token1)));
        assertFalse(locker.isExpired(address(token2)));
        assertFalse(locker.isExpired(address(token3)));

        vm.warp(expiry2 + 1);
        assertTrue(locker.isExpired(address(token2)));
        assertFalse(locker.isExpired(address(token3)));

        vm.warp(expiry3 + 1);
        assertTrue(locker.isExpired(address(token3)));
    }

    // ============================================
    // Maximum Values Tests
    // ============================================

    /// @notice Test maximum amounts handling
    function test_maximumAmounts() public {
        addSupportedToken(address(pyt1));

        // Mint max tokens to alice
        uint256 maxAmount = type(uint128).max;
        pyt1.mint(alice, maxAmount);

        uint256 aliceBalance = pyt1.balanceOf(alice);

        // Deposit max amount
        approveToken(alice, address(pyt1), maxAmount);
        vm.prank(alice);
        locker.deposit(address(pyt1), maxAmount);

        assertEq(getLockedBalance(alice, address(pyt1)), maxAmount);

        // Advance and withdraw
        advanceToExpiry(address(pyt1));
        withdraw(alice, address(pyt1), maxAmount);

        // Alice should have her balance back
        assertEq(pyt1.balanceOf(alice), aliceBalance);
    }
}
