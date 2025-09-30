// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";

contract JaneTokenOwnershipTest is JaneSetup {
    function test_owner_canGrantTransferRole() public {
        assertFalse(token.hasTransferRole(alice));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit TransferRoleUpdated(alice, true);
        token.setTransferRole(alice, true);

        assertTrue(token.hasTransferRole(alice));
    }

    function test_owner_canRevokeTransferRole() public {
        vm.prank(owner);
        token.setTransferRole(alice, true);
        assertTrue(token.hasTransferRole(alice));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit TransferRoleUpdated(alice, false);
        token.setTransferRole(alice, false);

        assertFalse(token.hasTransferRole(alice));
    }

    function test_setMinter_success() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MinterUpdated(minter, newMinter);
        token.setMinter(newMinter);

        assertEq(token.minter(), newMinter);
    }

    function test_setMinter_revertsNonOwner() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(alice);
        vm.expectRevert();
        token.setMinter(newMinter);
    }

    function test_setMinter_allowsZeroAddress() public {
        vm.prank(owner);
        token.setMinter(address(0));

        assertEq(token.minter(), address(0));
    }

    function test_setMinter_functionalityWorks() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(owner);
        token.setMinter(newMinter);

        vm.prank(newMinter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);

        vm.prank(minter);
        vm.expectRevert(JaneToken.NotMinter.selector);
        token.mint(bob, 100e18);
    }

    function test_setBurner_success() public {
        address newBurner = makeAddr("newBurner");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit BurnerUpdated(burner, newBurner);
        token.setBurner(newBurner);

        assertEq(token.burner(), newBurner);
    }

    function test_setBurner_revertsNonOwner() public {
        address newBurner = makeAddr("newBurner");

        vm.prank(alice);
        vm.expectRevert();
        token.setBurner(newBurner);
    }

    function test_setBurner_allowsZeroAddress() public {
        vm.prank(owner);
        token.setBurner(address(0));

        assertEq(token.burner(), address(0));
    }

    function test_setBurner_functionalityWorks() public {
        address newBurner = makeAddr("newBurner");
        mintTokens(alice, 1000e18);

        vm.prank(owner);
        token.setBurner(newBurner);

        vm.prank(newBurner);
        token.burn(alice, 100e18);
        assertEq(token.balanceOf(alice), 900e18);

        vm.prank(burner);
        vm.expectRevert(JaneToken.NotBurner.selector);
        token.burn(alice, 100e18);
    }

    function test_ownership_canBeTransferred() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        token.transferOwnership(newOwner);

        assertEq(token.owner(), newOwner);
    }

    function test_nonOwner_cannotGrantTransferRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferRole(bob, true);
    }

    function test_nonOwner_cannotSetTransferable() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferable();
    }

    function test_nonOwner_cannotFinalizeMinting() public {
        vm.prank(alice);
        vm.expectRevert();
        token.finalizeMinting();
    }

    function test_multipleTransferRoles() public {
        vm.prank(owner);
        token.setTransferRole(alice, true);

        vm.prank(owner);
        token.setTransferRole(bob, true);

        vm.prank(owner);
        token.setTransferRole(charlie, true);

        assertTrue(token.hasTransferRole(alice));
        assertTrue(token.hasTransferRole(bob));
        assertTrue(token.hasTransferRole(charlie));

        // Revoke bob's role
        vm.prank(owner);
        token.setTransferRole(bob, false);

        assertTrue(token.hasTransferRole(alice));
        assertFalse(token.hasTransferRole(bob));
        assertTrue(token.hasTransferRole(charlie));
    }

    function testFuzz_transferRoleManagement(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != owner);

        assertFalse(token.hasTransferRole(user));

        vm.prank(owner);
        token.setTransferRole(user, true);
        assertTrue(token.hasTransferRole(user));

        vm.prank(owner);
        token.setTransferRole(user, false);
        assertFalse(token.hasTransferRole(user));
    }
}
