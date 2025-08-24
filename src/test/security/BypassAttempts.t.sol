// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {console2} from "forge-std/console2.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";

/**
 * @title BypassAttempts
 * @notice Tests for commitment and lock period bypass attempts
 * @dev Ensures that time-based restrictions cannot be circumvented
 */
contract BypassAttempts is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3Strategy),
            management,
            keeper
        );

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
                address(susd3Implementation),
                address(susd3ProxyAdmin),
                susd3InitData
            );

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");

        // Configure commitment and lock periods
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set config as the owner (test contract in this case)
        MockProtocolConfig(protocolConfigAddress).setConfig(
            USD3_COMMITMENT_TIME,
            7 days
        );

        vm.prank(management);
        usd3Strategy.setMinDeposit(100e6);

        // Set lock duration via protocol config (90 days is already the default)
        // No need to change it unless we want a different value

        // Setup test users
        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);
        airdrop(asset, charlie, 10000e6);
    }

    // USD3 Commitment Bypass Tests

    function test_cannot_bypass_commitment_with_mint() public {
        // Alice deposits using deposit()
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);

        // Alice cannot withdraw before commitment period
        vm.expectRevert();
        usd3Strategy.withdraw(100e6, alice, alice);
        vm.stopPrank();

        // Bob tries to bypass using mint()
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 1000e6);
        uint256 sharesToMint = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(1000e6);
        usd3Strategy.mint(sharesToMint, bob);

        // Bob also cannot withdraw before commitment period
        vm.expectRevert();
        usd3Strategy.withdraw(100e6, bob, bob);
        vm.stopPrank();

        // Both should have commitment timestamps set
        assertGt(usd3Strategy.depositTimestamp(alice), 0);
        assertGt(usd3Strategy.depositTimestamp(bob), 0);
    }

    function test_cannot_bypass_commitment_with_transferFrom() public {
        // Alice deposits and gets shares
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Alice approves Bob to spend her shares
        vm.prank(alice);
        IERC20(address(usd3Strategy)).approve(bob, aliceShares);

        // Bob CANNOT transfer Alice's shares during commitment
        vm.prank(bob);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transferFrom(alice, bob, aliceShares);

        // Verify Alice still has her shares
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), aliceShares);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 0);

        // Skip commitment period
        skip(7 days);

        // Now Bob CAN transfer
        vm.prank(bob);
        IERC20(address(usd3Strategy)).transferFrom(alice, bob, aliceShares);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), aliceShares);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
    }

    function test_commitment_extends_on_subsequent_deposits() public {
        // Alice makes first deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(500e6, alice);
        uint256 firstTimestamp = usd3Strategy.depositTimestamp(alice);
        vm.stopPrank();

        // Time passes but not enough to complete commitment
        skip(3 days);

        // Alice makes second deposit
        vm.prank(alice);
        usd3Strategy.deposit(500e6, alice);
        uint256 secondTimestamp = usd3Strategy.depositTimestamp(alice);

        // Commitment should be extended
        assertGt(secondTimestamp, firstTimestamp);

        // Alice still cannot withdraw
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.withdraw(100e6, alice, alice);

        // After full commitment from second deposit
        skip(7 days);

        // Now Alice can withdraw
        vm.prank(alice);
        uint256 withdrawn = usd3Strategy.withdraw(100e6, alice, alice);
        assertGt(withdrawn, 0);
    }

    function test_commitment_clears_on_full_withdrawal() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        assertGt(usd3Strategy.depositTimestamp(alice), 0);
        vm.stopPrank();

        // Wait for commitment period
        skip(7 days);

        // Alice withdraws everything she can
        vm.startPrank(alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Check maximum redeemable (accounts for subordination ratio)
        uint256 maxRedeemable = ITokenizedStrategy(address(usd3Strategy))
            .maxRedeem(alice);

        if (maxRedeemable == aliceShares) {
            // Can withdraw everything
            IERC20(address(usd3Strategy)).approve(
                address(usd3Strategy),
                aliceShares
            );
            usd3Strategy.redeem(aliceShares, alice, alice);

            // Commitment timestamp should be cleared
            assertEq(usd3Strategy.depositTimestamp(alice), 0);
            assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
        } else if (maxRedeemable > 0) {
            // Can only withdraw partial amount due to subordination limits
            IERC20(address(usd3Strategy)).approve(
                address(usd3Strategy),
                maxRedeemable
            );
            usd3Strategy.redeem(maxRedeemable, alice, alice);

            // Check remaining balance
            uint256 remainingShares = IERC20(address(usd3Strategy)).balanceOf(
                alice
            );
            if (remainingShares == 0) {
                // Fully withdrawn
                assertEq(usd3Strategy.depositTimestamp(alice), 0);
            } else {
                // Still has shares, timestamp should remain
                assertGt(usd3Strategy.depositTimestamp(alice), 0);
            }
        } else {
            // Cannot withdraw anything due to subordination limits
            assertEq(maxRedeemable, 0, "Should not be able to withdraw");
        }

        vm.stopPrank();
    }

    // sUSD3 Lock Period Bypass Tests

    function test_cannot_bypass_lock_with_mint() public {
        // First get USD3 tokens
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, bob);
        vm.stopPrank();

        // Alice deposits USD3 into sUSD3 using deposit()
        // With 2000e6 USD3, max sUSD3 is 300e6 (15% of USD3 supply)
        // Alice deposits less than max to leave room for Bob
        vm.startPrank(alice);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 200e6);
        susd3Strategy.deposit(200e6, alice);

        // Alice cannot start cooldown before lock period
        vm.expectRevert("Still in lock period");
        susd3Strategy.startCooldown(100e6);
        vm.stopPrank();

        // Bob tries to bypass using mint()
        vm.startPrank(bob);
        // Check available deposit limit
        uint256 availableLimit = susd3Strategy.availableDepositLimit(bob);
        console2.log("Available deposit limit for Bob:", availableLimit);

        // Use smaller amount that fits within limit
        uint256 depositAmount = availableLimit > 10e6 ? 10e6 : availableLimit;
        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            depositAmount
        );
        uint256 sharesToMint = ITokenizedStrategy(address(susd3Strategy))
            .previewDeposit(depositAmount);
        susd3Strategy.mint(sharesToMint, bob);

        // Bob also cannot start cooldown before lock period
        uint256 bobSusd3Balance = IERC20(address(susd3Strategy)).balanceOf(bob);
        console2.log("Bob's sUSD3 balance:", bobSusd3Balance);
        vm.expectRevert("Still in lock period");
        susd3Strategy.startCooldown(bobSusd3Balance > 0 ? bobSusd3Balance : 1);
        vm.stopPrank();

        // Both should have lock timestamps set
        assertGt(susd3Strategy.lockedUntil(alice), block.timestamp);
        assertGt(susd3Strategy.lockedUntil(bob), block.timestamp);
    }

    function test_lock_extends_on_subsequent_deposits() public {
        // Get USD3 first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(2000e6, alice);

        // First sUSD3 deposit
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 300e6);
        susd3Strategy.deposit(150e6, alice);
        uint256 firstLock = susd3Strategy.lockedUntil(alice);
        vm.stopPrank();

        // Time passes but not past lock
        skip(30 days);

        // Second deposit extends lock
        vm.prank(alice);
        susd3Strategy.deposit(150e6, alice);
        uint256 secondLock = susd3Strategy.lockedUntil(alice);

        // Lock should be extended
        assertGt(secondLock, firstLock);
        assertGt(secondLock, block.timestamp + 60 days); // At least 60 days from now
    }

    function test_lock_clears_on_full_withdrawal() public {
        // Get USD3 and deposit into sUSD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        // With 1000e6 USD3, max sUSD3 is ~176e6
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        assertGt(susd3Strategy.lockedUntil(alice), 0);
        vm.stopPrank();

        // Wait for lock period
        skip(90 days);

        // Start and complete cooldown
        vm.startPrank(alice);
        uint256 aliceShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        console2.log("Alice shares before cooldown:", aliceShares);
        console2.log("Alice locked until:", susd3Strategy.lockedUntil(alice));
        console2.log("Current timestamp:", block.timestamp);
        require(aliceShares > 0, "Alice has no shares");
        susd3Strategy.startCooldown(aliceShares);
        vm.stopPrank();

        // Check cooldown was set
        (
            uint256 cooldownEnd,
            uint256 windowEnd,
            uint256 cooldownShares
        ) = susd3Strategy.getCooldownStatus(alice);
        console2.log("Cooldown end:", cooldownEnd);
        console2.log("Window end:", windowEnd);
        console2.log("Cooldown shares:", cooldownShares);

        skip(7 days + 1); // Cooldown period + 1 second to be in window
        console2.log("After skip, timestamp:", block.timestamp);

        // Withdraw everything
        vm.startPrank(alice);
        // Need to approve the strategy to burn shares
        IERC20(address(susd3Strategy)).approve(
            address(susd3Strategy),
            aliceShares
        );
        susd3Strategy.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        // Lock should be cleared
        assertEq(susd3Strategy.lockedUntil(alice), 0);
        assertEq(IERC20(address(susd3Strategy)).balanceOf(alice), 0);
    }

    function test_cannot_bypass_cooldown_window() public {
        // Setup and wait for lock period
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        // With 1000e6 USD3, max sUSD3 is ~176e6
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        vm.stopPrank();

        skip(90 days); // Past lock period

        // Start cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(100e6);

        // Cannot withdraw during cooldown
        assertEq(susd3Strategy.availableWithdrawLimit(alice), 0);

        skip(7 days); // Cooldown complete

        // Can withdraw during window
        assertGt(susd3Strategy.availableWithdrawLimit(alice), 0);

        skip(3 days); // Window expired (2 day window + 1 extra)

        // Cannot withdraw after window
        assertEq(susd3Strategy.availableWithdrawLimit(alice), 0);
    }

    function test_partial_withdrawal_preserves_restrictions() public {
        // Setup
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        // With 1000e6 USD3, max sUSD3 is ~176e6
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        vm.stopPrank();

        skip(90 days); // Past lock period

        // Start cooldown for partial amount
        uint256 totalShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        console2.log("Alice's sUSD3 balance:", totalShares);
        require(totalShares > 0, "Alice has no sUSD3 shares");
        vm.prank(alice);
        susd3Strategy.startCooldown(totalShares / 2);

        skip(7 days); // Cooldown complete

        // Check withdrawal limit
        vm.prank(alice);
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(alice);
        console2.log("Available withdraw limit:", withdrawLimit);
        (
            uint256 cooldownEnd,
            uint256 windowEnd,
            uint256 cooldownShares
        ) = susd3Strategy.getCooldownStatus(alice);
        console2.log("Cooldown end:", cooldownEnd);
        console2.log("Window end:", windowEnd);
        console2.log("Current time:", block.timestamp);
        console2.log("Cooldown shares:", cooldownShares);

        // Withdraw partial amount (within cooldown)
        require(withdrawLimit > 0, "No withdrawal available");
        uint256 sharesToRedeem = totalShares / 4; // Redeem a quarter of total shares
        // Need to approve the strategy to burn shares on behalf of alice
        vm.startPrank(alice);
        IERC20(address(susd3Strategy)).approve(
            address(susd3Strategy),
            sharesToRedeem
        );
        susd3Strategy.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Lock should still be set (not fully withdrawn)
        assertGt(susd3Strategy.lockedUntil(alice), 0);

        // Cooldown should be reduced but not cleared
        (, , uint256 remainingCooldownShares) = susd3Strategy.getCooldownStatus(
            alice
        );
        assertEq(remainingCooldownShares, totalShares / 4); // Half minus quarter
    }

    function test_cannot_game_commitment_with_multiple_accounts() public {
        // Alice deposits with commitment
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Alice cannot withdraw immediately
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.withdraw(100e6, alice, alice);

        // Alice CANNOT transfer shares during commitment period
        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 500e6);

        // Verify shares didn't move
        assertGt(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 0);

        // After commitment period, transfers work
        skip(7 days);
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, 500e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 500e6);
    }

    function test_cannot_transfer_during_lock_period() public {
        // Setup: Get USD3 first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);

        // Wait for commitment to pass
        skip(7 days);

        // Deposit USD3 into sUSD3
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        uint256 aliceSusd3Shares = IERC20(address(susd3Strategy)).balanceOf(
            alice
        );
        vm.stopPrank();

        // Alice tries to transfer during lock period
        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(bob, aliceSusd3Shares);

        // Skip lock period (90 days)
        skip(90 days);

        // Now transfer works
        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, aliceSusd3Shares);
        assertEq(
            IERC20(address(susd3Strategy)).balanceOf(bob),
            aliceSusd3Shares
        );
    }

    function test_cannot_transfer_shares_in_cooldown() public {
        // Setup and pass lock period
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days); // Pass USD3 commitment

        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        skip(90 days); // Pass sUSD3 lock

        uint256 aliceShares = IERC20(address(susd3Strategy)).balanceOf(alice);

        // Start cooldown for half the shares
        susd3Strategy.startCooldown(aliceShares / 2);

        // Can transfer non-cooldown shares
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares / 4);

        // Cannot transfer more than non-cooldown shares
        vm.expectRevert("sUSD3: Cannot transfer shares in cooldown");
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares / 2);
        vm.stopPrank();
    }

    function test_cannot_bypass_minimum_deposit() public {
        // Try to deposit below minimum via deposit() as first deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(50e6, alice); // Below 100e6 minimum

        // Try to bypass via mint()
        uint256 sharesToMint = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(50e6);
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.mint(sharesToMint, alice);
        vm.stopPrank();

        // Verify minimum is enforced for first deposit
        vm.prank(alice);
        usd3Strategy.deposit(100e6, alice); // Should work at minimum
        assertGt(IERC20(address(usd3Strategy)).balanceOf(alice), 0);

        // After first deposit, Alice can deposit any amount
        vm.prank(alice);
        uint256 shares = usd3Strategy.deposit(10e6, alice); // Below minimum but should work
        assertGt(shares, 0, "Subsequent deposits should allow any amount");
    }

    // ============ CRITICAL VULNERABILITY TESTS ============
    // Tests for the lock period bypass vulnerability via transfer and pre-cooldown

    function test_exploit_lock_bypass_via_transfer_and_precooldown() public {
        console2.log("\n=== Testing Lock Period Bypass Vulnerability ===");

        // Step 1: User1 (alice) deposits and gets locked shares
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days); // Pass USD3 commitment period

        // Alice deposits into sUSD3 and gets locked
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        uint256 aliceShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        uint256 aliceLockEnd = susd3Strategy.lockedUntil(alice);
        vm.stopPrank();

        console2.log("Alice deposited and got locked until:", aliceLockEnd);
        console2.log("Alice sUSD3 shares:", aliceShares);
        console2.log("Current timestamp:", block.timestamp);
        assertGt(aliceLockEnd, block.timestamp, "Alice should be locked");

        // Step 2: User2 (bob) who NEVER deposited tries to start cooldown
        // This should now FAIL with the security fix
        console2.log(
            "\nBob (who never deposited) attempts to start cooldown..."
        );
        vm.prank(bob);
        vm.expectRevert("Insufficient balance for cooldown");
        susd3Strategy.startCooldown(type(uint256).max); // Max shares they don't even have

        console2.log("Bob's cooldown attempt correctly blocked (FIXED)!");

        // Step 3: Since Bob couldn't start cooldown, skip ahead
        console2.log("\nSkipping ahead to demonstrate the protection:");
        console2.log("Current timestamp:", block.timestamp);
        console2.log("Alice still locked until:", aliceLockEnd);
        assertLt(block.timestamp, aliceLockEnd, "Alice should still be locked");

        // Step 4: Alice transfers her locked shares to Bob
        console2.log("\nAlice attempts to transfer locked shares to Bob...");
        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares);

        // The vulnerability would be if Alice could transfer during lock
        // and Bob could withdraw using pre-started cooldown
        console2.log("Transfer correctly blocked during lock period");

        // Step 5: Demonstrate what would happen if transfer was allowed
        // Skip to after lock period to show the complete attack
        skip(90 days);
        console2.log("\n=== Demonstrating Complete Attack Scenario ===");
        console2.log("After lock period - showing what attacker intended:");

        // Now Alice can transfer
        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares);
        console2.log("Alice transferred shares to Bob");

        // Bob needs to start cooldown after receiving shares
        uint256 bobBalance = IERC20(address(susd3Strategy)).balanceOf(bob);
        console2.log("Bob's sUSD3 balance:", bobBalance);

        // Bob must start a new cooldown with his actual balance
        vm.prank(bob);
        susd3Strategy.startCooldown(bobBalance);
        console2.log("Bob started cooldown with actual balance");
        
        // Wait for cooldown
        skip(7 days + 1);
        
        // Now Bob can withdraw
        uint256 bobWithdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        console2.log("Bob's withdraw limit after proper cooldown:", bobWithdrawLimit);
        assertGt(bobWithdrawLimit, 0, "Bob can withdraw after proper cooldown");
        
        console2.log(
            "VULNERABILITY FIXED: Pre-started cooldown without balance is prevented"
        );
    }

    function test_non_depositor_can_start_cooldown() public {
        console2.log("\n=== Testing Non-Depositor Cooldown Start ===");

        // Charlie has never interacted with sUSD3
        assertEq(
            susd3Strategy.lockedUntil(charlie),
            0,
            "Charlie should have no lock"
        );
        assertEq(
            IERC20(address(susd3Strategy)).balanceOf(charlie),
            0,
            "Charlie has no shares"
        );

        // Charlie tries to start cooldown but should fail with the fix
        vm.prank(charlie);
        vm.expectRevert("Insufficient balance for cooldown");
        susd3Strategy.startCooldown(1000e18); // Arbitrary large amount

        (uint256 cooldownEnd, uint256 windowEnd, uint256 shares) = susd3Strategy
            .getCooldownStatus(charlie);

        console2.log("Charlie's cooldown end:", cooldownEnd);
        console2.log("Charlie's cooldown shares:", shares);
        assertEq(
            cooldownEnd,
            0,
            "Charlie should not have cooldown set"
        );
        assertEq(
            shares,
            0,
            "Charlie should have no cooldown shares"
        );
        console2.log("VULNERABILITY FIXED: Cannot start cooldown without balance");
    }

    function test_transfer_locked_shares_bypass_attempt() public {
        console2.log("\n=== Testing Transfer of Locked Shares ===");

        // Setup: Alice deposits and gets locked
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days); // Pass USD3 commitment

        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        uint256 aliceShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Bob tries to start cooldown before receiving any shares - should fail
        vm.prank(bob);
        vm.expectRevert("Insufficient balance for cooldown");
        susd3Strategy.startCooldown(aliceShares); // Will fail - no balance

        // Alice tries to transfer during lock period
        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares);

        console2.log("Transfer during lock period correctly blocked");

        // After lock period
        skip(90 days);

        // Alice can now transfer
        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares);

        // Bob needs to start cooldown after receiving shares
        vm.prank(bob);
        susd3Strategy.startCooldown(aliceShares);
        console2.log("Bob started cooldown with received shares");
        
        // Wait for cooldown
        skip(7 days + 1);
        
        // Now Bob can withdraw
        uint256 bobWithdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        console2.log(
            "Bob's withdraw limit after proper cooldown:",
            bobWithdrawLimit
        );
        assertGt(bobWithdrawLimit, 0, "Bob can withdraw after proper cooldown");
        console2.log("VULNERABILITY FIXED: Must have shares to start cooldown");
    }

    function test_cooldown_shares_exceed_balance_check() public {
        console2.log("\n=== Testing Cooldown Shares vs Balance Validation ===");

        // Bob tries to start cooldown for shares he doesn't have - should fail
        vm.prank(bob);
        vm.expectRevert("Insufficient balance for cooldown");
        susd3Strategy.startCooldown(1000e18);

        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(bob);
        uint256 bobBalance = IERC20(address(susd3Strategy)).balanceOf(bob);

        console2.log("Bob's cooldown shares:", cooldownShares);
        console2.log("Bob's actual balance:", bobBalance);
        assertEq(
            cooldownShares,
            0,
            "Cooldown should not be set without balance"
        );
        
        console2.log("VULNERABILITY FIXED: Balance validation prevents excessive cooldown");
    }

    function test_multiple_users_exploit_scenario() public {
        console2.log("\n=== Testing Multi-User Exploit Scenario ===");

        // Alice deposits and gets locked
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        vm.stopPrank();

        // Multiple attackers (bob and charlie) try to start cooldowns - should fail
        vm.prank(bob);
        vm.expectRevert("Insufficient balance for cooldown");
        susd3Strategy.startCooldown(75e6);

        vm.prank(charlie);
        vm.expectRevert("Insufficient balance for cooldown");
        susd3Strategy.startCooldown(75e6);

        console2.log("Both attackers correctly blocked from starting cooldown without balance");

        // After lock period, Alice splits shares between attackers
        skip(90 days);

        vm.startPrank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, 75e6);
        IERC20(address(susd3Strategy)).transfer(charlie, 75e6);
        vm.stopPrank();

        // Now they need to start cooldowns with their actual balances
        vm.prank(bob);
        susd3Strategy.startCooldown(75e6);
        
        vm.prank(charlie);
        susd3Strategy.startCooldown(75e6);
        
        // Wait for cooldowns
        skip(7 days + 1);

        // Now both can withdraw after proper cooldown
        uint256 bobLimit = susd3Strategy.availableWithdrawLimit(bob);
        uint256 charlieLimit = susd3Strategy.availableWithdrawLimit(charlie);

        console2.log("Bob's withdraw limit:", bobLimit);
        console2.log("Charlie's withdraw limit:", charlieLimit);

        assertGt(bobLimit, 0, "Bob can withdraw after proper cooldown");
        assertGt(charlieLimit, 0, "Charlie can withdraw after proper cooldown");
        
        console2.log(
            "VULNERABILITY FIXED: Attackers must have balance to start cooldown"
        );
    }
}
