// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";

contract JaneTokenAccessControlTest is JaneSetup {
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function test_adminRole_selfAdministered() public {
        assertEq(token.getRoleAdmin(ADMIN_ROLE), ADMIN_ROLE);

        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit RoleGranted(ADMIN_ROLE, newAdmin, admin);
        token.grantRole(ADMIN_ROLE, newAdmin);

        assertTrue(token.hasRole(ADMIN_ROLE, newAdmin));

        vm.prank(newAdmin);
        vm.expectEmit(true, true, true, false);
        emit RoleRevoked(ADMIN_ROLE, admin, newAdmin);
        token.revokeRole(ADMIN_ROLE, admin);

        assertFalse(token.hasRole(ADMIN_ROLE, admin));
        assertTrue(token.hasRole(ADMIN_ROLE, newAdmin));
    }

    function test_adminRole_managesTransferRole() public {
        assertEq(token.getRoleAdmin(TRANSFER_ROLE), ADMIN_ROLE);

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit RoleGranted(TRANSFER_ROLE, alice, admin);
        token.grantRole(TRANSFER_ROLE, alice);

        assertTrue(token.hasRole(TRANSFER_ROLE, alice));

        vm.prank(admin);
        vm.expectEmit(true, true, true, false);
        emit RoleRevoked(TRANSFER_ROLE, alice, admin);
        token.revokeRole(TRANSFER_ROLE, alice);

        assertFalse(token.hasRole(TRANSFER_ROLE, alice));
    }

    function test_minterRole_immutable() public {
        assertEq(token.getRoleAdmin(MINTER_ROLE), bytes32(0));

        vm.prank(admin);
        vm.expectRevert();
        token.grantRole(MINTER_ROLE, alice);

        // Note: renounceRole is allowed by AccessControl even without admin
        // This is a feature, not a bug - roles can always renounce themselves
        vm.prank(minter);
        token.renounceRole(MINTER_ROLE, minter);
        assertFalse(token.hasRole(MINTER_ROLE, minter));
    }

    function test_burnerRole_immutable() public {
        assertEq(token.getRoleAdmin(BURNER_ROLE), bytes32(0));

        vm.prank(admin);
        vm.expectRevert();
        token.grantRole(BURNER_ROLE, alice);

        // Note: renounceRole is allowed by AccessControl even without admin
        // This is a feature, not a bug - roles can always renounce themselves
        vm.prank(burner);
        token.renounceRole(BURNER_ROLE, burner);
        assertFalse(token.hasRole(BURNER_ROLE, burner));
    }

    function test_defaultAdminRole_notUsed() public {
        bytes32 DEFAULT_ADMIN_ROLE = 0x00;
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, minter));
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, burner));

        assertEq(token.getRoleAdmin(MINTER_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(token.getRoleAdmin(BURNER_ROLE), DEFAULT_ADMIN_ROLE);
    }

    function test_multipleAdmins() public {
        address admin2 = makeAddr("admin2");
        address admin3 = makeAddr("admin3");

        vm.prank(admin);
        token.grantRole(ADMIN_ROLE, admin2);

        vm.prank(admin);
        token.grantRole(ADMIN_ROLE, admin3);

        assertTrue(token.hasRole(ADMIN_ROLE, admin));
        assertTrue(token.hasRole(ADMIN_ROLE, admin2));
        assertTrue(token.hasRole(ADMIN_ROLE, admin3));

        vm.prank(admin2);
        token.grantRole(TRANSFER_ROLE, bob);
        assertTrue(token.hasRole(TRANSFER_ROLE, bob));
    }

    function test_roleRenouncement() public {
        vm.prank(admin);
        token.grantRole(TRANSFER_ROLE, alice);
        assertTrue(token.hasRole(TRANSFER_ROLE, alice));

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit RoleRevoked(TRANSFER_ROLE, alice, alice);
        token.renounceRole(TRANSFER_ROLE, alice);

        assertFalse(token.hasRole(TRANSFER_ROLE, alice));
    }

    function test_nonAdminCannotManageRoles() public {
        vm.prank(alice);
        vm.expectRevert();
        token.grantRole(TRANSFER_ROLE, bob);

        vm.prank(alice);
        vm.expectRevert();
        token.revokeRole(TRANSFER_ROLE, treasury);
    }

    function testFuzz_roleGrantRevoke(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != admin);

        assertFalse(token.hasRole(TRANSFER_ROLE, user));

        vm.prank(admin);
        token.grantRole(TRANSFER_ROLE, user);
        assertTrue(token.hasRole(TRANSFER_ROLE, user));

        vm.prank(admin);
        token.revokeRole(TRANSFER_ROLE, user);
        assertFalse(token.hasRole(TRANSFER_ROLE, user));
    }
}
