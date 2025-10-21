// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {JaneSetup} from "./utils/JaneSetup.sol";
import {Jane} from "../../../src/jane/Jane.sol";

contract JaneTokenRedistributeTest is JaneSetup {
    address public markdownController;

    function setUp() public override {
        super.setUp();
        mintTokens(alice, 1000e18);
        mintTokens(bob, 1000e18);
        mintTokens(charlie, 1000e18);

        markdownController = makeAddr("markdownController");
        vm.label(markdownController, "MarkdownController");

        // Set markdown controller
        vm.prank(owner);
        token.setMarkdownController(markdownController);
    }

    function test_redistributeFromBorrower_success() public {
        uint256 initialDistributorBalance = token.balanceOf(distributor);
        uint256 redistributeAmount = 200e18;

        vm.prank(markdownController);
        token.redistributeFromBorrower(alice, redistributeAmount);

        assertEq(token.balanceOf(alice), 800e18);
        assertEq(token.balanceOf(distributor), initialDistributorBalance + redistributeAmount);
        assertEq(token.totalSupply(), 3000e18);
    }

    function test_redistributeFromBorrower_fullBalance() public {
        uint256 initialDistributorBalance = token.balanceOf(distributor);
        uint256 aliceBalance = token.balanceOf(alice);

        vm.prank(markdownController);
        token.redistributeFromBorrower(alice, aliceBalance);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(distributor), initialDistributorBalance + aliceBalance);
    }

    function test_redistributeFromBorrower_unauthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(Jane.Unauthorized.selector);
        token.redistributeFromBorrower(bob, 100e18);
    }

    function test_redistributeFromBorrower_nonMarkdownController() public {
        vm.prank(owner);
        vm.expectRevert(Jane.Unauthorized.selector);
        token.redistributeFromBorrower(alice, 100e18);
    }

    function test_redistributeFromBorrower_zeroAddressBorrower() public {
        vm.prank(markdownController);
        vm.expectRevert(Jane.InvalidAddress.selector);
        token.redistributeFromBorrower(address(0), 100e18);
    }

    function test_redistributeFromBorrower_noDistributorSet() public {
        // Deploy new token without distributor
        Jane newToken = new Jane(owner, address(0));

        vm.prank(owner);
        newToken.setMarkdownController(markdownController);

        vm.prank(markdownController);
        vm.expectRevert(Jane.InvalidAddress.selector);
        newToken.redistributeFromBorrower(alice, 100e18);
    }

    function test_redistributeFromBorrower_exceedsBalance() public {
        vm.prank(markdownController);
        vm.expectRevert();
        token.redistributeFromBorrower(alice, 1001e18);
    }

    function test_redistributeFromBorrower_zeroAmount() public {
        uint256 initialAliceBalance = token.balanceOf(alice);
        uint256 initialDistributorBalance = token.balanceOf(distributor);

        vm.prank(markdownController);
        token.redistributeFromBorrower(alice, 0);

        assertEq(token.balanceOf(alice), initialAliceBalance);
        assertEq(token.balanceOf(distributor), initialDistributorBalance);
    }

    function test_redistributeFromBorrower_multipleRedistributions() public {
        uint256 initialDistributorBalance = token.balanceOf(distributor);

        vm.startPrank(markdownController);
        token.redistributeFromBorrower(alice, 100e18);
        token.redistributeFromBorrower(bob, 200e18);
        token.redistributeFromBorrower(charlie, 300e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.balanceOf(bob), 800e18);
        assertEq(token.balanceOf(charlie), 700e18);
        assertEq(token.balanceOf(distributor), initialDistributorBalance + 600e18);
        assertEq(token.totalSupply(), 3000e18);
    }

    function test_redistributeFromBorrower_withTransferRestrictions() public {
        // Transfer restrictions should not affect redistribution
        assertFalse(token.transferable());

        vm.prank(alice);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        token.transfer(bob, 100e18);

        vm.prank(markdownController);
        token.redistributeFromBorrower(alice, 100e18);
        assertEq(token.balanceOf(alice), 900e18);
    }

    function testFuzz_redistributeFromBorrower(address borrower, uint256 redistributeAmount) public {
        vm.assume(borrower != address(0));
        vm.assume(borrower != distributor);
        vm.assume(borrower != minter && borrower != owner && borrower != markdownController);
        vm.assume(borrower != alice && borrower != bob && borrower != charlie);
        vm.assume(redistributeAmount <= 1000e18);

        mintTokens(borrower, 1000e18);
        uint256 initialDistributorBalance = token.balanceOf(distributor);

        vm.prank(markdownController);
        token.redistributeFromBorrower(borrower, redistributeAmount);

        assertEq(token.balanceOf(borrower), 1000e18 - redistributeAmount);
        assertEq(token.balanceOf(distributor), initialDistributorBalance + redistributeAmount);
    }
}
