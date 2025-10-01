// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {Jane} from "../../../src/jane/Jane.sol";

contract JaneTokenOwnershipTest is JaneSetup {
    function test_owner_canGrantTransferRole() public {
        assertFalse(token.hasTransferRole(alice));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit TransferAuthorized(alice, true);
        token.addTransferRole(alice);

        assertTrue(token.hasTransferRole(alice));
    }

    function test_owner_canRevokeTransferRole() public {
        vm.prank(owner);
        token.addTransferRole(alice);
        assertTrue(token.hasTransferRole(alice));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit TransferAuthorized(alice, false);
        token.removeTransferRole(alice);

        assertFalse(token.hasTransferRole(alice));
    }

    function test_addMinter_success() public {
        address newMinter = makeAddr("newMinter");

        assertFalse(token.isMinter(newMinter));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MinterAuthorized(newMinter, true);
        token.addMinter(newMinter);

        assertTrue(token.isMinter(newMinter));
        assertEq(token.minters().length, 2); // minter + newMinter
    }

    function test_addMinter_revertsNonOwner() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(alice);
        vm.expectRevert();
        token.addMinter(newMinter);
    }

    function test_removeMinter_success() public {
        assertTrue(token.isMinter(minter));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MinterAuthorized(minter, false);
        token.removeMinter(minter);

        assertFalse(token.isMinter(minter));
        assertEq(token.minters().length, 0);
    }

    function test_removeMinter_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.removeMinter(minter);
    }

    function test_minter_functionalityWorks() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(owner);
        token.addMinter(newMinter);

        vm.prank(newMinter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);

        vm.prank(owner);
        token.removeMinter(minter);

        vm.prank(minter);
        vm.expectRevert(Jane.NotMinter.selector);
        token.mint(bob, 100e18);
    }

    function test_addBurner_success() public {
        address newBurner = makeAddr("newBurner");

        assertFalse(token.isBurner(newBurner));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit BurnerAuthorized(newBurner, true);
        token.addBurner(newBurner);

        assertTrue(token.isBurner(newBurner));
        assertEq(token.burners().length, 2); // burner + newBurner
    }

    function test_addBurner_revertsNonOwner() public {
        address newBurner = makeAddr("newBurner");

        vm.prank(alice);
        vm.expectRevert();
        token.addBurner(newBurner);
    }

    function test_removeBurner_success() public {
        assertTrue(token.isBurner(burner));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit BurnerAuthorized(burner, false);
        token.removeBurner(burner);

        assertFalse(token.isBurner(burner));
        assertEq(token.burners().length, 0);
    }

    function test_removeBurner_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.removeBurner(burner);
    }

    function test_burner_functionalityWorks() public {
        address newBurner = makeAddr("newBurner");
        mintTokens(alice, 1000e18);

        vm.prank(owner);
        token.addBurner(newBurner);

        vm.prank(newBurner);
        token.burn(alice, 100e18);
        assertEq(token.balanceOf(alice), 900e18);

        vm.prank(owner);
        token.removeBurner(burner);

        vm.prank(burner);
        vm.expectRevert(Jane.NotBurner.selector);
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
        token.addTransferRole(bob);
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
        token.addTransferRole(alice);

        vm.prank(owner);
        token.addTransferRole(bob);

        vm.prank(owner);
        token.addTransferRole(charlie);

        assertTrue(token.hasTransferRole(alice));
        assertTrue(token.hasTransferRole(bob));
        assertTrue(token.hasTransferRole(charlie));
        assertEq(token.transferAuthorized().length, 3);

        // Revoke bob's role
        vm.prank(owner);
        token.removeTransferRole(bob);

        assertTrue(token.hasTransferRole(alice));
        assertFalse(token.hasTransferRole(bob));
        assertTrue(token.hasTransferRole(charlie));
        assertEq(token.transferAuthorized().length, 2);
    }

    function testFuzz_transferRoleManagement(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != owner);

        assertFalse(token.hasTransferRole(user));

        vm.prank(owner);
        token.addTransferRole(user);
        assertTrue(token.hasTransferRole(user));

        vm.prank(owner);
        token.removeTransferRole(user);
        assertFalse(token.hasTransferRole(user));
    }
}
