// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title Test for Min Deposit Bypass Bug
 * @notice Demonstrates that users can bypass minDeposit using type(uint256).max
 * @dev Shows that the hook receives type(uint256).max before TokenizedStrategy resolves it
 *
 * The bug occurs because:
 * 1. User calls deposit(type(uint256).max, receiver)
 * 2. _preDepositHook receives assets = type(uint256).max
 * 3. Hook checks: type(uint256).max >= minDeposit (always true)
 * 4. TokenizedStrategy later resolves type(uint256).max to user's actual balance
 * 5. User with balance < minDeposit successfully deposits
 *
 * This violates the protocol's minimum deposit requirement for first-time depositors.
 */
contract MinDepositBypassTest is Setup {
    USD3 public usd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant MIN_DEPOSIT = 100e6; // 100 USDC minimum

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Set minimum deposit requirement
        vm.prank(management);
        usd3Strategy.setMinDeposit(MIN_DEPOSIT);

        console2.log("Setup complete:");
        console2.log("- Min deposit set to:", MIN_DEPOSIT / 1e6, "USDC");
    }

    /**
     * @notice Test that normal deposits below minDeposit are correctly rejected
     * @dev This should pass - confirming the minDeposit check works normally
     */
    function test_normal_minDeposit_enforcement() public {
        uint256 belowMinAmount = MIN_DEPOSIT - 1;

        // Give alice less than minDeposit
        deal(address(asset), alice, belowMinAmount);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), belowMinAmount);

        // Should revert for first-time depositor with amount below minimum
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(belowMinAmount, alice);
        vm.stopPrank();

        console2.log(
            "[PASS] Normal deposit below minDeposit correctly rejected"
        );
    }

    /**
     * @notice Test that minDeposit can be bypassed using type(uint256).max
     * @dev This test SHOULD FAIL with the current buggy implementation
     *
     * The bug allows this to succeed when it should be rejected
     */
    function test_minDeposit_bypass_with_deposit_max() public {
        uint256 belowMinAmount = MIN_DEPOSIT - 1;

        // Give alice less than minDeposit
        deal(address(asset), alice, belowMinAmount);

        console2.log(
            "\nAlice balance:",
            belowMinAmount / 1e6,
            "USDC (below minimum)"
        );

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), belowMinAmount);

        // This SHOULD revert but doesn't due to the bug
        // The test expects this to revert, so it will FAIL when the bug exists
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(type(uint256).max, alice);

        vm.stopPrank();

        console2.log(
            "[PASS] Deposit with type(uint256).max correctly rejected"
        );
    }

    /**
     * @notice Test that minDeposit bypass also works with mint function
     * @dev This test SHOULD FAIL with the current buggy implementation
     */
    function test_minDeposit_bypass_with_mint_max() public {
        uint256 belowMinAmount = MIN_DEPOSIT / 2; // 50 USDC, well below minimum

        // Give bob less than minDeposit
        deal(address(asset), bob, belowMinAmount);

        console2.log(
            "\nBob balance:",
            belowMinAmount / 1e6,
            "USDC (well below minimum)"
        );

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), type(uint256).max);

        // This SHOULD revert but doesn't due to the bug
        // The test expects this to revert, so it will FAIL when the bug exists
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.mint(type(uint256).max, bob);

        vm.stopPrank();

        console2.log("[PASS] Mint with type(uint256).max correctly rejected");
    }

    /**
     * @notice Test edge case: user with exactly minDeposit-1 wei
     * @dev This test SHOULD FAIL with the current buggy implementation
     */
    function test_minDeposit_bypass_edge_case() public {
        uint256 justBelowMin = MIN_DEPOSIT - 1;

        address charlie = makeAddr("charlie");
        deal(address(asset), charlie, justBelowMin);

        console2.log(
            "\nCharlie balance:",
            justBelowMin,
            "wei (exactly minDeposit - 1)"
        );
        console2.log("Min deposit:", MIN_DEPOSIT, "wei");

        vm.startPrank(charlie);
        asset.approve(address(usd3Strategy), justBelowMin);

        // Using type(uint256).max should still respect minDeposit
        // This SHOULD revert but doesn't due to the bug
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(type(uint256).max, charlie);

        vm.stopPrank();

        console2.log("[PASS] Edge case correctly handled");
    }

    /**
     * @notice Test that existing depositors can deposit any amount
     * @dev This should always pass - minDeposit only applies to first-time depositors
     */
    function test_existing_depositor_can_deposit_any_amount() public {
        // First, alice makes a valid initial deposit
        deal(address(asset), alice, MIN_DEPOSIT);
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), MIN_DEPOSIT);
        usd3Strategy.deposit(MIN_DEPOSIT, alice);

        // Clear the commitment period for alice
        vm.warp(block.timestamp + 1 days);

        // Now alice should be able to deposit any amount, even 1 wei
        deal(address(asset), alice, 1);
        asset.approve(address(usd3Strategy), 1);

        // This should succeed for existing depositor
        usd3Strategy.deposit(1, alice);
        vm.stopPrank();

        console2.log("[PASS] Existing depositor can deposit any amount");
    }

    /**
     * @notice Additional test: Verify the actual exploit scenario
     * @dev Shows exactly how an attacker would bypass minDeposit
     */
    function test_exploit_scenario() public {
        address attacker = makeAddr("attacker");
        uint256 attackerBalance = 10e6; // Only 10 USDC, far below 100 USDC minimum

        console2.log("\n=== Exploit Scenario ===");
        console2.log("Attacker balance:", attackerBalance / 1e6, "USDC");
        console2.log("Required minimum:", MIN_DEPOSIT / 1e6, "USDC");

        deal(address(asset), attacker, attackerBalance);

        vm.startPrank(attacker);
        asset.approve(address(usd3Strategy), attackerBalance);

        // Check attacker has no USD3 shares initially
        uint256 sharesBefore = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(attacker);
        assertEq(sharesBefore, 0, "Attacker should have no shares initially");

        // This SHOULD fail but doesn't due to the bug
        // The test expects this to revert, so it will FAIL when the bug exists
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(type(uint256).max, attacker);

        vm.stopPrank();

        console2.log("[PASS] Exploit attempt correctly blocked");
    }
}
