// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";

contract JaneTokenTransferTest is JaneSetup {
    function setUp() public override {
        super.setUp();
        mintTokens(alice, 1000e18);
        mintTokens(bob, 1000e18);
    }

    function test_transfer_whenTransferableTrue() public {
        setTransferable();
        assertTrue(token.transferable());

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 100e18);
        assertTrue(token.transfer(bob, 100e18));

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(bob), 1100e18);
    }

    function test_transfer_whenTransferableFalse_senderHasRole() public {
        assertFalse(token.transferable());
        grantTransferRole(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, charlie, 100e18);
        assertTrue(token.transfer(charlie, 100e18));

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(charlie), 100e18);
    }

    function test_transfer_whenTransferableFalse_receiverHasRole() public {
        assertFalse(token.transferable());
        grantTransferRole(treasury);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, treasury, 100e18);
        assertTrue(token.transfer(treasury, 100e18));

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(treasury), 100e18);
    }

    function test_transfer_whenTransferableFalse_neitherHasRole() public {
        assertFalse(token.transferable());

        vm.prank(alice);
        vm.expectRevert(JaneToken.TransferNotAllowed.selector);
        token.transfer(charlie, 100e18);
    }

    function test_transferFrom_respectsRestrictions() public {
        assertFalse(token.transferable());

        vm.prank(alice);
        token.approve(charlie, 200e18);

        vm.prank(charlie);
        vm.expectRevert(JaneToken.TransferNotAllowed.selector);
        token.transferFrom(alice, bob, 100e18);

        grantTransferRole(bob);

        vm.prank(charlie);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 100e18);
        assertTrue(token.transferFrom(alice, bob, 100e18));

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(bob), 1100e18);
        assertEq(token.allowance(alice, charlie), 100e18);
    }

    function test_setTransferable_oneWay() public {
        assertFalse(token.transferable());

        setTransferable();
        assertTrue(token.transferable());

        vm.prank(owner);
        token.setTransferable();
        assertTrue(token.transferable());
    }

    function test_setTransferable_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TransferEnabled();
        token.setTransferable();
    }

    function test_transfer_zeroAmount() public {
        setTransferable();

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0);
        assertTrue(token.transfer(bob, 0));

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 1000e18);
    }

    function test_transfer_toSelf() public {
        setTransferable();

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, alice, 100e18);
        assertTrue(token.transfer(alice, 100e18));

        assertEq(token.balanceOf(alice), 1000e18);
    }

    function test_transfer_exceedsBalance() public {
        setTransferable();

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1001e18);
    }

    function testFuzz_transferScenarios(
        address from,
        address to,
        uint256 amount,
        bool grantRoleToSender,
        bool grantRoleToReceiver
    ) public {
        vm.assume(from != address(0) && to != address(0));
        vm.assume(from != minter && from != burner && from != owner);
        vm.assume(to != minter && to != burner && to != owner);
        // Exclude addresses that already have tokens from setUp
        vm.assume(from != alice && from != bob);
        vm.assume(to != alice && to != bob);
        vm.assume(amount <= 1000e18);

        mintTokens(from, 1000e18);

        if (grantRoleToSender) {
            grantTransferRole(from);
        }
        if (grantRoleToReceiver) {
            grantTransferRole(to);
        }

        bool shouldSucceed = grantRoleToSender || grantRoleToReceiver;

        vm.prank(from);
        if (shouldSucceed) {
            assertTrue(token.transfer(to, amount));
            if (from == to) {
                // Self-transfer doesn't change balance
                assertEq(token.balanceOf(from), 1000e18);
            } else {
                assertEq(token.balanceOf(to), amount);
                assertEq(token.balanceOf(from), 1000e18 - amount);
            }
        } else {
            vm.expectRevert(JaneToken.TransferNotAllowed.selector);
            token.transfer(to, amount);
        }
    }
}
