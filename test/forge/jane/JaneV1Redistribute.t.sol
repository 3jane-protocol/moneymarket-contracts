// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {JaneV1} from "../../../src/jane/JaneV1.sol";

contract JaneV1RedistributeTest is Test {
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    JaneV1 internal token;

    address internal owner;
    address internal minter;
    address internal distributor;
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal markdownController;

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        distributor = makeAddr("distributor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        markdownController = makeAddr("markdownController");

        token = new JaneV1(owner, distributor);

        vm.startPrank(owner);
        token.grantRole(MINTER_ROLE, minter);
        token.setMarkdownController(markdownController);
        vm.stopPrank();

        mintTokens(alice, 1000e18);
        mintTokens(bob, 1000e18);
        mintTokens(charlie, 1000e18);
    }

    function mintTokens(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
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
        vm.expectRevert(JaneV1.Unauthorized.selector);
        token.redistributeFromBorrower(bob, 100e18);
    }

    function test_redistributeFromBorrower_nonMarkdownController() public {
        vm.prank(owner);
        vm.expectRevert(JaneV1.Unauthorized.selector);
        token.redistributeFromBorrower(alice, 100e18);
    }

    function test_redistributeFromBorrower_zeroAddressBorrower() public {
        vm.prank(markdownController);
        vm.expectRevert(JaneV1.InvalidAddress.selector);
        token.redistributeFromBorrower(address(0), 100e18);
    }

    function test_redistributeFromBorrower_noDistributorSet() public {
        JaneV1 newToken = new JaneV1(owner, address(0));

        vm.prank(owner);
        newToken.setMarkdownController(markdownController);

        vm.prank(markdownController);
        vm.expectRevert(JaneV1.InvalidAddress.selector);
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
        assertFalse(token.transferable());

        vm.prank(alice);
        vm.expectRevert(JaneV1.TransferNotAllowed.selector);
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
