// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {Jane} from "../../../src/jane/Jane.sol";

contract JaneTokenOwnershipTest is JaneSetup {
    function test_owner_canGrantTransferRole() public {
        assertFalse(token.hasRole(TRANSFER_ROLE, alice));

        vm.prank(owner);
        token.grantRole(TRANSFER_ROLE, alice);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
    }

    function test_owner_canRevokeTransferRole() public {
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

    function test_owner_canBeTransferred() public {
        address newOwner = makeAddr("newAdmin");

        assertEq(token.owner(), owner);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);
        token.transferOwnership(newOwner);

        assertEq(token.owner(), newOwner);
        assertFalse(token.hasRole(OWNER_ROLE, owner));
        assertTrue(token.hasRole(OWNER_ROLE, newOwner));
    }

    function test_transferOwnership_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Jane.InvalidAddress.selector);
        token.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsNonAdmin() public {
        address newOwner = makeAddr("newAdmin");

        vm.prank(alice);
        vm.expectRevert();
        token.transferOwnership(newOwner);
    }

    function test_owner_accessor() public view {
        assertEq(token.owner(), owner);
    }

    function test_nonOwner_cannotGrantTransferRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.grantRole(TRANSFER_ROLE, bob);
    }

    function test_nonOwner_cannotSetTransferable() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferable();
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

    function test_owner_returnsZeroWhenNoAdmin() public {
        assertEq(token.owner(), owner);

        vm.prank(owner);
        token.renounceRole(OWNER_ROLE, owner);

        assertEq(token.owner(), address(0));
        assertEq(token.getRoleMemberCount(OWNER_ROLE), 0);
    }

    function test_transferOwnership_toSelf() public {
        assertEq(token.owner(), owner);

        vm.prank(owner);
        token.transferOwnership(owner);

        assertEq(token.owner(), owner);
        assertTrue(token.hasRole(OWNER_ROLE, owner));
        assertEq(token.getRoleMemberCount(OWNER_ROLE), 1);
    }

    function test_ownerRenounce_leavesContractWithoutAdmin() public {
        vm.prank(owner);
        token.renounceRole(OWNER_ROLE, owner);

        assertEq(token.owner(), address(0));
        assertFalse(token.hasRole(OWNER_ROLE, owner));

        vm.expectRevert();
        vm.prank(owner);
        token.grantRole(MINTER_ROLE, alice);
    }

    function test_getRoleMember_outOfBounds() public {
        vm.expectRevert();
        token.getRoleMember(TRANSFER_ROLE, 0);

        grantTransferRole(alice);

        vm.expectRevert();
        token.getRoleMember(TRANSFER_ROLE, 1);
    }

    function test_roleEnumeration_afterMultipleOperations() public {
        grantTransferRole(alice);
        grantTransferRole(bob);
        grantTransferRole(charlie);

        assertEq(token.getRoleMemberCount(TRANSFER_ROLE), 3);

        address member0 = token.getRoleMember(TRANSFER_ROLE, 0);
        address member1 = token.getRoleMember(TRANSFER_ROLE, 1);
        address member2 = token.getRoleMember(TRANSFER_ROLE, 2);

        assertTrue(member0 == alice || member0 == bob || member0 == charlie);
        assertTrue(member1 == alice || member1 == bob || member1 == charlie);
        assertTrue(member2 == alice || member2 == bob || member2 == charlie);

        vm.prank(owner);
        token.revokeRole(TRANSFER_ROLE, bob);
        assertEq(token.getRoleMemberCount(TRANSFER_ROLE), 2);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
        assertFalse(token.hasRole(TRANSFER_ROLE, bob));
        assertTrue(token.hasRole(TRANSFER_ROLE, charlie));
    }

    function test_roleAdminConfiguration() public view {
        assertEq(token.getRoleAdmin(MINTER_ROLE), OWNER_ROLE);
        assertEq(token.getRoleAdmin(TRANSFER_ROLE), OWNER_ROLE);
        assertEq(token.getRoleAdmin(OWNER_ROLE), 0x00);
    }

    function test_accountWithMultipleRoles() public {
        grantTransferRole(alice);
        vm.prank(owner);
        token.grantRole(MINTER_ROLE, alice);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
        assertTrue(token.hasRole(MINTER_ROLE, alice));

        vm.prank(owner);
        token.revokeRole(MINTER_ROLE, alice);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));
        assertFalse(token.hasRole(MINTER_ROLE, alice));
    }

    function test_adminGrantsSelfOtherRoles() public {
        assertFalse(token.hasRole(MINTER_ROLE, owner));

        vm.prank(owner);
        token.grantRole(MINTER_ROLE, owner);

        assertTrue(token.hasRole(OWNER_ROLE, owner));
        assertTrue(token.hasRole(MINTER_ROLE, owner));

        vm.prank(owner);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }
}
