// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {Jane} from "../../../src/jane/Jane.sol";

contract JaneTokenOwnershipTest is JaneSetup {
    function test_admin_canGrantTransferRole() public {
        assertFalse(token.hasRole(TRANSFER_ROLE, alice));

        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, alice);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
    }

    function test_admin_canRevokeTransferRole() public {
        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, alice);
        assertTrue(token.hasRole(TRANSFER_ROLE, alice));

        vm.prank(owner);
        token.revokeRole(TRANSFER_ROLE, alice);

        assertFalse(token.hasRole(TRANSFER_ROLE, alice));
    }

    function test_addMinter_success() public {
        address newMinter = makeAddr("newMinter");

        assertFalse(token.hasRole(MINTER_ROLE, newMinter));

        vm.prank(owner);
        token.grantRole(MINTER_ROLE, newMinter);

        assertTrue(token.hasRole(MINTER_ROLE, newMinter));
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 2); // minter + newMinter
    }

    function test_addMinter_revertsNonAdmin() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(alice);
        vm.expectRevert();
        token.grantRole(MINTER_ROLE, newMinter);
    }

    function test_removeMinter_success() public {
        assertTrue(token.hasRole(MINTER_ROLE, minter));

        vm.prank(owner);
        token.revokeRole(MINTER_ROLE, minter);

        assertFalse(token.hasRole(MINTER_ROLE, minter));
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 0);
    }

    function test_removeMinter_revertsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.revokeRole(MINTER_ROLE, minter);
    }

    function test_minter_functionalityWorks() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(owner);
        token.grantRole(MINTER_ROLE, newMinter);

        vm.prank(newMinter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);

        vm.prank(owner);
        token.revokeRole(MINTER_ROLE, minter);

        vm.prank(minter);
        vm.expectRevert();
        token.mint(bob, 100e18);
    }

    function test_addBurner_success() public {
        address newBurner = makeAddr("newBurner");

        assertFalse(token.hasRole(BURNER_ROLE, newBurner));

        vm.prank(owner);
        token.grantRole(BURNER_ROLE, newBurner);

        assertTrue(token.hasRole(BURNER_ROLE, newBurner));
        assertEq(token.getRoleMemberCount(BURNER_ROLE), 2); // burner + newBurner
    }

    function test_addBurner_revertsNonAdmin() public {
        address newBurner = makeAddr("newBurner");

        vm.prank(alice);
        vm.expectRevert();
        token.grantRole(BURNER_ROLE, newBurner);
    }

    function test_removeBurner_success() public {
        assertTrue(token.hasRole(BURNER_ROLE, burner));

        vm.prank(owner);
        token.revokeRole(BURNER_ROLE, burner);

        assertFalse(token.hasRole(BURNER_ROLE, burner));
        assertEq(token.getRoleMemberCount(BURNER_ROLE), 0);
    }

    function test_removeBurner_revertsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.revokeRole(BURNER_ROLE, burner);
    }

    function test_burner_functionalityWorks() public {
        address newBurner = makeAddr("newBurner");
        mintTokens(alice, 1000e18);

        vm.prank(owner);
        token.grantRole(BURNER_ROLE, newBurner);

        vm.prank(newBurner);
        token.burn(alice, 100e18);
        assertEq(token.balanceOf(alice), 900e18);

        vm.prank(owner);
        token.revokeRole(BURNER_ROLE, burner);

        vm.prank(burner);
        vm.expectRevert();
        token.burn(alice, 100e18);
    }

    function test_admin_canBeTransferred() public {
        address newAdmin = makeAddr("newAdmin");

        assertEq(token.admin(), owner);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit AdminTransferred(owner, newAdmin);
        token.transferAdmin(newAdmin);

        assertEq(token.admin(), newAdmin);
        assertFalse(token.hasRole(ADMIN_ROLE, owner));
        assertTrue(token.hasRole(ADMIN_ROLE, newAdmin));
    }

    function test_transferAdmin_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Jane.InvalidAddress.selector);
        token.transferAdmin(address(0));
    }

    function test_transferAdmin_revertsNonAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(alice);
        vm.expectRevert();
        token.transferAdmin(newAdmin);
    }

    function test_admin_accessor() public view {
        assertEq(token.admin(), owner);
    }

    function test_nonAdmin_cannotGrantTransferRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.grantRole(TRANSFER_ROLE, bob);
    }

    function test_nonAdmin_cannotSetTransferable() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferable();
    }

    function test_nonAdmin_cannotFinalizeMinting() public {
        vm.prank(alice);
        vm.expectRevert();
        token.finalizeMinting();
    }

    function test_multipleTransferRoles() public {
        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, alice);

        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, bob);

        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, charlie);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
        assertTrue(token.hasRole(TRANSFER_ROLE, bob));
        assertTrue(token.hasRole(TRANSFER_ROLE, charlie));
        assertEq(token.getRoleMemberCount(TRANSFER_ROLE), 3);

        // Revoke bob's role
        vm.prank(owner);
        token.revokeRole(TRANSFER_ROLE, bob);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
        assertFalse(token.hasRole(TRANSFER_ROLE, bob));
        assertTrue(token.hasRole(TRANSFER_ROLE, charlie));
        assertEq(token.getRoleMemberCount(TRANSFER_ROLE), 2);
    }

    function testFuzz_transferRoleManagement(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != owner);

        assertFalse(token.hasRole(TRANSFER_ROLE, user));

        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, user);
        assertTrue(token.hasRole(TRANSFER_ROLE, user));

        vm.prank(owner);
        token.revokeRole(TRANSFER_ROLE, user);
        assertFalse(token.hasRole(TRANSFER_ROLE, user));
    }
}
