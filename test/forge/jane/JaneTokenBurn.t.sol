// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20Errors} from "../../../lib/openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {JaneSetup} from "./utils/JaneSetup.sol";

contract JaneTokenBurnTest is JaneSetup {
    function setUp() public override {
        super.setUp();
        mintTokens(alice, 1000e18);
        mintTokens(bob, 1000e18);
    }

    function test_burn_succeedsWithTransfersDisabledAndNoTransferRole() public {
        assertFalse(token.transferable());
        assertFalse(token.hasRole(TRANSFER_ROLE, alice));

        vm.prank(alice);
        token.burn(400e18);

        assertEq(token.balanceOf(alice), 600e18);
    }

    function test_burn_reducesBalanceAndTotalSupply() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.burn(250e18);

        assertEq(token.balanceOf(alice), 750e18);
        assertEq(token.balanceOf(bob), 1000e18);
        assertEq(token.totalSupply(), supplyBefore - 250e18);
    }

    function test_burn_emitsTransferToZero() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 100e18);

        vm.prank(alice);
        token.burn(100e18);
    }

    function test_burn_fullBalance() public {
        vm.prank(alice);
        token.burn(1000e18);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_burn_revertsAboveBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000e18, 1001e18));
        token.burn(1001e18);
    }

    function test_burn_revertsWithZeroBalance() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, charlie, 0, 1));
        token.burn(1);
    }

    function test_burn_doesNotSpendAllowance() public {
        vm.prank(alice);
        token.approve(bob, 500e18);

        vm.prank(bob);
        token.burn(100e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(bob), 900e18);
        assertEq(token.allowance(alice, bob), 500e18);
    }

    function test_burnFrom_notInAbi() public {
        vm.prank(alice);
        token.approve(bob, 500e18);

        vm.prank(bob);
        (bool success,) =
            address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, uint256(100e18)));

        assertFalse(success);
        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.allowance(alice, bob), 500e18);
    }

    function testFuzz_burn(address holder, uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(holder != address(0));
        mintAmount = bound(mintAmount, 0, type(uint128).max);
        burnAmount = bound(burnAmount, 0, mintAmount);

        uint256 balanceBefore = token.balanceOf(holder);
        mintTokens(holder, mintAmount);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(holder);
        token.burn(burnAmount);

        assertEq(token.balanceOf(holder), balanceBefore + mintAmount - burnAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
    }
}
