// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {sUSD3} from "../../sUSD3.sol";
import {USD3} from "../../USD3.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";

/**
 * @title CooldownEdgeCases
 * @notice Tests edge cases for sUSD3 cooldown and withdrawal window functionality
 */
contract CooldownEdgeCasesTest is Setup {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    USD3 usd3Strategy;
    sUSD3 susd3Strategy;

    function setUp() public override {
        super.setUp();

        // Deploy USD3 strategy
        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation and proxy
        sUSD3 susd3Implementation = new sUSD3();

        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3Strategy),
            management,
            keeper
        );

        address susd3ProxyAdmin = makeAddr("susd3ProxyAdmin");
        address susd3Proxy = address(
            new TransparentUpgradeableProxy(
                address(susd3Implementation),
                susd3ProxyAdmin,
                susd3InitData
            )
        );

        susd3Strategy = sUSD3(susd3Proxy);

        // Emergency admin is already set in USD3 strategy from Setup

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Give users USDC and get USD3
        deal(address(underlyingAsset), alice, 100_000e6);
        deal(address(underlyingAsset), bob, 100_000e6);

        // Get USD3 for users
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);
        usd3Strategy.deposit(50_000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);
        usd3Strategy.deposit(50_000e6, bob);
        vm.stopPrank();
    }

    /**
     * @notice Test multiple cooldown cancellations and restarts
     */
    function test_multipleCooldownCancellationsAndRestarts() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Start and cancel cooldown multiple times
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(alice);
            susd3Strategy.startCooldown(shares);

            // Skip partial cooldown
            skip(3 days);

            // Cancel cooldown
            susd3Strategy.cancelCooldown();
            vm.stopPrank();

            // Verify cooldown is cancelled
            (uint256 cooldownEnd, , uint256 cooldownShares) = susd3Strategy
                .getCooldownStatus(alice);
            assertEq(cooldownEnd, 0, "Cooldown should be cancelled");
            assertEq(cooldownShares, 0, "Cooldown shares should be zero");
        }

        // Start final cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Skip full cooldown
        skip(7 days);

        // Should be able to withdraw
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw after final cooldown");
    }

    /**
     * @notice Test cooldown behavior during strategy shutdown
     */
    function test_cooldownDuringShutdown() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Start cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Skip partial cooldown
        skip(3 days);

        // Emergency shutdown - sUSD3 doesn't have emergency admin, use management
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // After shutdown, should be able to withdraw immediately despite cooldown not finished
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(
            withdrawn,
            0,
            "Should withdraw immediately after shutdown, bypassing cooldown"
        );
    }

    /**
     * @notice Test starting cooldown with amount greater than balance
     */
    function test_cooldownWithExcessAmount() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Try to start cooldown with more shares than balance
        vm.prank(alice);
        susd3Strategy.startCooldown(shares * 2);

        // Cooldown should be set for the excess amount
        (uint256 cooldownEnd, , uint256 cooldownShares) = susd3Strategy
            .getCooldownStatus(alice);
        assertGt(cooldownEnd, 0, "Cooldown should be started");
        assertEq(
            cooldownShares,
            shares * 2,
            "Cooldown shares should be set to requested amount"
        );

        // Skip cooldown
        skip(7 days);

        // Should only be able to withdraw actual balance
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw actual balance");
    }

    /**
     * @notice Test cooldown window expiry edge cases
     */
    function test_cooldownWindowExpiryEdgeCases() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Start cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Skip to exactly at cooldown end
        skip(7 days);

        // Should be able to withdraw at exact boundary
        vm.prank(alice);
        uint256 withdrawn1 = susd3Strategy.redeem(shares / 2, alice, alice);
        assertGt(withdrawn1, 0, "Should withdraw at cooldown end");

        // Skip to just before window expires (2 days - 1 second)
        skip(2 days - 1);

        // Should still be able to withdraw
        vm.prank(alice);
        uint256 withdrawn2 = susd3Strategy.redeem(shares / 2, alice, alice);
        assertGt(withdrawn2, 0, "Should withdraw before window expires");

        // Start new cooldown for Bob
        vm.startPrank(bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 bobShares = susd3Strategy.deposit(5000e6, bob);
        vm.stopPrank();

        skip(90 days + 1);

        vm.prank(bob);
        susd3Strategy.startCooldown(bobShares);

        // Skip past window
        skip(7 days + 2 days + 1);

        // Should not be able to withdraw after window
        vm.prank(bob);
        vm.expectRevert();
        susd3Strategy.redeem(bobShares, bob, bob);
    }

    /**
     * @notice Test partial cooldown withdrawals
     */
    function test_partialCooldownWithdrawals() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 10000e6);
        uint256 shares = susd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Start cooldown for all shares
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Skip cooldown
        skip(7 days);

        // Withdraw 25%
        vm.prank(alice);
        uint256 withdrawn1 = susd3Strategy.redeem(shares / 4, alice, alice);
        assertGt(withdrawn1, 0, "Should withdraw 25%");

        // Check remaining cooldown
        (, , uint256 remainingCooldown) = susd3Strategy.getCooldownStatus(
            alice
        );
        assertEq(
            remainingCooldown,
            shares - shares / 4,
            "Cooldown should be reduced"
        );

        // Withdraw another 25%
        vm.prank(alice);
        uint256 withdrawn2 = susd3Strategy.redeem(shares / 4, alice, alice);
        assertGt(withdrawn2, 0, "Should withdraw another 25%");

        // Remaining cooldown should be updated
        (, , uint256 finalCooldown) = susd3Strategy.getCooldownStatus(alice);
        assertEq(finalCooldown, shares / 2, "Cooldown should be half");
    }

    /**
     * @notice Test cooldown with zero shares
     */
    function test_cooldownWithZeroShares() public {
        // Try to start cooldown with zero shares
        vm.prank(alice);
        vm.expectRevert("Invalid shares");
        susd3Strategy.startCooldown(0);
    }

    /**
     * @notice Test cooldown before lock period ends
     */
    function test_cooldownBeforeLockPeriod() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Try to start cooldown before lock period
        vm.prank(alice);
        vm.expectRevert("Still in lock period");
        susd3Strategy.startCooldown(shares);

        // Skip to just before lock period ends
        skip(90 days - 1);

        // Still shouldn't be able to start cooldown
        vm.prank(alice);
        vm.expectRevert("Still in lock period");
        susd3Strategy.startCooldown(shares);

        // Skip remaining time
        skip(2);

        // Now should be able to start cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares, shares, "Cooldown should be started");
    }

    /**
     * @notice Test cooldown update with different amounts
     */
    function test_cooldownUpdateWithDifferentAmounts() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 10000e6);
        uint256 shares = susd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Start cooldown for half shares
        vm.prank(alice);
        susd3Strategy.startCooldown(shares / 2);

        (, , uint256 cooldownShares1) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares1, shares / 2, "Cooldown should be half shares");

        // Skip 3 days
        skip(3 days);

        // Update cooldown to full shares (should restart cooldown)
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        (uint256 cooldownEnd2, , uint256 cooldownShares2) = susd3Strategy
            .getCooldownStatus(alice);
        assertEq(cooldownShares2, shares, "Cooldown should be full shares");
        assertGt(cooldownEnd2, block.timestamp, "Cooldown should restart");

        // Should not be able to withdraw immediately
        vm.prank(alice);
        vm.expectRevert();
        susd3Strategy.redeem(shares, alice, alice);

        // Skip new cooldown period
        skip(7 days);

        // Now should be able to withdraw
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw after new cooldown");
    }

    /**
     * @notice Test withdrawal window duration changes
     */
    function test_withdrawalWindowDurationChange() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Start cooldown with default 2-day window
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Change window to 1 day via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        bytes32 SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");
        MockProtocolConfig(protocolConfigAddress).setConfig(
            SUSD3_WITHDRAWAL_WINDOW,
            1 days
        );

        // Skip cooldown
        skip(7 days);

        // Skip 1.5 days into window
        skip(1.5 days);

        // Alice's original 2-day window should still apply
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(withdrawn, 0, "Should use original window duration");

        // Bob starts new cooldown with new 1-day window
        vm.startPrank(bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 bobShares = susd3Strategy.deposit(5000e6, bob);
        vm.stopPrank();

        skip(90 days + 1);

        vm.prank(bob);
        susd3Strategy.startCooldown(bobShares);

        skip(7 days + 1 days + 1);

        // Bob's window should have expired (only 1 day)
        vm.prank(bob);
        vm.expectRevert();
        susd3Strategy.redeem(bobShares, bob, bob);
    }

    /**
     * @notice Test shutdown bypasses all restrictions (lock and cooldown)
     */
    function test_shutdownBypassesAllRestrictions() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Still in lock period (not 90 days yet)
        skip(30 days);

        // Try to withdraw - should fail due to lock period
        vm.prank(alice);
        vm.expectRevert();
        susd3Strategy.redeem(shares, alice, alice);

        // Shutdown the strategy
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // Now should be able to withdraw immediately despite lock period
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(
            withdrawn,
            0,
            "Should withdraw immediately after shutdown despite lock"
        );
    }

    /**
     * @notice Test rapid cooldown starts and cancellations
     */
    function test_rapidCooldownStartsAndCancellations() public {
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Rapid start/cancel cycles
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            susd3Strategy.startCooldown(shares);

            if (i % 2 == 0) {
                vm.prank(alice);
                susd3Strategy.cancelCooldown();
            }
        }

        // Final state should have active cooldown (last iteration didn't cancel)
        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares, shares, "Should have active cooldown");

        // Skip cooldown and withdraw
        skip(7 days);

        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw after rapid cycles");
    }

    /**
     * @notice Test shutdown with pending cooldowns
     * @dev Ensures pending cooldowns are bypassed during shutdown
     */
    function test_shutdown_pending_cooldowns() public {
        // Alice and Bob deposit USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 aliceShares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 bobShares = susd3Strategy.deposit(5000e6, bob);
        vm.stopPrank();

        // Skip lock period
        skip(90 days + 1);

        // Alice starts cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(aliceShares);

        // Bob starts cooldown later
        skip(3 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobShares);

        // Alice is mid-cooldown, Bob just started
        skip(2 days); // Alice at 5 days, Bob at 2 days

        // Emergency shutdown
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // Both should be able to withdraw immediately
        vm.prank(alice);
        uint256 aliceWithdrawn = susd3Strategy.redeem(
            aliceShares,
            alice,
            alice
        );
        assertGt(aliceWithdrawn, 0, "Alice withdraws despite pending cooldown");

        vm.prank(bob);
        uint256 bobWithdrawn = susd3Strategy.redeem(bobShares, bob, bob);
        assertGt(bobWithdrawn, 0, "Bob withdraws despite pending cooldown");
    }

    /**
     * @notice Test emergency admin permissions during shutdown
     * @dev Verifies emergency admin capabilities and limitations
     */
    function test_emergency_admin_shutdown_powers() public {
        // Alice deposits
        vm.startPrank(alice);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), 5000e6);
        uint256 shares = susd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        // Management can shutdown sUSD3
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        assertTrue(
            ITokenizedStrategy(address(susd3Strategy)).isShutdown(),
            "sUSD3 should be shutdown"
        );

        // Alice can withdraw during shutdown
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw during shutdown");

        // Shutdown is permanent - no toggle functionality exists
    }
}
