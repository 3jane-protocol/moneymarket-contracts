// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PYTLockerSetup} from "./utils/PYTLockerSetup.sol";
import {PYTLocker, InvalidAddress, PYTNotExpired, PYTAlreadyExpired} from "../../../../src/jane/PYTLocker.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../../../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockPYT} from "./mocks/MockPYT.sol";

contract PYTLockerUnitTest is PYTLockerSetup {
    PYTLocker public locker1;
    PYTLocker public locker2;

    function setUp() public override {
        super.setUp();
        // Deploy lockers for testing
        locker1 = deployLocker(pyt1);
        locker2 = deployLocker(pyt2);
    }

    /// @notice Test successful constructor with valid non-expired PYT
    function test_constructor_validPYT() public {
        // Locker should be deployed successfully
        assertTrue(address(locker1) != address(0));
        assertEq(address(locker1.underlying()), address(pyt1));
    }

    /// @notice Test constructor reverts with zero address
    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert();
        new PYTLocker(IERC20Metadata(address(0)));
    }

    /// @notice Test constructor reverts with already expired PYT
    function test_constructor_revertsExpiredPYT() public {
        MockPYT expiredPYT = createExpiredPYT();
        vm.expectRevert(PYTAlreadyExpired.selector);
        new PYTLocker(IERC20Metadata(address(expiredPYT)));
    }

    /// @notice Test correct name and symbol generation
    function test_constructor_correctNameSymbol() public {
        assertEq(locker1.name(), "lPYT30");
        assertEq(locker1.symbol(), "lPYT30");
        assertEq(locker2.name(), "lPYT90");
        assertEq(locker2.symbol(), "lPYT90");
    }

    /// @notice Test successful deposit before expiry
    function test_depositFor_beforeExpiry() public {
        uint256 depositAmount = 1000e18;
        uint256 aliceBalanceBefore = pyt1.balanceOf(alice);

        vm.startPrank(alice);
        pyt1.approve(address(locker1), depositAmount);

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, depositAmount);

        bool success = locker1.depositFor(alice, depositAmount);
        vm.stopPrank();

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), depositAmount);
        assertEq(pyt1.balanceOf(alice), aliceBalanceBefore - depositAmount);
        assertEq(pyt1.balanceOf(address(locker1)), depositAmount);
    }

    /// @notice Test deposit reverts after expiry
    function test_depositFor_revertsAfterExpiry() public {
        uint256 depositAmount = 1000e18;

        // Advance time past expiry
        advanceTime(31 * DAY);

        vm.startPrank(alice);
        pyt1.approve(address(locker1), depositAmount);

        vm.expectRevert(PYTAlreadyExpired.selector);
        locker1.depositFor(alice, depositAmount);
        vm.stopPrank();
    }

    /// @notice Test deposit for another user
    function test_depositFor_anotherUser() public {
        uint256 depositAmount = 500e18;

        vm.startPrank(alice);
        pyt1.approve(address(locker1), depositAmount);
        bool success = locker1.depositFor(bob, depositAmount);
        vm.stopPrank();

        assertTrue(success);
        assertEq(locker1.balanceOf(bob), depositAmount);
        assertEq(locker1.balanceOf(alice), 0);
    }

    /// @notice Test withdrawal reverts before expiry
    function test_withdrawTo_revertsBeforeExpiry() public {
        uint256 amount = 1000e18;

        // First deposit
        depositFor(locker1, alice, amount);

        // Try to withdraw before expiry
        vm.prank(alice);
        vm.expectRevert(PYTNotExpired.selector);
        locker1.withdrawTo(alice, amount);
    }

    /// @notice Test successful withdrawal after expiry
    function test_withdrawTo_afterExpiry() public {
        uint256 amount = 1000e18;

        // Deposit first
        depositFor(locker1, alice, amount);

        // Advance time past expiry
        advanceTime(31 * DAY);

        uint256 aliceBalanceBefore = pyt1.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), amount);

        bool success = locker1.withdrawTo(alice, amount);

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), 0);
        assertEq(pyt1.balanceOf(alice), aliceBalanceBefore + amount);
        assertEq(pyt1.balanceOf(address(locker1)), 0);
    }

    /// @notice Test withdrawal to another user
    function test_withdrawTo_anotherUser() public {
        uint256 amount = 750e18;

        // Deposit first
        depositFor(locker1, alice, amount);

        // Advance time past expiry
        advanceTime(31 * DAY);

        uint256 bobBalanceBefore = pyt1.balanceOf(bob);

        vm.prank(alice);
        bool success = locker1.withdrawTo(bob, amount);

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), 0);
        assertEq(pyt1.balanceOf(bob), bobBalanceBefore + amount);
    }

    /// @notice Test isExpired returns false before expiry
    function test_isExpired_beforeExpiry() public view {
        assertFalse(locker1.isExpired());
        assertFalse(locker2.isExpired());
    }

    /// @notice Test isExpired returns true after expiry
    function test_isExpired_afterExpiry() public {
        // Advance past first locker expiry but not second
        advanceTime(31 * DAY);
        assertTrue(locker1.isExpired());
        assertFalse(locker2.isExpired());

        // Advance past second locker expiry
        advanceTime(60 * DAY);
        assertTrue(locker2.isExpired());
    }

    /// @notice Test isExpired at exact expiry timestamp
    function test_isExpired_atExactExpiry() public {
        uint256 expiryTime = locker1.expiry();
        warpTo(expiryTime);
        assertTrue(locker1.isExpired());
    }

    /// @notice Test timeUntilExpiry before expiry
    function test_timeUntilExpiry_beforeExpiry() public {
        uint256 timeLeft = locker1.timeUntilExpiry();
        assertGt(timeLeft, 29 * DAY);
        assertLe(timeLeft, 30 * DAY);
    }

    /// @notice Test timeUntilExpiry returns 0 after expiry
    function test_timeUntilExpiry_afterExpiry() public {
        advanceTime(31 * DAY);
        assertEq(locker1.timeUntilExpiry(), 0);
    }

    /// @notice Test timeUntilExpiry at exact expiry
    function test_timeUntilExpiry_atExactExpiry() public {
        uint256 expiryTime = locker1.expiry();
        warpTo(expiryTime);
        assertEq(locker1.timeUntilExpiry(), 0);
    }

    /// @notice Test expiry returns correct timestamp
    function test_expiry_returnsCorrectTimestamp() public {
        uint256 expectedExpiry = pyt1.expiry();
        assertEq(locker1.expiry(), expectedExpiry);
    }

    /// @notice Test decimals inheritance from underlying
    function test_decimals_inheritsFromUnderlying() public view {
        assertEq(locker1.decimals(), pyt1.decimals());
        assertEq(locker1.decimals(), 18);
    }

    /// @notice Test zero amount deposit
    function test_depositFor_zeroAmount() public {
        vm.startPrank(alice);
        pyt1.approve(address(locker1), 0);
        bool success = locker1.depositFor(alice, 0);
        vm.stopPrank();

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), 0);
    }

    /// @notice Test zero amount withdrawal
    function test_withdrawTo_zeroAmount() public {
        // First deposit some tokens
        depositFor(locker1, alice, 1000e18);

        // Advance past expiry
        advanceTime(31 * DAY);

        vm.prank(alice);
        bool success = locker1.withdrawTo(alice, 0);

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), 1000e18);
    }

    /// @notice Test partial withdrawal after expiry
    function test_withdrawTo_partialAmount() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 300e18;

        // Deposit
        depositFor(locker1, alice, depositAmount);

        // Advance past expiry
        advanceTime(31 * DAY);

        // Partial withdrawal
        vm.prank(alice);
        bool success = locker1.withdrawTo(alice, withdrawAmount);

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), depositAmount - withdrawAmount);
        assertEq(pyt1.balanceOf(address(locker1)), depositAmount - withdrawAmount);
    }

    /// @notice Test multiple deposits from same user
    function test_depositFor_multipleDeposits() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        uint256 amount3 = 300e18;

        depositFor(locker1, alice, amount1);
        depositFor(locker1, alice, amount2);
        depositFor(locker1, alice, amount3);

        uint256 totalDeposited = amount1 + amount2 + amount3;
        assertEq(locker1.balanceOf(alice), totalDeposited);
        assertEq(pyt1.balanceOf(address(locker1)), totalDeposited);
    }

    /// @notice Test deposit at exact expiry timestamp should fail
    function test_depositFor_atExactExpiry() public {
        uint256 expiryTime = locker1.expiry();
        warpTo(expiryTime);

        vm.startPrank(alice);
        pyt1.approve(address(locker1), 1000e18);

        vm.expectRevert(PYTAlreadyExpired.selector);
        locker1.depositFor(alice, 1000e18);
        vm.stopPrank();
    }

    /// @notice Test withdraw at exact expiry timestamp should succeed
    function test_withdrawTo_atExactExpiry() public {
        uint256 amount = 1000e18;

        // Deposit first
        depositFor(locker1, alice, amount);

        // Warp to exact expiry
        uint256 expiryTime = locker1.expiry();
        warpTo(expiryTime);

        // Should be able to withdraw
        vm.prank(alice);
        bool success = locker1.withdrawTo(alice, amount);

        assertTrue(success);
        assertEq(locker1.balanceOf(alice), 0);
    }

    /// @notice Test total supply tracking
    function test_totalSupply_tracking() public {
        assertEq(locker1.totalSupply(), 0);

        depositFor(locker1, alice, 100e18);
        assertEq(locker1.totalSupply(), 100e18);

        depositFor(locker1, bob, 200e18);
        assertEq(locker1.totalSupply(), 300e18);

        // Advance past expiry and withdraw
        advanceTime(31 * DAY);

        withdrawTo(locker1, alice, 100e18);
        assertEq(locker1.totalSupply(), 200e18);

        withdrawTo(locker1, bob, 200e18);
        assertEq(locker1.totalSupply(), 0);
    }
}
