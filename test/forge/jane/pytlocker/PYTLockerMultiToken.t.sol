// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PYTLockerSetup} from "./utils/PYTLockerSetup.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../../../lib/openzeppelin/contracts/access/Ownable.sol";
import {MockPYT} from "./mocks/MockPYT.sol";

contract PYTLockerMultiTokenTest is PYTLockerSetup {
    // ============================================
    // Test Owner Functionality & Token Management
    // ============================================

    function test_addSupportedToken_success() public {
        // Add first token
        vm.expectEmit(true, false, false, true);
        emit TokenAdded(address(pyt1), futureExpiry1);
        addSupportedToken(address(pyt1));

        assertTrue(locker.isSupported(address(pyt1)));
        assertEq(locker.supportedTokenCount(), 1);
        assertEq(locker.supportedTokenAt(0), address(pyt1));
    }

    function test_addMultipleTokens_success() public {
        addMultipleTokens();

        assertEq(locker.supportedTokenCount(), 3);
        assertTrue(locker.isSupported(address(pyt1)));
        assertTrue(locker.isSupported(address(pyt2)));
        assertTrue(locker.isSupported(address(pyt3)));

        // Check enumeration
        address[] memory tokens = locker.getSupportedTokens();
        assertEq(tokens.length, 3);
        assertEq(tokens[0], address(pyt1));
        assertEq(tokens[1], address(pyt2));
        assertEq(tokens[2], address(pyt3));
    }

    function test_addSupportedToken_revertsAlreadySupported() public {
        addSupportedToken(address(pyt1));

        vm.expectRevert(PYTLocker.TokenAlreadySupported.selector);
        addSupportedToken(address(pyt1));
    }

    function test_addSupportedToken_revertsExpiredToken() public {
        vm.expectRevert(PYTLocker.TokenExpired.selector);
        addSupportedToken(address(expiredPyt));
    }

    function test_addSupportedToken_revertsZeroAddress() public {
        vm.expectRevert(PYTLocker.InvalidToken.selector);
        addSupportedToken(address(0));
    }

    function test_addSupportedToken_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        locker.addSupportedToken(address(pyt1));
    }

    // ============================================
    // Test Multi-Token Deposit Functionality
    // ============================================

    function test_deposit_singleToken() public {
        addSupportedToken(address(pyt1));

        uint256 depositAmount = 100e18;
        uint256 balanceBefore = getTokenBalance(alice, address(pyt1));

        approveToken(alice, address(pyt1), depositAmount);
        vm.expectEmit(true, true, false, true, address(locker));
        emit Deposit(address(pyt1), alice, depositAmount);
        vm.prank(alice);
        locker.deposit(address(pyt1), depositAmount);

        assertEq(getLockedBalance(alice, address(pyt1)), depositAmount);
        assertEq(locker.totalSupply(address(pyt1)), depositAmount);
        assertEq(getTokenBalance(alice, address(pyt1)), balanceBefore - depositAmount);
    }

    function test_deposit_multipleTokens() public {
        addMultipleTokens();

        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        uint256 amount3 = 300e18;

        deposit(alice, address(pyt1), amount1);
        deposit(alice, address(pyt2), amount2);
        deposit(alice, address(pyt3), amount3);

        assertEq(getLockedBalance(alice, address(pyt1)), amount1);
        assertEq(getLockedBalance(alice, address(pyt2)), amount2);
        assertEq(getLockedBalance(alice, address(pyt3)), amount3);

        assertEq(locker.totalSupply(address(pyt1)), amount1);
        assertEq(locker.totalSupply(address(pyt2)), amount2);
        assertEq(locker.totalSupply(address(pyt3)), amount3);
    }

    function test_deposit_multipleUsers() public {
        addSupportedToken(address(pyt1));

        uint256 aliceAmount = 100e18;
        uint256 bobAmount = 200e18;
        uint256 charlieAmount = 150e18;

        deposit(alice, address(pyt1), aliceAmount);
        deposit(bob, address(pyt1), bobAmount);
        deposit(charlie, address(pyt1), charlieAmount);

        assertEq(getLockedBalance(alice, address(pyt1)), aliceAmount);
        assertEq(getLockedBalance(bob, address(pyt1)), bobAmount);
        assertEq(getLockedBalance(charlie, address(pyt1)), charlieAmount);
        assertEq(locker.totalSupply(address(pyt1)), aliceAmount + bobAmount + charlieAmount);
    }

    function test_deposit_revertsUnsupportedToken() public {
        approveToken(alice, address(pyt1), 100e18);
        vm.expectRevert(PYTLocker.TokenNotSupported.selector);
        vm.prank(alice);
        locker.deposit(address(pyt1), 100e18);
    }

    function test_deposit_revertsZeroAmount() public {
        addSupportedToken(address(pyt1));

        approveToken(alice, address(pyt1), 100e18);
        vm.expectRevert(PYTLocker.ZeroAmount.selector);
        vm.prank(alice);
        locker.deposit(address(pyt1), 0);
    }

    function test_deposit_revertsExpiredToken() public {
        addSupportedToken(address(pyt1));

        // Advance time past expiry
        advanceToExpiry(address(pyt1));

        approveToken(alice, address(pyt1), 100e18);
        vm.expectRevert(PYTLocker.TokenExpired.selector);
        vm.prank(alice);
        locker.deposit(address(pyt1), 100e18);
    }

    // ============================================
    // Test Multi-Token Withdrawal Functionality
    // ============================================

    function test_withdraw_afterExpiry() public {
        addSupportedToken(address(pyt1));

        uint256 depositAmount = 100e18;
        deposit(alice, address(pyt1), depositAmount);

        // Cannot withdraw before expiry
        vm.expectRevert(PYTLocker.TokenNotExpired.selector);
        withdraw(alice, address(pyt1), depositAmount);

        // Advance to expiry
        advanceToExpiry(address(pyt1));

        uint256 balanceBefore = getTokenBalance(alice, address(pyt1));

        vm.expectEmit(true, true, false, true);
        emit Withdraw(address(pyt1), alice, depositAmount);
        withdraw(alice, address(pyt1), depositAmount);

        assertEq(getLockedBalance(alice, address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(getTokenBalance(alice, address(pyt1)), balanceBefore + depositAmount);
    }

    function test_withdraw_partialAmount() public {
        addSupportedToken(address(pyt1));

        uint256 depositAmount = 100e18;
        deposit(alice, address(pyt1), depositAmount);

        advanceToExpiry(address(pyt1));

        uint256 withdrawAmount = 60e18;
        withdraw(alice, address(pyt1), withdrawAmount);

        assertEq(getLockedBalance(alice, address(pyt1)), depositAmount - withdrawAmount);
        assertEq(locker.totalSupply(address(pyt1)), depositAmount - withdrawAmount);
    }

    function test_withdraw_revertsInsufficientBalance() public {
        addSupportedToken(address(pyt1));

        deposit(alice, address(pyt1), 100e18);
        advanceToExpiry(address(pyt1));

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        withdraw(alice, address(pyt1), 200e18);
    }

    function test_withdraw_revertsZeroAmount() public {
        addSupportedToken(address(pyt1));

        deposit(alice, address(pyt1), 100e18);
        advanceToExpiry(address(pyt1));

        vm.expectRevert(PYTLocker.ZeroAmount.selector);
        withdraw(alice, address(pyt1), 0);
    }

    function test_withdraw_revertsBeforeExpiry() public {
        addSupportedToken(address(pyt1));

        deposit(alice, address(pyt1), 100e18);

        vm.expectRevert(PYTLocker.TokenNotExpired.selector);
        withdraw(alice, address(pyt1), 100e18);
    }

    // ============================================
    // Test Token Isolation
    // ============================================

    function test_tokenIsolation_deposits() public {
        addMultipleTokens();

        // Alice deposits in pyt1 and pyt2
        deposit(alice, address(pyt1), 100e18);
        deposit(alice, address(pyt2), 200e18);

        // Bob deposits in pyt2 and pyt3
        deposit(bob, address(pyt2), 150e18);
        deposit(bob, address(pyt3), 250e18);

        // Check balances are isolated
        assertEq(getLockedBalance(alice, address(pyt1)), 100e18);
        assertEq(getLockedBalance(alice, address(pyt2)), 200e18);
        assertEq(getLockedBalance(alice, address(pyt3)), 0);

        assertEq(getLockedBalance(bob, address(pyt1)), 0);
        assertEq(getLockedBalance(bob, address(pyt2)), 150e18);
        assertEq(getLockedBalance(bob, address(pyt3)), 250e18);

        // Check total supplies
        assertEq(locker.totalSupply(address(pyt1)), 100e18);
        assertEq(locker.totalSupply(address(pyt2)), 350e18);
        assertEq(locker.totalSupply(address(pyt3)), 250e18);
    }

    function test_tokenIsolation_withdrawals() public {
        addMultipleTokens();

        // Setup deposits
        deposit(alice, address(pyt1), 100e18);
        deposit(alice, address(pyt2), 200e18);
        deposit(bob, address(pyt1), 150e18);

        // Advance pyt1 to expiry
        advanceToExpiry(address(pyt1));

        // Alice withdraws from pyt1
        withdraw(alice, address(pyt1), 100e18);

        // Verify isolation
        assertEq(getLockedBalance(alice, address(pyt1)), 0);
        assertEq(getLockedBalance(alice, address(pyt2)), 200e18);
        assertEq(getLockedBalance(bob, address(pyt1)), 150e18);

        // Cannot withdraw pyt2 (not expired)
        vm.expectRevert(PYTLocker.TokenNotExpired.selector);
        withdraw(alice, address(pyt2), 200e18);

        // Bob can still withdraw pyt1
        withdraw(bob, address(pyt1), 150e18);
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), 200e18);
    }

    // ============================================
    // Test View Functions
    // ============================================

    function test_viewFunctions_expiry() public {
        addSupportedToken(address(pyt1));

        // Test expiry
        assertEq(locker.expiry(address(pyt1)), futureExpiry1);
        assertFalse(locker.isExpired(address(pyt1)));

        // Test timeUntilExpiry
        uint256 timeLeft = locker.timeUntilExpiry(address(pyt1));
        assertGt(timeLeft, 0);
        assertLe(timeLeft, ONE_WEEK);

        // After expiry
        advanceToExpiry(address(pyt1));
        assertTrue(locker.isExpired(address(pyt1)));
        assertEq(locker.timeUntilExpiry(address(pyt1)), 0);
    }

    function test_viewFunctions_unsupportedToken() public view {
        // isSupported correctly returns false for unsupported tokens
        assertFalse(locker.isSupported(address(pyt1)));
        assertFalse(locker.isSupported(address(pyt2)));
        assertFalse(locker.isSupported(address(0)));
    }

    function test_viewFunctions_enumeration() public {
        // Empty state
        assertEq(locker.supportedTokenCount(), 0);

        // Add tokens
        addSupportedToken(address(pyt1));
        assertEq(locker.supportedTokenCount(), 1);
        assertEq(locker.supportedTokenAt(0), address(pyt1));

        addSupportedToken(address(pyt2));
        assertEq(locker.supportedTokenCount(), 2);
        assertEq(locker.supportedTokenAt(1), address(pyt2));

        // Get all tokens
        address[] memory allTokens = locker.getSupportedTokens();
        assertEq(allTokens.length, 2);
        assertEq(allTokens[0], address(pyt1));
        assertEq(allTokens[1], address(pyt2));
    }

    // ============================================
    // Complex Multi-Token Scenarios
    // ============================================

    function test_complexScenario_staggeredExpiries() public {
        addMultipleTokens();

        // Multiple users deposit in multiple tokens
        deposit(alice, address(pyt1), 100e18);
        deposit(alice, address(pyt2), 150e18);
        deposit(bob, address(pyt1), 200e18);
        deposit(bob, address(pyt3), 300e18);
        deposit(charlie, address(pyt2), 250e18);
        deposit(charlie, address(pyt3), 350e18);

        // Check total supplies
        assertEq(locker.totalSupply(address(pyt1)), 300e18);
        assertEq(locker.totalSupply(address(pyt2)), 400e18);
        assertEq(locker.totalSupply(address(pyt3)), 650e18);

        // pyt1 expires first (1 week)
        advanceToExpiry(address(pyt1));
        assertTrue(locker.isExpired(address(pyt1)));
        assertFalse(locker.isExpired(address(pyt2)));
        assertFalse(locker.isExpired(address(pyt3)));

        // Alice and Bob withdraw pyt1
        withdraw(alice, address(pyt1), 100e18);
        withdraw(bob, address(pyt1), 200e18);
        assertEq(locker.totalSupply(address(pyt1)), 0);

        // pyt2 expires (1 month)
        advanceToExpiry(address(pyt2));
        assertTrue(locker.isExpired(address(pyt2)));

        // Partial withdrawals from pyt2
        withdraw(alice, address(pyt2), 50e18);
        withdraw(charlie, address(pyt2), 100e18);
        assertEq(locker.totalSupply(address(pyt2)), 250e18);

        // Verify pyt3 still locked
        vm.expectRevert(PYTLocker.TokenNotExpired.selector);
        withdraw(bob, address(pyt3), 300e18);

        // Advance to pyt3 expiry (2 months)
        advanceToExpiry(address(pyt3));

        // Final withdrawals
        withdraw(alice, address(pyt2), 100e18); // Remaining pyt2
        withdraw(charlie, address(pyt2), 150e18); // Remaining pyt2
        withdraw(bob, address(pyt3), 300e18);
        withdraw(charlie, address(pyt3), 350e18);

        // Verify all cleared
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), 0);
        assertEq(locker.totalSupply(address(pyt3)), 0);
    }

    function test_complexScenario_dynamicTokenAddition() public {
        // Start with no tokens
        assertEq(locker.supportedTokenCount(), 0);

        // Add first token and deposit
        addSupportedToken(address(pyt1));
        deposit(alice, address(pyt1), 100e18);

        // Advance some time
        advanceTime(ONE_DAY * 3);

        // Add second token and deposit
        addSupportedToken(address(pyt2));
        deposit(bob, address(pyt2), 200e18);
        deposit(alice, address(pyt2), 150e18);

        // First token expires
        advanceToExpiry(address(pyt1));

        // Add third token after first expired
        addSupportedToken(address(pyt3));
        deposit(charlie, address(pyt3), 300e18);

        // Withdraw from expired token
        withdraw(alice, address(pyt1), 100e18);

        // Verify state
        assertEq(locker.supportedTokenCount(), 3);
        assertEq(locker.totalSupply(address(pyt1)), 0);
        assertEq(locker.totalSupply(address(pyt2)), 350e18);
        assertEq(locker.totalSupply(address(pyt3)), 300e18);
    }

    // ============================================
    // Gas Benchmarking
    // ============================================

    function test_gas_addMultipleTokens() public {
        uint256 gasStart;
        uint256 gasUsed;

        // Measure gas for adding 10 tokens
        MockPYT[] memory tokens = new MockPYT[](10);
        for (uint256 i = 0; i < 10; i++) {
            tokens[i] = createMockPYT(
                string.concat("PYT", vm.toString(i)),
                string.concat("P", vm.toString(i)),
                block.timestamp + ONE_WEEK * (i + 1)
            );

            gasStart = gasleft();
            vm.prank(owner);
            locker.addSupportedToken(address(tokens[i]));
            gasUsed = gasStart - gasleft();

            assertTrue(gasUsed < 100000, "addSupportedToken gas too high");
        }
    }

    function test_gas_depositAndWithdraw() public {
        addSupportedToken(address(pyt1));

        uint256 gasStart;
        uint256 gasUsed;

        // Measure deposit gas
        approveToken(alice, address(pyt1), 100e18);
        gasStart = gasleft();
        vm.prank(alice);
        locker.deposit(address(pyt1), 100e18);
        gasUsed = gasStart - gasleft();
        assertTrue(gasUsed < 120000, "deposit gas too high");

        // Measure withdraw gas
        advanceToExpiry(address(pyt1));
        gasStart = gasleft();
        vm.prank(alice);
        locker.withdraw(address(pyt1), 100e18);
        gasUsed = gasStart - gasleft();
        assertTrue(gasUsed < 80000, "withdraw gas too high");
    }

    // ============================================
    // Helper Functions
    // ============================================

    function createMockPYT(string memory name, string memory symbol, uint256 expiry) internal returns (MockPYT) {
        return new MockPYT(name, symbol, expiry);
    }
}
