// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {SettlementController} from "../../../src/SettlementController.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {JaneBurner} from "../../../src/jane/JaneBurner.sol";
import {JaneToken} from "../../../src/jane/JaneToken.sol";
import {MarketParams, Id} from "../../../src/interfaces/IMorpho.sol";

contract MockCreditLine {
    function settle(MarketParams memory, address, uint256, uint256)
        external
        pure
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        return (1000e18, 1000e18);
    }
}

contract MockCreditLineWithOwner {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function settle(MarketParams memory, address, uint256, uint256)
        external
        pure
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        return (1000e18, 1000e18);
    }
}

contract SettlementControllerTest is Test {
    SettlementController public controller;
    MockCreditLineWithOwner public creditLine;
    JaneBurner public burner;
    JaneToken public jane;

    address public owner;
    address public minter;
    address public alice;
    address public bob;

    event SettledWithBurn(
        address indexed borrower, uint256 burnedAmount, uint256 writtenOffAssets, uint256 writtenOffShares
    );

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        jane = new JaneToken(owner, minter, address(0));
        burner = new JaneBurner(address(jane));
        creditLine = new MockCreditLineWithOwner(owner);
        controller = new SettlementController(address(creditLine), address(burner), address(jane));

        vm.prank(owner);
        burner.setAuthorized(address(controller), true);

        vm.prank(owner);
        jane.setBurner(address(burner));

        vm.prank(minter);
        jane.mint(alice, 1000e18);

        vm.prank(minter);
        jane.mint(bob, 500e18);
    }

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(controller.creditLine()), address(creditLine));
        assertEq(address(controller.burner()), address(burner));
        assertEq(address(controller.JANE()), address(jane));
        assertEq(controller.owner(), owner);
    }

    function test_settleAndBurn_success() public {
        MarketParams memory params;
        uint256 aliceBalanceBefore = jane.balanceOf(alice);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SettledWithBurn(alice, aliceBalanceBefore, 1000e18, 1000e18);
        (uint256 writtenOffAssets, uint256 writtenOffShares) = controller.settleAndBurn(params, alice, 1000e18, 0);

        assertEq(jane.balanceOf(alice), 0);
        assertEq(writtenOffAssets, 1000e18);
        assertEq(writtenOffShares, 1000e18);
    }

    function test_settleAndBurn_zeroBalance() public {
        MarketParams memory params;

        vm.prank(owner);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            controller.settleAndBurn(params, makeAddr("nobody"), 1000e18, 0);

        assertEq(writtenOffAssets, 1000e18);
        assertEq(writtenOffShares, 1000e18);
    }

    function test_settleAndBurn_onlyOwner() public {
        MarketParams memory params;

        vm.prank(alice);
        vm.expectRevert(SettlementController.NotOwner.selector);
        controller.settleAndBurn(params, bob, 1000e18, 0);
    }

    function test_settleAndBurn_burnsFullBalance() public {
        MarketParams memory params;

        vm.prank(minter);
        jane.mint(alice, 500e18);

        assertEq(jane.balanceOf(alice), 1500e18);

        vm.prank(owner);
        controller.settleAndBurn(params, alice, 1000e18, 0);

        assertEq(jane.balanceOf(alice), 0);
    }

    function test_settleAndBurn_multipleBorrowers() public {
        MarketParams memory params;

        uint256 aliceBalance = jane.balanceOf(alice);
        uint256 bobBalance = jane.balanceOf(bob);

        vm.prank(owner);
        controller.settleAndBurn(params, alice, 1000e18, 0);
        assertEq(jane.balanceOf(alice), 0);

        vm.prank(owner);
        controller.settleAndBurn(params, bob, 500e18, 0);
        assertEq(jane.balanceOf(bob), 0);

        assertEq(jane.totalSupply(), 0);
    }

    function test_settleAndBurn_emitsCorrectEvent() public {
        MarketParams memory params;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SettledWithBurn(alice, 1000e18, 1000e18, 1000e18);
        controller.settleAndBurn(params, alice, 1000e18, 0);
    }

    function test_settleAndBurn_returnsCorrectValues() public {
        MarketParams memory params;

        vm.prank(owner);
        (uint256 writtenOffAssets, uint256 writtenOffShares) = controller.settleAndBurn(params, alice, 1000e18, 0);

        assertEq(writtenOffAssets, 1000e18);
        assertEq(writtenOffShares, 1000e18);
    }

    function testFuzz_settleAndBurn_variousAmounts(uint256 janeBalance, uint256 settleAssets) public {
        vm.assume(janeBalance <= 1e27);
        vm.assume(settleAssets <= 1e27);

        address borrower = makeAddr("fuzzBorrower");
        MarketParams memory params;

        if (janeBalance > 0) {
            vm.prank(minter);
            jane.mint(borrower, janeBalance);
        }

        uint256 balanceBefore = jane.balanceOf(borrower);

        vm.prank(owner);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            controller.settleAndBurn(params, borrower, settleAssets, 0);

        assertEq(jane.balanceOf(borrower), 0);
        assertEq(writtenOffAssets, 1000e18);
        assertEq(writtenOffShares, 1000e18);
    }
}
