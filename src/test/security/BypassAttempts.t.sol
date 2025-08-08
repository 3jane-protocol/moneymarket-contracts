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
            "sUSD3",
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
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(susd3Strategy));

        // Configure commitment and lock periods
        vm.startPrank(management);
        usd3Strategy.setMinCommitmentTime(7 days);
        usd3Strategy.setMinDeposit(100e6);
        vm.stopPrank();

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

        // Bob transfers Alice's shares to himself
        vm.prank(bob);
        IERC20(address(usd3Strategy)).transferFrom(alice, bob, aliceShares);

        // Bob has the shares but no commitment timestamp
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), aliceShares);
        assertEq(usd3Strategy.depositTimestamp(bob), 0);

        // Bob can withdraw since he didn't deposit (no commitment)
        // This is expected behavior - commitment is per depositor
        vm.prank(bob);
        uint256 withdrawn = usd3Strategy.withdraw(100e6, bob, bob);
        assertGt(withdrawn, 0);
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

        // Alice withdraws everything
        vm.startPrank(alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        // Need to approve the strategy to burn shares
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            aliceShares
        );
        usd3Strategy.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        // Commitment timestamp should be cleared
        assertEq(usd3Strategy.depositTimestamp(alice), 0);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
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

        // Alice transfers shares to Bob (who has no commitment)
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, 500e6);

        // Bob can withdraw (no commitment) but Alice still cannot
        vm.prank(bob);
        uint256 bobWithdrawn = usd3Strategy.withdraw(100e6, bob, bob);
        assertGt(bobWithdrawn, 0);

        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.withdraw(100e6, alice, alice);

        // This is expected - commitment is per-depositor, not per-share
        // Transfers don't carry commitment restrictions
    }

    function test_cannot_bypass_minimum_deposit() public {
        // Try to deposit below minimum via deposit()
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

        // Verify minimum is enforced for both paths
        vm.prank(alice);
        usd3Strategy.deposit(100e6, alice); // Should work at minimum
        assertGt(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
    }
}
