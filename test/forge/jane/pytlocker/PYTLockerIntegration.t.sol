// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PYTLockerSetup} from "./utils/PYTLockerSetup.sol";
import {PYTLocker, PYTLockerFactory} from "../../../../src/jane/PYTLocker.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPYT} from "./mocks/MockPYT.sol";

contract PYTLockerIntegrationTest is PYTLockerSetup {
    /// @notice Test complete lifecycle: deploy, deposit, wait, withdraw
    function test_completeLifecycle() public {
        // Step 1: Deploy factory and create locker
        MockPYT pyt = deployPYT("LIFECYCLE-PYT", "LPYT", 30 * DAY);
        address lockerAddr = factory.newPYTLocker(address(pyt));
        PYTLocker locker = PYTLocker(lockerAddr);

        // Fund users
        pyt.mint(alice, 1000e18);
        pyt.mint(bob, 500e18);

        // Step 2: User A deposits 1000 PYT tokens
        vm.startPrank(alice);
        pyt.approve(address(locker), 1000e18);
        locker.depositFor(alice, 1000e18);
        vm.stopPrank();

        assertEq(locker.balanceOf(alice), 1000e18);
        assertEq(pyt.balanceOf(alice), 0);

        // Step 3: User B deposits 500 PYT tokens
        vm.startPrank(bob);
        pyt.approve(address(locker), 500e18);
        locker.depositFor(bob, 500e18);
        vm.stopPrank();

        assertEq(locker.balanceOf(bob), 500e18);
        assertEq(pyt.balanceOf(bob), 0);

        // Step 4: Both users attempt withdrawal (should fail)
        vm.prank(alice);
        vm.expectRevert();
        locker.withdrawTo(alice, 1000e18);

        vm.prank(bob);
        vm.expectRevert();
        locker.withdrawTo(bob, 500e18);

        // Step 5: Warp time to expiry + 1 second
        advanceTime(30 * DAY + 1);

        // Step 6: User A withdraws 1000 PYT
        vm.prank(alice);
        locker.withdrawTo(alice, 1000e18);

        assertEq(locker.balanceOf(alice), 0);
        assertEq(pyt.balanceOf(alice), 1000e18);

        // Step 7: User B withdraws 500 PYT
        vm.prank(bob);
        locker.withdrawTo(bob, 500e18);

        assertEq(locker.balanceOf(bob), 0);
        assertEq(pyt.balanceOf(bob), 500e18);

        // Step 8: Verify all balances
        assertEq(locker.totalSupply(), 0);
        assertEq(pyt.balanceOf(address(locker)), 0);
    }

    /// @notice Test multi-user deposits and withdrawals
    function test_multiUserScenario() public {
        PYTLocker locker = deployLocker(pyt1);

        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1000e18; // alice
        amounts[1] = 2500e18; // bob
        amounts[2] = 750e18; // charlie
        amounts[3] = 5000e18; // dave

        address[4] memory users = [alice, bob, charlie, dave];

        // All users deposit
        for (uint256 i = 0; i < users.length; i++) {
            depositFor(locker, users[i], amounts[i]);
        }

        // Verify total supply
        uint256 totalDeposited = 1000e18 + 2500e18 + 750e18 + 5000e18;
        assertEq(locker.totalSupply(), totalDeposited);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Users withdraw in different order
        withdrawTo(locker, charlie, 750e18);
        withdrawTo(locker, alice, 1000e18);
        withdrawTo(locker, dave, 5000e18);
        withdrawTo(locker, bob, 2500e18);

        // Verify final state
        assertEq(locker.totalSupply(), 0);
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(locker.balanceOf(users[i]), 0);
        }
    }

    /// @notice Test transfer of wrapped tokens between users
    function test_wrappedTokenTransfer() public {
        PYTLocker locker = deployLocker(pyt2);

        // Alice deposits
        depositFor(locker, alice, 1000e18);

        // Alice transfers wrapped tokens to Bob
        vm.prank(alice);
        locker.transfer(bob, 400e18);

        assertEq(locker.balanceOf(alice), 600e18);
        assertEq(locker.balanceOf(bob), 400e18);

        // Advance past expiry
        advanceTime(91 * DAY);

        // Bob withdraws tokens he received
        vm.prank(bob);
        locker.withdrawTo(bob, 400e18);

        assertEq(pyt2.balanceOf(bob), INITIAL_BALANCE + 400e18);
        assertEq(locker.balanceOf(bob), 0);

        // Alice withdraws remaining
        vm.prank(alice);
        locker.withdrawTo(alice, 600e18);

        assertEq(pyt2.balanceOf(alice), INITIAL_BALANCE - 1000e18 + 600e18);
    }

    /// @notice Test multiple PYT tokens with different expiries
    function test_multiplePYTsWithDifferentExpiries() public {
        PYTLocker locker1 = deployLocker(pyt1); // 30 days
        PYTLocker locker2 = deployLocker(pyt2); // 90 days
        PYTLocker locker3 = deployLocker(pyt3); // 365 days

        // Deposit in all lockers
        depositFor(locker1, alice, 100e18);
        depositFor(locker2, alice, 200e18);
        depositFor(locker3, alice, 300e18);

        // After 30 days, only locker1 is withdrawable
        advanceTime(30 * DAY + 1);

        assertTrue(locker1.isExpired());
        assertFalse(locker2.isExpired());
        assertFalse(locker3.isExpired());

        // Withdraw from locker1
        vm.prank(alice);
        locker1.withdrawTo(alice, 100e18);

        // Cannot withdraw from locker2 and locker3
        vm.prank(alice);
        vm.expectRevert();
        locker2.withdrawTo(alice, 200e18);

        // After 90 days total, locker2 is also withdrawable
        advanceTime(60 * DAY + 1);

        assertTrue(locker2.isExpired());
        assertFalse(locker3.isExpired());

        vm.prank(alice);
        locker2.withdrawTo(alice, 200e18);

        // After 365 days total, all are withdrawable
        advanceTime(275 * DAY);

        assertTrue(locker3.isExpired());

        vm.prank(alice);
        locker3.withdrawTo(alice, 300e18);
    }

    /// @notice Test edge case: deposit and withdraw at expiry boundary
    function test_expiryBoundaryEdgeCase() public {
        MockPYT boundaryPYT = deployPYT("BOUNDARY-PYT", "BPYT", 1 * DAY);
        PYTLocker locker = PYTLocker(factory.newPYTLocker(address(boundaryPYT)));
        boundaryPYT.mint(alice, 1000e18);

        // Deposit just before expiry (1 second before)
        advanceTime(1 * DAY - 1);
        depositFor(locker, alice, 500e18);

        // Try to deposit at exact expiry (should fail)
        advanceTime(1);
        vm.startPrank(alice);
        boundaryPYT.approve(address(locker), 500e18);
        vm.expectRevert();
        locker.depositFor(alice, 500e18);
        vm.stopPrank();

        // But withdrawal should work
        vm.prank(alice);
        locker.withdrawTo(alice, 500e18);

        assertEq(boundaryPYT.balanceOf(alice), 1000e18);
    }

    /// @notice Test partial withdrawals scenario
    function test_partialWithdrawals() public {
        PYTLocker locker = deployLocker(pyt1);

        // Alice deposits 1000
        depositFor(locker, alice, 1000e18);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Alice makes multiple partial withdrawals
        uint256 aliceInitial = pyt1.balanceOf(alice);

        vm.startPrank(alice);
        locker.withdrawTo(alice, 100e18);
        assertEq(locker.balanceOf(alice), 900e18);

        locker.withdrawTo(alice, 200e18);
        assertEq(locker.balanceOf(alice), 700e18);

        locker.withdrawTo(alice, 300e18);
        assertEq(locker.balanceOf(alice), 400e18);

        locker.withdrawTo(alice, 400e18);
        assertEq(locker.balanceOf(alice), 0);
        vm.stopPrank();

        assertEq(pyt1.balanceOf(alice), aliceInitial + 1000e18);
    }

    /// @notice Test wrapped token recipient can withdraw
    function test_wrappedTokenRecipientWithdrawal() public {
        PYTLocker locker = deployLocker(pyt1);

        // Alice deposits and transfers to Bob
        depositFor(locker, alice, 1000e18);
        vm.prank(alice);
        locker.transfer(bob, 1000e18);

        assertEq(locker.balanceOf(alice), 0);
        assertEq(locker.balanceOf(bob), 1000e18);

        // Bob transfers to Charlie
        vm.prank(bob);
        locker.transfer(charlie, 500e18);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Charlie can withdraw even though he never deposited
        uint256 charlieInitial = pyt1.balanceOf(charlie);
        vm.prank(charlie);
        locker.withdrawTo(charlie, 500e18);

        assertEq(pyt1.balanceOf(charlie), charlieInitial + 500e18);
        assertEq(locker.balanceOf(charlie), 0);

        // Bob withdraws his remaining
        vm.prank(bob);
        locker.withdrawTo(bob, 500e18);
    }

    /// @notice Test gas costs for batch operations
    function test_batchOperationsGas() public {
        PYTLocker locker = deployLocker(pyt1);

        uint256 gasUsed;
        uint256 gasBefore;

        // Measure deposit gas
        gasBefore = gasleft();
        depositFor(locker, alice, 1000e18);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for single deposit", gasUsed);
        assertLt(gasUsed, 120_000);

        // Batch deposits
        gasBefore = gasleft();
        for (uint256 i = 0; i < 10; i++) {
            depositFor(locker, bob, 100e18);
        }
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for 10 deposits", gasUsed);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Measure withdrawal gas
        gasBefore = gasleft();
        withdrawTo(locker, alice, 1000e18);
        gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for single withdrawal", gasUsed);
        assertLt(gasUsed, 80_000);
    }

    /// @notice Fuzz test for random deposit/withdraw amounts
    function testFuzz_randomAmounts(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);
        PYTLocker locker = deployLocker(pyt1);

        // Deposit
        depositFor(locker, alice, depositAmount);
        assertEq(locker.balanceOf(alice), depositAmount);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Withdraw partial amount
        withdrawAmount = bound(withdrawAmount, 0, depositAmount);
        vm.prank(alice);
        locker.withdrawTo(alice, withdrawAmount);

        assertEq(locker.balanceOf(alice), depositAmount - withdrawAmount);
    }

    /// @notice Test maximum amounts handling
    function test_maximumAmounts() public {
        PYTLocker locker = deployLocker(pyt1);

        // Mint max tokens to alice (she already has INITIAL_BALANCE)
        uint256 maxAmount = type(uint128).max;
        pyt1.mint(alice, maxAmount);

        // Alice now has INITIAL_BALANCE + maxAmount
        uint256 aliceBalance = pyt1.balanceOf(alice);

        // Deposit max amount
        vm.startPrank(alice);
        pyt1.approve(address(locker), maxAmount);
        locker.depositFor(alice, maxAmount);
        vm.stopPrank();

        assertEq(locker.balanceOf(alice), maxAmount);

        // Advance and withdraw
        advanceTime(31 * DAY);

        vm.prank(alice);
        locker.withdrawTo(alice, maxAmount);

        // Alice should have her original balance back
        assertEq(pyt1.balanceOf(alice), aliceBalance);
    }

    /// @notice Test zero amount operations
    function test_zeroAmountOperations() public {
        PYTLocker locker = deployLocker(pyt1);

        // Zero deposit
        depositFor(locker, alice, 0);
        assertEq(locker.balanceOf(alice), 0);

        // Deposit some amount
        depositFor(locker, alice, 1000e18);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Zero withdrawal
        withdrawTo(locker, alice, 0);
        assertEq(locker.balanceOf(alice), 1000e18);
    }

    /// @notice Test multiple factories don't interfere
    function test_multipleFactoriesIsolation() public {
        PYTLockerFactory factory2 = new PYTLockerFactory();

        // Same PYT can have lockers in different factories
        address locker1 = factory.newPYTLocker(address(pyt1));
        address locker2 = factory2.newPYTLocker(address(pyt1));

        assertTrue(locker1 != locker2);
        assertEq(factory.getLocker(address(pyt1)), locker1);
        assertEq(factory2.getLocker(address(pyt1)), locker2);
    }
}
