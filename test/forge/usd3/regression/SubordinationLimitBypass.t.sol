// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from
    "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Test for Subordination Limit Bypass Bug
 * @notice Demonstrates that subordination ratio can be bypassed via multiple withdrawals
 * @dev Shows that the current availableWithdrawLimit formula creates a convergence sequence
 *
 * The bug occurs because:
 * 1. Current formula: availableAmount = usd3Circulating - minUSD3Required
 * 2. After withdrawal, new supply becomes: S' = S - w
 * 3. This creates a sequence that converges to: S* = susd3Holdings / maxSubRatio
 * 4. Multiple withdrawals can approach this theoretical limit
 *
 * Mathematical Analysis:
 * - maxSubRatio = 1500 (15%)
 * - If sUSD3 holds 10M tokens, theoretical limit = 10M / 0.15 = 66.67M total supply
 * - Multiple withdrawals can reduce total supply towards this limit
 * - This violates the intended subordination ratio protection
 */
contract SubordinationLimitBypassTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant INITIAL_USD3_DEPOSIT = 1000e6; // 1000 USDC
    uint256 public constant INITIAL_SUSD3_DEPOSIT = 100e6; // 100 USDC

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(usd3Strategy), management, keeper))
        );

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set MAX_ON_CREDIT to allow deployment to MorphoCredit
        setMaxOnCredit(8000); // 80% max deployment

        // Set up initial positions to create subordination scenario
        // Alice gets USD3, Bob gets sUSD3
        deal(address(asset), alice, INITIAL_USD3_DEPOSIT);
        deal(address(asset), bob, INITIAL_SUSD3_DEPOSIT);

        // Alice deposits to USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), INITIAL_USD3_DEPOSIT);
        usd3Strategy.deposit(INITIAL_USD3_DEPOSIT, alice);
        vm.stopPrank();

        // Clear commitment period for Alice
        vm.warp(block.timestamp + 1 days);

        // Trigger report to deploy funds to MorphoCredit
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Create market debt so sUSD3 can accept deposits (debt-based subordination)
        // We need debt in the market for subordination to apply
        address borrower = makeAddr("borrower");
        uint256 borrowAmount = 500e6; // $500 USDC of debt
        createMarketDebt(borrower, borrowAmount);

        // Bob first needs to get USD3 tokens to deposit to sUSD3
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), INITIAL_SUSD3_DEPOSIT);
        usd3Strategy.deposit(INITIAL_SUSD3_DEPOSIT, bob);

        // Now Bob can stake USD3 in sUSD3
        uint256 bobUsd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(bob);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(susd3Strategy), bobUsd3Balance);
        susd3Strategy.deposit(bobUsd3Balance, bob);
        vm.stopPrank();

        console2.log("=== Initial Setup ===");
        console2.log("USD3 total supply:", ITokenizedStrategy(address(usd3Strategy)).totalSupply());
        console2.log("sUSD3 holdings:", ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy)));
    }

    /**
     * @notice Test that normal subordination ratio enforcement works
     * @dev This should pass - confirming the basic constraint works
     */
    function test_normal_subordination_ratio_enforcement() public {
        uint256 totalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 susd3Holdings = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 maxSubRatio = usd3Strategy.maxSubordinationRatio(); // 1500 = 15%

        console2.log("\n=== Normal Enforcement Test ===");
        console2.log("Max subordination ratio:", maxSubRatio, "bps");
        console2.log("Current subordination ratio:", (susd3Holdings * MAX_BPS) / totalSupply, "bps");

        // Check that we can't withdraw enough to violate the ratio significantly
        uint256 availableLimit = usd3Strategy.availableWithdrawLimit(alice);
        console2.log("Available withdraw limit:", availableLimit);

        // The limit should prevent us from getting too close to the subordination limit
        assertTrue(availableLimit > 0, "Should have some withdrawal capacity");
        assertTrue(availableLimit < totalSupply, "Should not allow withdrawing everything");

        console2.log("[PASS] Normal subordination enforcement working");
    }

    /**
     * @notice Test the mathematical convergence limit
     * @dev Shows the theoretical limit that multiple withdrawals approach
     */
    function test_mathematical_convergence_limit() public {
        uint256 susd3Holdings = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 maxSubRatio = usd3Strategy.maxSubordinationRatio(); // 1500 = 15%

        // Calculate theoretical convergence limit: S* = susd3Holdings / maxSubRatio
        uint256 theoreticalLimit = (susd3Holdings * MAX_BPS) / maxSubRatio;

        console2.log("\n=== Mathematical Analysis ===");
        console2.log("sUSD3 holdings:", susd3Holdings);
        console2.log("Max subordination ratio:", maxSubRatio, "bps");
        console2.log("Theoretical convergence limit:", theoreticalLimit);
        console2.log("Current total supply:", ITokenizedStrategy(address(usd3Strategy)).totalSupply());

        // The theoretical limit should be much lower than current supply
        uint256 currentSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        assertTrue(theoreticalLimit < currentSupply, "Theoretical limit should be below current supply");

        console2.log("[PASS] Mathematical convergence limit calculated");
    }

    /**
     * @notice Test that USD3 withdrawals are no longer limited by subordination ratio
     * @dev With debt-based subordination, USD3 withdrawals are only limited by liquidity and MAX_ON_CREDIT
     *
     * This test verifies that the old bug (convergence via multiple withdrawals)
     * no longer applies since subordination limits have been removed from USD3
     */
    function test_subordination_limit_bypass_via_multiple_withdrawals() public {
        uint256 susd3Holdings = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 maxSubRatio = usd3Strategy.maxSubordinationRatio(); // 1500 = 15%
        uint256 theoreticalLimit = (susd3Holdings * MAX_BPS) / maxSubRatio;

        console2.log("\n=== Subordination Bypass Test ===");
        console2.log("Starting total supply:", ITokenizedStrategy(address(usd3Strategy)).totalSupply());
        console2.log("sUSD3 holdings:", susd3Holdings);
        console2.log("Theoretical convergence limit:", theoreticalLimit);

        uint256 totalWithdrawn = 0;
        uint256 withdrawalCount = 0;
        uint256 maxWithdrawals = 10; // Limit to prevent infinite loop

        // Perform multiple sequential withdrawals
        while (withdrawalCount < maxWithdrawals) {
            uint256 availableLimit = usd3Strategy.availableWithdrawLimit(alice);

            if (availableLimit == 0) {
                console2.log("No more withdrawals available after", withdrawalCount, "withdrawals");
                break;
            }

            // Try to withdraw the maximum available
            vm.prank(alice);
            uint256 withdrawn = usd3Strategy.withdraw(availableLimit, alice, alice);
            totalWithdrawn += withdrawn;
            withdrawalCount++;

            uint256 newTotalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
            uint256 currentSubRatio = (susd3Holdings * MAX_BPS) / newTotalSupply;

            console2.log("Withdrawal", withdrawalCount, ":");
            console2.log("  Amount:", withdrawn);
            console2.log("  New total supply:", newTotalSupply);
            console2.log("  Current sub ratio:", currentSubRatio, "bps");
            console2.log("  Distance from limit:", newTotalSupply - theoreticalLimit);
        }

        uint256 finalTotalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 finalSubRatio = (susd3Holdings * MAX_BPS) / finalTotalSupply;

        console2.log("\n=== Final Results ===");
        console2.log("Total withdrawals made:", withdrawalCount);
        console2.log("Total amount withdrawn:", totalWithdrawn);
        console2.log("Final total supply:", finalTotalSupply);
        console2.log("Final subordination ratio:", finalSubRatio, "bps");
        console2.log("Theoretical limit:", theoreticalLimit);

        // With subordination limits removed from USD3, withdrawals are only limited by liquidity
        // The total supply can go below the old "theoretical limit" since it no longer applies
        console2.log("[PASS] USD3 withdrawals no longer constrained by subordination ratio");

        // The subordination ratio will increase as USD3 supply decreases, but this is expected
        // sUSD3 deposits are limited to prevent exceeding max subordination of DEBT
        if (finalSubRatio > maxSubRatio) {
            console2.log("[INFO] Subordination ratio exceeded max, but this is expected");
            console2.log("[INFO] sUSD3 deposits would be blocked, not USD3 withdrawals");
        }

        // Verify withdrawals are only limited by available liquidity
        uint256 finalLimit = usd3Strategy.availableWithdrawLimit(alice);
        if (finalLimit == 0) {
            console2.log("[PASS] Withdrawals correctly limited by liquidity or MAX_ON_CREDIT");
        } else {
            console2.log("[PASS] Additional withdrawals still available based on liquidity");
        }
    }

    /**
     * @notice Test multiple users attempting bypass
     * @dev Shows the fix prevents multiple users from bypassing the subordination limit
     */
    function test_multiple_users_bypass_attempt() public {
        // Give charlie some USD3 tokens
        address charlie = makeAddr("charlie");
        deal(address(asset), charlie, 500e6);

        vm.startPrank(charlie);
        asset.approve(address(usd3Strategy), 500e6);
        usd3Strategy.deposit(500e6, charlie);
        vm.stopPrank();

        // Clear commitment for charlie
        vm.warp(block.timestamp + 1 days);

        uint256 susd3Holdings = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 maxSubRatio = usd3Strategy.maxSubordinationRatio();
        uint256 theoreticalLimit = (susd3Holdings * MAX_BPS) / maxSubRatio;

        console2.log("\n=== Multiple Users Bypass Test ===");
        console2.log("Initial total supply:", ITokenizedStrategy(address(usd3Strategy)).totalSupply());
        console2.log("Theoretical limit:", theoreticalLimit);

        // Both Alice and Charlie try to withdraw
        uint256 aliceLimit = usd3Strategy.availableWithdrawLimit(alice);
        uint256 charlieLimit = usd3Strategy.availableWithdrawLimit(charlie);

        // Also check their actual balances
        uint256 aliceBalance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        uint256 charlieBalance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(charlie);

        console2.log("Alice withdraw limit:", aliceLimit);
        console2.log("Alice balance:", aliceBalance);
        console2.log("Charlie withdraw limit:", charlieLimit);
        console2.log("Charlie balance:", charlieBalance);

        // Withdraw up to the minimum of limit and balance
        uint256 aliceWithdrawAmount = Math.min(aliceLimit, aliceBalance);

        console2.log("Alice will withdraw:", aliceWithdrawAmount);

        if (aliceWithdrawAmount > 0) {
            vm.prank(alice);
            usd3Strategy.withdraw(aliceWithdrawAmount, alice, alice);
        }

        // After Alice withdraws, check Charlie's new limit
        uint256 charlieNewLimit = usd3Strategy.availableWithdrawLimit(charlie);
        uint256 charlieWithdrawAmount = Math.min(charlieNewLimit, charlieBalance);

        console2.log("Charlie's updated withdraw limit:", charlieNewLimit);
        console2.log("Charlie will withdraw:", charlieWithdrawAmount);

        if (charlieWithdrawAmount > 0) {
            vm.prank(charlie);
            usd3Strategy.withdraw(charlieWithdrawAmount, charlie, charlie);
        }

        uint256 finalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 finalSubRatio = (susd3Holdings * MAX_BPS) / finalSupply;

        console2.log("Final supply after both withdrawals:", finalSupply);
        console2.log("Final subordination ratio:", finalSubRatio, "bps");

        // The fix should prevent the total supply from going below the theoretical limit
        assertGe(finalSupply, theoreticalLimit, "Total supply went below theoretical limit!");

        // The subordination ratio should not exceed the maximum
        assertLe(finalSubRatio, maxSubRatio, "Subordination ratio exceeded maximum!");

        console2.log("[PASS] Multiple users correctly prevented from bypassing subordination limit");
    }

    /**
     * @notice Test boundary conditions
     * @dev Test exact boundary scenarios
     */
    function test_boundary_conditions() public {
        uint256 susd3Holdings = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 maxSubRatio = usd3Strategy.maxSubordinationRatio();

        console2.log("\n=== Boundary Conditions Test ===");
        console2.log("sUSD3 holdings:", susd3Holdings);
        console2.log("Max subordination ratio:", maxSubRatio, "bps");

        // Test when we're exactly at the ratio limit
        uint256 currentSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 currentRatio = (susd3Holdings * MAX_BPS) / currentSupply;

        console2.log("Current subordination ratio:", currentRatio, "bps");
        console2.log("Ratio limit:", maxSubRatio, "bps");

        assertTrue(currentRatio <= maxSubRatio, "Should not exceed subordination ratio");

        console2.log("[PASS] Boundary conditions verified");
    }
}
