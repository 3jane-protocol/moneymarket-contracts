// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";

contract JaneTokenMintFinalizationTest is JaneSetup {
    function test_renounceMintAdmin_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.renounceMintAdmin();
    }

    function test_renounceMintAdmin_setsAdminToZero() public {
        assertEq(token.getRoleAdmin(MINTER_ROLE), OWNER_ROLE);

        vm.prank(owner);
        token.renounceMintAdmin();

        assertEq(token.getRoleAdmin(MINTER_ROLE), bytes32(0));
    }

    function test_renounceMintAdmin_existingMintersCanStillMint() public {
        vm.prank(owner);
        token.renounceMintAdmin();

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(minter);
        token.mint(alice, 100e18);

        assertEq(token.balanceOf(alice), balanceBefore + 100e18);
    }

    function test_renounceMintAdmin_cannotGrantNewMinters() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(owner);
        token.renounceMintAdmin();

        vm.prank(owner);
        vm.expectRevert();
        token.grantRole(MINTER_ROLE, newMinter);
    }

    function test_afterAdminRenounced_mintersRemain() public {
        vm.prank(owner);
        token.renounceMintAdmin();

        assertEq(token.getRoleAdmin(MINTER_ROLE), bytes32(0));
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 1);
    }

    function test_afterAllRenounced_noMintersOrAdmin() public {
        vm.prank(owner);
        token.renounceMintAdmin();

        vm.prank(minter);
        token.renounceRole(MINTER_ROLE, minter);

        assertEq(token.getRoleMemberCount(MINTER_ROLE), 0);
        assertEq(token.getRoleAdmin(MINTER_ROLE), bytes32(0));
    }

    function test_cannotMintAfterAllRenounced() public {
        vm.prank(owner);
        token.renounceMintAdmin();

        vm.prank(minter);
        token.renounceRole(MINTER_ROLE, minter);

        vm.prank(owner);
        vm.expectRevert();
        token.mint(alice, 100e18);
    }

    function test_gracefulShutdown_multipleMintersCanRenounceIndependently() public {
        address minter2 = makeAddr("minter2");
        address minter3 = makeAddr("minter3");

        vm.startPrank(owner);
        token.grantRole(MINTER_ROLE, minter2);
        token.grantRole(MINTER_ROLE, minter3);
        vm.stopPrank();

        assertEq(token.getRoleMemberCount(MINTER_ROLE), 3);

        vm.prank(owner);
        token.renounceMintAdmin();

        vm.prank(minter);
        token.renounceRole(MINTER_ROLE, minter);
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 2);

        vm.prank(minter2);
        token.renounceRole(MINTER_ROLE, minter2);
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 1);

        vm.prank(minter3);
        token.renounceRole(MINTER_ROLE, minter3);
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 0);
    }

    function test_stateTransitions() public {
        assertEq(token.getRoleAdmin(MINTER_ROLE), OWNER_ROLE);
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 1);

        vm.prank(owner);
        token.renounceMintAdmin();

        assertEq(token.getRoleAdmin(MINTER_ROLE), bytes32(0));
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 1);

        vm.prank(minter);
        token.renounceRole(MINTER_ROLE, minter);

        assertEq(token.getRoleAdmin(MINTER_ROLE), bytes32(0));
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 0);
    }
}
