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

    function test_minter_isImmutable() public view {
        assertEq(token.minter(), minter);
        // No way to change minter - it's immutable
    }

    function test_burner_isImmutable() public view {
        assertEq(token.burner(), burner);
        // No way to change burner - it's immutable
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
