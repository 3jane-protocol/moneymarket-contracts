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
 * @title ShutdownIntegration
 * @notice Integration tests for shutdown scenarios across USD3 and sUSD3
 * @dev Tests complex interactions during emergency shutdown
 */
contract ShutdownIntegrationTest is Setup {
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
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(susd3Strategy));

        // Configure restrictions
        vm.startPrank(management);
        usd3Strategy.setMinCommitmentTime(7 days);
        usd3Strategy.setMinDeposit(100e6);
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        usd3Strategy.setWhitelist(bob, true);
        usd3Strategy.setWhitelist(charlie, true);
        vm.stopPrank();

        // Setup test users with USDC
        deal(address(underlyingAsset), alice, 10000e6);
        deal(address(underlyingAsset), bob, 10000e6);
        deal(address(underlyingAsset), charlie, 10000e6);
    }

    /**
     * @notice Test USD3 and sUSD3 interaction during shutdown
     * @dev Verifies both strategies handle shutdown correctly when linked
     */
    function test_usd3_susd3_shutdown_interaction() public {
        // Alice deposits into USD3
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(2000e6, alice);
        vm.stopPrank();

        // Bob deposits into USD3
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(2000e6, bob);
        vm.stopPrank();

        // Skip commitment for USD3
        skip(7 days);

        // Alice stakes USD3 into sUSD3
        vm.startPrank(alice);
        uint256 aliceUsd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );
        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            aliceUsd3Balance
        );

        // Check subordination limit
        uint256 maxSusd3 = susd3Strategy.availableDepositLimit(alice);
        uint256 depositAmount = aliceUsd3Balance > maxSusd3
            ? maxSusd3
            : aliceUsd3Balance / 2;
        uint256 susd3Shares = susd3Strategy.deposit(depositAmount, alice);
        assertGt(susd3Shares, 0, "Should receive sUSD3 shares");
        vm.stopPrank();

        // Shutdown both strategies
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        vm.prank(management); // sUSD3 uses management for shutdown
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // Alice should be able to withdraw from sUSD3 immediately (bypassing lock)
        vm.startPrank(alice);
        IERC20(address(susd3Strategy)).approve(
            address(susd3Strategy),
            susd3Shares
        );
        uint256 withdrawn = susd3Strategy.redeem(susd3Shares, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw sUSD3 during shutdown");
        vm.stopPrank();

        // Bob should be able to withdraw USD3 immediately
        vm.startPrank(bob);
        uint256 bobUsd3 = IERC20(address(usd3Strategy)).balanceOf(bob);
        IERC20(address(usd3Strategy)).approve(address(usd3Strategy), bobUsd3);
        uint256 bobWithdrawn = usd3Strategy.redeem(bobUsd3, bob, bob);
        assertGt(bobWithdrawn, 0, "Should withdraw USD3 during shutdown");
        vm.stopPrank();

        // Verify both strategies are shutdown
        assertTrue(ITokenizedStrategy(address(usd3Strategy)).isShutdown());
        assertTrue(ITokenizedStrategy(address(susd3Strategy)).isShutdown());
    }

    /**
     * @notice Test multi-user concurrent withdrawals during shutdown
     * @dev Ensures system handles multiple simultaneous withdrawal requests
     */
    function test_multi_user_shutdown_withdrawal() public {
        // Multiple users deposit into USD3
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 1000e6;
        deposits[1] = 1500e6;
        deposits[2] = 2000e6;

        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            underlyingAsset.approve(address(usd3Strategy), deposits[i]);
            usd3Strategy.deposit(deposits[i], users[i]);
            vm.stopPrank();
        }

        // Some users also deposit into sUSD3
        skip(7 days); // Past USD3 commitment

        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        uint256 aliceUsd3 = IERC20(address(usd3Strategy)).balanceOf(alice);
        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            aliceUsd3
        );
        uint256 maxDeposit = susd3Strategy.availableDepositLimit(alice);
        uint256 aliceDepositAmount = aliceUsd3 / 2 > maxDeposit
            ? maxDeposit
            : aliceUsd3 / 2;
        uint256 aliceSusd3 = susd3Strategy.deposit(aliceDepositAmount, alice);
        vm.stopPrank();

        // Emergency shutdown both strategies
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // All users try to withdraw simultaneously
        uint256 totalWithdrawn = 0;

        // Alice withdraws from both sUSD3 and remaining USD3
        vm.startPrank(alice);
        uint256 aliceWithdrawnSusd3 = susd3Strategy.redeem(
            aliceSusd3,
            alice,
            alice
        );
        uint256 aliceRemainingUsd3 = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );
        uint256 aliceWithdrawnUsd3 = usd3Strategy.redeem(
            aliceRemainingUsd3,
            alice,
            alice
        );
        totalWithdrawn += aliceWithdrawnSusd3 + aliceWithdrawnUsd3;
        vm.stopPrank();

        // Bob and Charlie withdraw USD3
        for (uint256 i = 1; i < users.length; i++) {
            address user = users[i];
            vm.startPrank(user);
            uint256 shares = IERC20(address(usd3Strategy)).balanceOf(user);
            // Approve for redeem
            IERC20(address(usd3Strategy)).approve(
                address(usd3Strategy),
                shares
            );
            uint256 withdrawn = usd3Strategy.redeem(shares, user, user);
            totalWithdrawn += withdrawn;
            assertGt(withdrawn, 0, "User should withdraw during shutdown");
            vm.stopPrank();
        }

        console2.log("Total withdrawn by all users:", totalWithdrawn);
        assertGt(totalWithdrawn, 0, "Should have successful withdrawals");
    }

    /**
     * @notice Test whitelist + minimum deposit + shutdown interaction
     * @dev Complex scenario with multiple restrictions during shutdown
     */
    function test_triple_restriction_shutdown() public {
        // Dave is not whitelisted
        address dave = makeAddr("dave");
        deal(address(underlyingAsset), dave, 10000e6);

        // Alice deposits (whitelisted, meets minimum)
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 200e6);
        usd3Strategy.deposit(200e6, alice);
        vm.stopPrank();

        // Dave cannot deposit (not whitelisted)
        vm.startPrank(dave);
        underlyingAsset.approve(address(usd3Strategy), 200e6);
        vm.expectRevert("ERC4626: deposit more than max");
        usd3Strategy.deposit(200e6, dave);
        vm.stopPrank();

        // Bob tries to deposit below minimum (whitelisted)
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 50e6);
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(50e6, bob);
        vm.stopPrank();

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // During shutdown:
        // - Alice can withdraw immediately (bypasses commitment)
        vm.startPrank(alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            aliceShares
        );
        uint256 aliceWithdrawn = usd3Strategy.redeem(aliceShares, alice, alice);
        assertGt(aliceWithdrawn, 0, "Alice withdraws during shutdown");
        vm.stopPrank();

        // - Dave still cannot deposit (shutdown prevents all deposits)
        vm.startPrank(dave);
        vm.expectRevert("ERC4626: deposit more than max");
        usd3Strategy.deposit(200e6, dave);
        vm.stopPrank();

        // - Bob still cannot deposit (shutdown prevents all deposits)
        vm.startPrank(bob);
        vm.expectRevert("ERC4626: deposit more than max");
        usd3Strategy.deposit(100e6, bob);
        vm.stopPrank();

        // Verify that deposits are blocked during shutdown
        // The deposit limit check isn't meaningful here - what matters is that deposits fail
        // These were already tested above with expectRevert
    }

    /**
     * @notice Test deposit-withdraw-deposit cycle with minimum deposit
     * @dev Ensures minimum deposit logic works correctly across cycles
     */
    function test_minimum_deposit_withdrawal_cycle() public {
        // Initial deposit at minimum
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        uint256 shares1 = usd3Strategy.deposit(100e6, alice);
        assertGt(shares1, 0, "First deposit at minimum");

        // Can deposit small amount as existing depositor
        uint256 shares2 = usd3Strategy.deposit(10e6, alice);
        assertGt(shares2, 0, "Small subsequent deposit allowed");

        // Skip commitment period
        skip(7 days);

        // Partial withdrawal (check limits first)
        uint256 partialShares = shares1 / 2;
        uint256 maxRedeemableNow = ITokenizedStrategy(address(usd3Strategy))
            .maxRedeem(alice);
        uint256 toRedeemNow = partialShares > maxRedeemableNow
            ? maxRedeemableNow
            : partialShares;

        if (toRedeemNow > 0) {
            IERC20(address(usd3Strategy)).approve(
                address(usd3Strategy),
                toRedeemNow
            );
            uint256 withdrawn1 = usd3Strategy.redeem(toRedeemNow, alice, alice);
            assertGt(withdrawn1, 0, "Partial withdrawal successful");
        }

        // Can still deposit small amounts (still has balance)
        uint256 shares3 = usd3Strategy.deposit(5e6, alice);
        assertGt(shares3, 0, "Small deposit after partial withdrawal");

        // Full withdrawal (or max allowed due to subordination)
        skip(7 days); // New commitment from recent deposit
        uint256 remainingShares = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );

        // Check max redeemable in case of subordination limits
        uint256 maxRedeemable = ITokenizedStrategy(address(usd3Strategy))
            .maxRedeem(alice);
        uint256 toRedeem = remainingShares > maxRedeemable
            ? maxRedeemable
            : remainingShares;

        if (toRedeem > 0) {
            IERC20(address(usd3Strategy)).approve(
                address(usd3Strategy),
                toRedeem
            );
            uint256 withdrawn2 = usd3Strategy.redeem(toRedeem, alice, alice);
            assertGt(withdrawn2, 0, "Withdrawal successful");
        }

        // Check if alice still has shares
        uint256 finalShares = IERC20(address(usd3Strategy)).balanceOf(alice);

        if (finalShares == 0) {
            // After full withdrawal, minimum applies again
            vm.expectRevert("Below minimum deposit");
            usd3Strategy.deposit(50e6, alice);

            // Must meet minimum for new cycle
            uint256 shares4 = usd3Strategy.deposit(100e6, alice);
            assertGt(shares4, 0, "New cycle requires minimum");
        } else {
            // Partial withdrawal due to subordination, can still deposit small amounts
            uint256 shares4 = usd3Strategy.deposit(50e6, alice);
            assertGt(
                shares4,
                0,
                "Can deposit small amount with existing balance"
            );
        }
        vm.stopPrank();
    }

    /**
     * @notice Test shutdown with mixed USD3/sUSD3 positions and restrictions
     * @dev Complex scenario with both strategies and various restrictions
     */
    function test_complex_shutdown_scenario() public {
        // Setup: Multiple users with different positions

        // Alice: USD3 only, in commitment period
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Bob: USD3 + sUSD3, past commitment
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(2000e6, bob);
        vm.stopPrank();

        // Charlie: USD3 only initially
        vm.startPrank(charlie);
        underlyingAsset.approve(address(usd3Strategy), 1500e6);
        usd3Strategy.deposit(1500e6, charlie);
        vm.stopPrank();

        skip(7 days); // Past USD3 commitment

        // Bob deposits into sUSD3
        vm.startPrank(bob);
        uint256 bobUsd3 = IERC20(address(usd3Strategy)).balanceOf(bob);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), bobUsd3);
        uint256 maxSusd3 = susd3Strategy.availableDepositLimit(bob);
        uint256 bobSusd3Amount = bobUsd3 / 2 > maxSusd3
            ? maxSusd3
            : bobUsd3 / 2;
        uint256 bobSusd3 = susd3Strategy.deposit(bobSusd3Amount, bob);
        vm.stopPrank();

        // Charlie tries to deposit into sUSD3 but wait for lock to pass first
        vm.startPrank(charlie);
        uint256 charlieUsd3 = IERC20(address(usd3Strategy)).balanceOf(charlie);
        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            charlieUsd3
        );
        uint256 charlieSusd3Amount = susd3Strategy.availableDepositLimit(
            charlie
        );
        if (charlieSusd3Amount > charlieUsd3 / 3) {
            charlieSusd3Amount = charlieUsd3 / 3;
        }
        uint256 charlieSusd3 = 0;
        if (charlieSusd3Amount > 0) {
            charlieSusd3 = susd3Strategy.deposit(charlieSusd3Amount, charlie);
        }
        vm.stopPrank();

        // Wait for lock period to pass for those who want to start cooldown
        skip(90 days);

        // Charlie starts cooldown now that lock has passed (if he has shares)
        if (charlieSusd3 > 0) {
            vm.prank(charlie);
            susd3Strategy.startCooldown(charlieSusd3);
        }

        skip(3 days); // Partial cooldown

        // Emergency shutdown both strategies
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // All users should be able to withdraw immediately

        // Alice (was in commitment period)
        vm.startPrank(alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            aliceShares
        );
        uint256 aliceWithdrawn = usd3Strategy.redeem(aliceShares, alice, alice);
        assertGt(aliceWithdrawn, 0, "Alice withdraws despite commitment");
        vm.stopPrank();

        // Bob (was in lock period for sUSD3)
        vm.startPrank(bob);
        // Approve for redeem
        IERC20(address(susd3Strategy)).approve(
            address(susd3Strategy),
            bobSusd3
        );
        uint256 bobWithdrawnSusd3 = susd3Strategy.redeem(bobSusd3, bob, bob);
        assertGt(bobWithdrawnSusd3, 0, "Bob withdraws sUSD3 despite lock");

        uint256 bobRemainingUsd3 = IERC20(address(usd3Strategy)).balanceOf(bob);
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            bobRemainingUsd3
        );
        uint256 bobWithdrawnUsd3 = usd3Strategy.redeem(
            bobRemainingUsd3,
            bob,
            bob
        );
        assertGt(bobWithdrawnUsd3, 0, "Bob withdraws remaining USD3");
        vm.stopPrank();

        // Charlie (was in cooldown if he had deposits)
        vm.startPrank(charlie);
        uint256 charlieWithdrawnSusd3 = 0;
        if (charlieSusd3 > 0) {
            // Approve for redeem
            IERC20(address(susd3Strategy)).approve(
                address(susd3Strategy),
                charlieSusd3
            );
            charlieWithdrawnSusd3 = susd3Strategy.redeem(
                charlieSusd3,
                charlie,
                charlie
            );
            assertGt(
                charlieWithdrawnSusd3,
                0,
                "Charlie withdraws sUSD3 despite cooldown"
            );
        }

        uint256 charlieRemainingUsd3 = IERC20(address(usd3Strategy)).balanceOf(
            charlie
        );
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            charlieRemainingUsd3
        );
        uint256 charlieWithdrawnUsd3 = usd3Strategy.redeem(
            charlieRemainingUsd3,
            charlie,
            charlie
        );
        assertGt(charlieWithdrawnUsd3, 0, "Charlie withdraws remaining USD3");
        vm.stopPrank();
    }

    /**
     * @notice Test shutdown with protocol config changes
     * @dev Ensures shutdown works correctly even with config parameter changes
     */
    function test_shutdown_with_protocol_config_changes() public {
        // Alice deposits into sUSD3
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 2000e6);
        usd3Strategy.deposit(2000e6, alice);
        vm.stopPrank();

        skip(7 days); // Past commitment

        vm.startPrank(alice);
        uint256 aliceUsd3 = IERC20(address(usd3Strategy)).balanceOf(alice);
        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            aliceUsd3
        );
        uint256 maxDeposit = susd3Strategy.availableDepositLimit(alice);
        uint256 depositAmount = aliceUsd3 / 2 > maxDeposit
            ? maxDeposit
            : aliceUsd3 / 2;
        uint256 aliceSusd3 = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Change protocol config parameters
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Change subordination ratio
        bytes32 SUBORDINATION_RATIO = keccak256("SUBORDINATION_RATIO");
        protocolConfig.setConfig(SUBORDINATION_RATIO, 2000); // 20% instead of 15%

        // Change lock duration
        bytes32 LOCK_DURATION = keccak256("LOCK_DURATION");
        protocolConfig.setConfig(LOCK_DURATION, 120 days); // 120 days instead of 90

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // Alice should still be able to withdraw immediately despite config changes
        vm.startPrank(alice);
        // Approve sUSD3 for redeem
        IERC20(address(susd3Strategy)).approve(
            address(susd3Strategy),
            aliceSusd3
        );
        uint256 withdrawnSusd3 = susd3Strategy.redeem(aliceSusd3, alice, alice);
        assertGt(withdrawnSusd3, 0, "Should withdraw despite config changes");

        uint256 remainingUsd3 = IERC20(address(usd3Strategy)).balanceOf(alice);
        // Approve USD3 for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            remainingUsd3
        );
        uint256 withdrawnUsd3 = usd3Strategy.redeem(
            remainingUsd3,
            alice,
            alice
        );
        assertGt(
            withdrawnUsd3,
            0,
            "Should withdraw USD3 despite config changes"
        );
        vm.stopPrank();
    }

    /**
     * @notice Test partial withdrawals during shutdown
     * @dev Ensures partial withdrawals work correctly during emergency
     */
    function test_shutdown_partial_withdrawal() public {
        // Alice deposits
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        uint256 aliceShares = usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Alice withdraws 25%
        vm.prank(alice);
        uint256 withdrawn1 = usd3Strategy.redeem(aliceShares / 4, alice, alice);
        assertGt(withdrawn1, 0, "First partial withdrawal");

        // Alice withdraws another 25%
        vm.startPrank(alice);
        uint256 withdrawn2 = usd3Strategy.redeem(aliceShares / 4, alice, alice);
        assertGt(withdrawn2, 0, "Second partial withdrawal");
        vm.stopPrank();

        // Alice withdraws remaining 50%
        vm.startPrank(alice);
        uint256 remainingShares = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );
        uint256 withdrawn3 = usd3Strategy.redeem(remainingShares, alice, alice);
        assertGt(withdrawn3, 0, "Final withdrawal");
        vm.stopPrank();

        // Verify all funds withdrawn
        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(alice),
            0,
            "All shares redeemed"
        );
        assertApproxEqRel(
            withdrawn1 + withdrawn2 + withdrawn3,
            1000e6,
            0.01e18, // 1% tolerance for fees/rounding
            "Total withdrawn approximately equals deposit"
        );
    }
}
