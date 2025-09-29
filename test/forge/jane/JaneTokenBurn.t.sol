// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";

contract JaneTokenBurnTest is JaneSetup {
    function setUp() public override {
        super.setUp();
        mintTokens(alice, 1000e18);
        mintTokens(bob, 1000e18);
        mintTokens(charlie, 1000e18);
    }

    function test_burn_self() public {
        uint256 initialSupply = token.totalSupply();

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), 200e18);
        token.burn(200e18);

        assertEq(token.balanceOf(alice), 800e18);
        assertEq(token.totalSupply(), initialSupply - 200e18);
    }

    function test_burn_self_exceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(1001e18);
    }

    function test_burnFrom_withAllowance() public {
        uint256 initialSupply = token.totalSupply();

        vm.prank(alice);
        token.approve(bob, 300e18);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), 200e18);
        token.burnFrom(alice, 200e18);

        assertEq(token.balanceOf(alice), 800e18);
        assertEq(token.totalSupply(), initialSupply - 200e18);
        assertEq(token.allowance(alice, bob), 100e18);
    }

    function test_burnFrom_insufficientAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100e18);

        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 200e18);
    }

    function test_burn_byBurnerRole() public {
        uint256 initialSupply = token.totalSupply();

        vm.prank(burner);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), 300e18);
        token.burn(alice, 300e18);

        assertEq(token.balanceOf(alice), 700e18);
        assertEq(token.totalSupply(), initialSupply - 300e18);
    }

    function test_burn_byBurnerRole_anyAccount() public {
        vm.prank(burner);
        token.burn(alice, 100e18);
        assertEq(token.balanceOf(alice), 900e18);

        vm.prank(burner);
        token.burn(bob, 200e18);
        assertEq(token.balanceOf(bob), 800e18);

        vm.prank(burner);
        token.burn(charlie, 300e18);
        assertEq(token.balanceOf(charlie), 700e18);
    }

    function test_burn_unauthorizedRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(bob, 100e18);
    }

    function test_burn_zeroAddress() public {
        vm.prank(burner);
        vm.expectRevert(JaneToken.InvalidAddress.selector);
        token.burn(address(0), 100e18);
    }

    function test_burn_exceedsBalance() public {
        vm.prank(burner);
        vm.expectRevert();
        token.burn(alice, 1001e18);
    }

    function test_burnInteraction_withTransferRestrictions() public {
        assertFalse(token.transferable());

        vm.prank(alice);
        vm.expectRevert(JaneToken.TransferNotAllowed.selector);
        token.transfer(bob, 100e18);

        vm.prank(alice);
        token.burn(100e18);
        assertEq(token.balanceOf(alice), 900e18);

        vm.prank(burner);
        token.burn(alice, 100e18);
        assertEq(token.balanceOf(alice), 800e18);
    }

    function test_burn_zeroAmount() public {
        uint256 initialBalance = token.balanceOf(alice);
        uint256 initialSupply = token.totalSupply();

        vm.prank(alice);
        token.burn(0);

        assertEq(token.balanceOf(alice), initialBalance);
        assertEq(token.totalSupply(), initialSupply);
    }

    function test_burnFrom_maxApproval() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.burnFrom(alice, 100e18);

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function testFuzz_burnMechanisms(address account, uint256 burnAmount) public {
        vm.assume(account != address(0));
        vm.assume(account != minter && account != burner && account != owner);
        // Exclude addresses that already have tokens from setUp
        vm.assume(account != alice && account != bob && account != charlie);
        vm.assume(burnAmount <= 1000e18);

        mintTokens(account, 1000e18);

        vm.prank(account);
        token.burn(burnAmount);
        assertEq(token.balanceOf(account), 1000e18 - burnAmount);

        mintTokens(account, burnAmount);

        vm.prank(burner);
        token.burn(account, burnAmount);
        assertEq(token.balanceOf(account), 1000e18 - burnAmount);
    }
}
