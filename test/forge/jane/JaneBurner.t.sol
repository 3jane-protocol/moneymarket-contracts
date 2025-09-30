// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneBurner} from "../../../src/jane/JaneBurner.sol";

contract JaneBurnerTest is JaneSetup {
    JaneBurner public janeBurner;

    event AuthorizationUpdated(address indexed account, bool status);

    function setUp() public override {
        super.setUp();
        janeBurner = new JaneBurner(address(token));

        vm.prank(owner);
        token.setBurner(address(janeBurner));

        mintTokens(alice, 1000e18);
        mintTokens(bob, 500e18);
    }

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(janeBurner.JANE()), address(token));
        assertEq(janeBurner.owner(), owner);
    }

    function test_setAuthorized_success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AuthorizationUpdated(alice, true);
        janeBurner.setAuthorized(alice, true);

        assertTrue(janeBurner.authorized(alice));
    }

    function test_setAuthorized_canRevoke() public {
        vm.prank(owner);
        janeBurner.setAuthorized(alice, true);
        assertTrue(janeBurner.authorized(alice));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit AuthorizationUpdated(alice, false);
        janeBurner.setAuthorized(alice, false);

        assertFalse(janeBurner.authorized(alice));
    }

    function test_setAuthorized_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(JaneBurner.NotOwner.selector);
        janeBurner.setAuthorized(bob, true);
    }

    function test_burn_ownerCanBurn() public {
        vm.prank(owner);
        janeBurner.burn(alice, 100e18);

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.totalSupply(), 1400e18);
    }

    function test_burn_authorizedCanBurn() public {
        vm.prank(owner);
        janeBurner.setAuthorized(bob, true);

        vm.prank(bob);
        janeBurner.burn(alice, 200e18);

        assertEq(token.balanceOf(alice), 800e18);
        assertEq(token.totalSupply(), 1300e18);
    }

    function test_burn_unauthorizedCannotBurn() public {
        vm.prank(alice);
        vm.expectRevert(JaneBurner.Unauthorized.selector);
        janeBurner.burn(bob, 100e18);
    }

    function test_burn_unauthorizedAfterRevocation() public {
        vm.prank(owner);
        janeBurner.setAuthorized(alice, true);

        vm.prank(owner);
        janeBurner.setAuthorized(alice, false);

        vm.prank(alice);
        vm.expectRevert(JaneBurner.Unauthorized.selector);
        janeBurner.burn(bob, 100e18);
    }

    function test_burn_multipleAuthorized() public {
        vm.prank(owner);
        janeBurner.setAuthorized(alice, true);

        vm.prank(owner);
        janeBurner.setAuthorized(charlie, true);

        vm.prank(alice);
        janeBurner.burn(bob, 100e18);
        assertEq(token.balanceOf(bob), 400e18);

        vm.prank(charlie);
        janeBurner.burn(bob, 100e18);
        assertEq(token.balanceOf(bob), 300e18);

        vm.prank(owner);
        janeBurner.burn(bob, 100e18);
        assertEq(token.balanceOf(bob), 200e18);
    }

    function test_burn_exceedsBalance() public {
        vm.prank(owner);
        vm.expectRevert();
        janeBurner.burn(alice, 2000e18);
    }

    function testFuzz_setAuthorized(address account, bool status) public {
        vm.assume(account != address(0));

        vm.prank(owner);
        janeBurner.setAuthorized(account, status);

        assertEq(janeBurner.authorized(account), status);
    }

    function testFuzz_burn_authorized(address authorized, uint256 burnAmount) public {
        vm.assume(authorized != address(0) && authorized != owner);
        vm.assume(burnAmount <= 1000e18);

        vm.prank(owner);
        janeBurner.setAuthorized(authorized, true);

        vm.prank(authorized);
        janeBurner.burn(alice, burnAmount);

        assertEq(token.balanceOf(alice), 1000e18 - burnAmount);
    }
}
