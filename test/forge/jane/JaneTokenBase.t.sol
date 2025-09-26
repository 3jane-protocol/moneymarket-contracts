// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";

contract JaneTokenBaseTest is JaneSetup {
    function test_constructor_setsCorrectRoles() public view {
        assertTrue(token.hasRole(ADMIN_ROLE, admin));
        assertTrue(token.hasRole(MINTER_ROLE, minter));
        assertTrue(token.hasRole(BURNER_ROLE, burner));
        assertFalse(token.hasRole(TRANSFER_ROLE, admin));
    }

    function test_constructor_revertsWithZeroAdmin() public {
        vm.expectRevert(JaneToken.InvalidAddress.selector);
        new JaneToken(address(0), minter, burner);
    }

    function test_tokenMetadata() public view {
        assertEq(token.name(), "JANE");
        assertEq(token.symbol(), "JANE");
        assertEq(token.decimals(), 18);
    }

    function test_mint_success() public {
        vm.prank(minter);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 1000e18);
        token.mint(alice, 1000e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_mint_revertsUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(bob, 1000e18);
    }

    function test_mint_revertsToZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(JaneToken.InvalidAddress.selector);
        token.mint(address(0), 1000e18);
    }

    function test_totalSupplyTracking() public {
        mintTokens(alice, 1000e18);
        assertEq(token.totalSupply(), 1000e18);

        mintTokens(bob, 500e18);
        assertEq(token.totalSupply(), 1500e18);

        vm.prank(alice);
        token.burn(200e18);
        assertEq(token.totalSupply(), 1300e18);
    }

    function test_setTransferable_onlyAdmin() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit TransferableStatusChanged(true);
        token.setTransferable();

        assertTrue(token.transferable());
    }

    function test_setTransferable_revertsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferable();
    }

    function testFuzz_mint_variousAmounts(uint256 amount) public {
        vm.assume(amount <= type(uint256).max / 2);

        vm.prank(minter);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzz_mint_multipleRecipients(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(amount <= type(uint256).max / 2);

        vm.prank(minter);
        token.mint(recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
    }
}
