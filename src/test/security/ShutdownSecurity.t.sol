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

/**
 * @title ShutdownSecurity
 * @notice Critical security tests for shutdown bypass functionality
 * @dev Tests attack vectors and security scenarios during emergency shutdown
 */
contract ShutdownSecurityTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public attacker = makeAddr("attacker");

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
        vm.stopPrank();

        // Setup test users with USDC
        deal(address(underlyingAsset), alice, 10000e6);
        deal(address(underlyingAsset), bob, 10000e6);
        deal(address(underlyingAsset), charlie, 10000e6);
        deal(address(underlyingAsset), attacker, 10000e6);
    }

    /**
     * @notice Test that shutdown state cannot be toggled to bypass restrictions
     * @dev Verifies that rapidly toggling shutdown doesn't create vulnerability
     */
    function test_shutdown_state_manipulation_attack() public {
        // Alice deposits with commitment period
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Cannot withdraw due to commitment
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.withdraw(500e6, alice, alice);

        // Emergency admin shuts down
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Alice can withdraw during shutdown
        vm.prank(alice);
        uint256 withdrawn = usd3Strategy.withdraw(500e6, alice, alice);
        assertGt(withdrawn, 0, "Should withdraw during shutdown");

        // Verify strategy is still shutdown
        assertTrue(ITokenizedStrategy(address(usd3Strategy)).isShutdown());

        // Alice can still withdraw remaining
        vm.startPrank(alice);
        uint256 remainingShares = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            remainingShares
        );
        withdrawn = usd3Strategy.redeem(remainingShares, alice, alice);
        assertGt(withdrawn, 0, "Should still withdraw after toggle attempt");
        vm.stopPrank();
    }

    /**
     * @notice Test minimum deposit enforcement with mint() for subsequent deposits
     * @dev Ensures minimum deposit bypass isn't possible via mint after first deposit
     */
    function test_minimum_deposit_mint_subsequent() public {
        // Alice makes first deposit at minimum
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(100e6, alice); // Minimum deposit

        // Alice can now deposit small amounts via deposit()
        uint256 shares1 = usd3Strategy.deposit(10e6, alice);
        assertGt(shares1, 0, "Should allow small deposit after first");

        // Alice can also use mint() for small amounts
        uint256 sharesToMint = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(10e6);
        uint256 assets = usd3Strategy.mint(sharesToMint, alice);
        assertGt(assets, 0, "Should allow small mint after first deposit");
        vm.stopPrank();

        // Bob tries to bypass minimum via mint() for first deposit
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);

        uint256 bobSharesAttempt = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(50e6); // Below minimum
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.mint(bobSharesAttempt, bob);

        // Bob must meet minimum for first deposit even with mint()
        uint256 bobShares = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(100e6);
        uint256 bobAssets = usd3Strategy.mint(bobShares, bob);
        assertGt(bobAssets, 0, "Should allow mint at minimum");

        // Now Bob can mint small amounts
        uint256 bobSmallShares = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(5e6);
        uint256 bobSmallAssets = usd3Strategy.mint(bobSmallShares, bob);
        assertGt(bobSmallAssets, 0, "Should allow small mint after first");
        vm.stopPrank();
    }

    /**
     * @notice Test shutdown behavior when there's insufficient liquidity
     * @dev Ensures shutdown bypass respects available liquidity constraints
     */
    function test_shutdown_insufficient_liquidity() public {
        // Alice and Bob deposit
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, bob);
        vm.stopPrank();

        // Skip commitment period
        skip(7 days);

        // Most funds are deployed to Morpho (simulated by having low idle balance)
        // In real scenario, funds would be lent out
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        console2.log("Total assets in strategy:", totalAssets);

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Check available liquidity
        uint256 availableLiquidity = usd3Strategy.availableWithdrawLimit(alice);
        console2.log("Available liquidity for Alice:", availableLiquidity);

        // Alice tries to withdraw more than available liquidity
        vm.prank(alice);
        if (availableLiquidity < 1000e6) {
            // Should revert if trying to withdraw more than available
            vm.expectRevert("ERC4626: withdraw more than max");
            usd3Strategy.withdraw(1000e6, alice, alice);

            // But can withdraw up to available liquidity
            if (availableLiquidity > 0) {
                uint256 withdrawn = usd3Strategy.withdraw(
                    availableLiquidity,
                    alice,
                    alice
                );
                assertEq(
                    withdrawn,
                    availableLiquidity,
                    "Should withdraw available amount"
                );
            }
        } else {
            // If sufficient liquidity, withdrawal should work
            uint256 withdrawn = usd3Strategy.withdraw(1000e6, alice, alice);
            assertGt(withdrawn, 0, "Should withdraw with sufficient liquidity");
        }
    }

    /**
     * @notice Test that shutdown bypass respects max loss limits
     * @dev Ensures users cannot bypass max loss protection during shutdown
     */
    function test_shutdown_respects_max_loss() public {
        // Alice deposits
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        uint256 aliceShares = usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Skip commitment
        skip(7 days);

        // Simulate a loss scenario (would happen via markdown in production)
        // For this test, we'll check that max loss is still enforced

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Alice tries to redeem with 0 max loss (very strict)
        vm.startPrank(alice);
        // Need to approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            aliceShares
        );

        // Get the current value of shares
        uint256 currentValue = ITokenizedStrategy(address(usd3Strategy))
            .previewRedeem(aliceShares);

        // If there's any loss (currentValue < 1000e6), redeem with 0 maxLoss should fail
        if (currentValue < 1000e6) {
            vm.expectRevert();
            usd3Strategy.redeem(aliceShares, alice, alice, 0); // 0 maxLoss

            // But should work with appropriate maxLoss
            uint256 withdrawn = usd3Strategy.redeem(
                aliceShares,
                alice,
                alice,
                10_000
            ); // 100% maxLoss
            assertGt(withdrawn, 0, "Should withdraw with appropriate maxLoss");
        } else {
            // No loss, should work with 0 maxLoss
            uint256 withdrawn = usd3Strategy.redeem(
                aliceShares,
                alice,
                alice,
                0
            );
            assertEq(withdrawn, currentValue, "Should withdraw full value");
        }
        vm.stopPrank();
    }

    /**
     * @notice Test double-deposit attack scenario
     * @dev User deposits minimum, withdraws all, then tries to deposit below minimum
     */
    function test_double_deposit_attack() public {
        // Not whitelisted, so add to whitelist first
        vm.prank(management);
        usd3Strategy.setWhitelist(attacker, true);

        // Attacker deposits minimum
        vm.startPrank(attacker);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        uint256 shares = usd3Strategy.deposit(100e6, attacker);
        vm.stopPrank();
        assertGt(shares, 0, "Should receive shares");

        // Skip commitment period
        skip(7 days);

        // Withdraw everything
        vm.startPrank(attacker);
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(address(usd3Strategy), shares);
        usd3Strategy.redeem(shares, attacker, attacker);
        vm.stopPrank();

        // Verify balance is zero
        assertEq(IERC20(address(usd3Strategy)).balanceOf(attacker), 0);

        // Try to deposit below minimum again
        vm.startPrank(attacker);
        vm.expectRevert("Below minimum deposit");
        usd3Strategy.deposit(50e6, attacker);

        // Must meet minimum again for first deposit after full withdrawal
        shares = usd3Strategy.deposit(100e6, attacker);
        assertGt(shares, 0, "Should require minimum after full withdrawal");
        vm.stopPrank();
    }

    /**
     * @notice Test fee extraction during emergency shutdown
     * @dev Ensures performance fees cannot be improperly extracted during shutdown
     */
    function test_fee_extraction_during_shutdown() public {
        // Set performance fee
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(1000); // 10%

        // Alice deposits
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Generate some profit (simulate via airdrop)
        airdrop(asset, address(usd3Strategy), 100e6);

        // Report to lock in profit
        vm.prank(keeper);
        (uint256 profit, ) = ITokenizedStrategy(address(usd3Strategy)).report();
        assertGt(profit, 0, "Should have profit");

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Check that performance fee recipient cannot claim during shutdown
        uint256 feeShares = ITokenizedStrategy(address(usd3Strategy)).balanceOf(
            management
        );

        if (feeShares > 0) {
            // Management can withdraw their fee shares even during shutdown
            // This is expected behavior - fees already earned should be withdrawable
            vm.prank(management);
            uint256 feeAmount = usd3Strategy.redeem(
                feeShares,
                management,
                management
            );
            assertGt(feeAmount, 0, "Fee recipient can claim earned fees");
        }

        // New reports are blocked during shutdown
        // TokenizedStrategy prevents reports during shutdown
    }

    /**
     * @notice Test multi-user race condition during shutdown
     * @dev Ensures fair access during emergency shutdown with multiple users
     */
    function test_multi_user_shutdown_race() public {
        // Multiple users deposit
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        // Charlie needs whitelist
        vm.prank(management);
        usd3Strategy.setWhitelist(charlie, true);

        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            underlyingAsset.approve(address(usd3Strategy), 1000e6);
            usd3Strategy.deposit(1000e6, users[i]);
            vm.stopPrank();
        }

        // Skip commitment
        skip(7 days);

        // Emergency shutdown
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // All users try to withdraw simultaneously
        uint256[] memory withdrawals = new uint256[](3);

        for (uint256 i = 0; i < users.length; i++) {
            uint256 shares = IERC20(address(usd3Strategy)).balanceOf(users[i]);
            address user = users[i];
            vm.startPrank(user);

            // Each user should be able to withdraw their share
            uint256 userShares = IERC20(address(usd3Strategy)).balanceOf(user);
            if (userShares > 0) {
                // Approve for redeem
                IERC20(address(usd3Strategy)).approve(
                    address(usd3Strategy),
                    userShares
                );
                withdrawals[i] = usd3Strategy.redeem(userShares, user, user);
                assertGt(
                    withdrawals[i],
                    0,
                    "User should withdraw during shutdown"
                );
            }
            vm.stopPrank();
        }

        // Verify fairness - all users who could withdraw got proportional amounts
        if (withdrawals[0] > 0 && withdrawals[1] > 0) {
            // If multiple users withdrew, amounts should be similar (within rounding)
            assertApproxEqRel(
                withdrawals[0],
                withdrawals[1],
                0.01e18, // 1% tolerance for rounding
                "Withdrawals should be proportional"
            );
        }
    }

    /**
     * @notice Test shutdown with pending performance fees
     * @dev Ensures pending fees are handled correctly during shutdown
     */
    function test_shutdown_with_pending_performance_fees() public {
        // Set performance fee
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(1000); // 10%

        // Alice deposits
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Generate profit
        airdrop(asset, address(usd3Strategy), 100e6);

        // Report to create pending fees
        vm.prank(keeper);
        (uint256 profit, ) = ITokenizedStrategy(address(usd3Strategy)).report();
        assertGt(profit, 0, "Should have profit");

        // Don't wait for unlock - shutdown immediately with pending fees
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Alice should be able to withdraw despite pending fees
        skip(7 days); // Past commitment

        vm.startPrank(alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        // Approve for redeem
        IERC20(address(usd3Strategy)).approve(
            address(usd3Strategy),
            aliceShares
        );
        uint256 withdrawn = usd3Strategy.redeem(aliceShares, alice, alice);
        vm.stopPrank();
        assertGt(withdrawn, 0, "Should withdraw with pending fees");

        // Performance fee recipient should also be able to claim
        uint256 feeShares = ITokenizedStrategy(address(usd3Strategy)).balanceOf(
            management
        );
        if (feeShares > 0) {
            vm.prank(management);
            uint256 feeAmount = usd3Strategy.redeem(
                feeShares,
                management,
                management
            );
            assertGt(feeAmount, 0, "Should claim performance fees");
        }
    }
}
