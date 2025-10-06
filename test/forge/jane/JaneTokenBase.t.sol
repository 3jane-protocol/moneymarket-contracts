// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {Jane} from "../../../src/jane/Jane.sol";

contract JaneTokenBaseTest is JaneSetup {
    function test_constructor_setsCorrectAddresses() public view {
        assertEq(token.owner(), owner);
        assertTrue(token.hasRole(MINTER_ROLE, minter));
        assertTrue(token.hasRole(BURNER_ROLE, burner));
        assertEq(token.getRoleMemberCount(MINTER_ROLE), 1);
        assertEq(token.getRoleMemberCount(BURNER_ROLE), 1);
        assertFalse(token.hasRole(TRANSFER_ROLE, owner));
    }

    function test_constructor_revertsWithZeroOwner() public {
        vm.expectRevert(Jane.InvalidAddress.selector);
        new Jane(address(0), minter, burner);
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
        vm.expectRevert(Jane.InvalidAddress.selector);
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

    function test_setTransferable_onlyOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TransferEnabled();
        token.setTransferable();

        assertTrue(token.transferable());
    }

    function test_setTransferable_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setTransferable();
    }

    function test_finalizeMinting_onlyOwner() public {
        assertFalse(token.mintFinalized());

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MintingFinalized();
        token.finalizeMinting();

        assertTrue(token.mintFinalized());
    }

    function test_finalizeMinting_preventsFutureMinting() public {
        vm.prank(owner);
        token.finalizeMinting();

        vm.prank(minter);
        vm.expectRevert(Jane.MintFinalized.selector);
        token.mint(alice, 1000e18);
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

    function test_constructor_allowsZeroMinter() public {
        Jane newToken = new Jane(owner, address(0), burner);
        assertEq(newToken.getRoleMemberCount(MINTER_ROLE), 0);
        assertEq(newToken.owner(), owner);
        assertTrue(newToken.hasRole(BURNER_ROLE, burner));
    }

    function test_constructor_allowsZeroBurner() public {
        Jane newToken = new Jane(owner, minter, address(0));
        assertEq(newToken.getRoleMemberCount(BURNER_ROLE), 0);
        assertEq(newToken.owner(), owner);
        assertTrue(newToken.hasRole(MINTER_ROLE, minter));
    }

    function test_constructor_bothMinterAndBurnerZero() public {
        Jane newToken = new Jane(owner, address(0), address(0));
        assertEq(newToken.getRoleMemberCount(MINTER_ROLE), 0);
        assertEq(newToken.getRoleMemberCount(BURNER_ROLE), 0);
        assertEq(newToken.owner(), owner);
        assertTrue(newToken.hasRole(OWNER_ROLE, owner));
    }
}
