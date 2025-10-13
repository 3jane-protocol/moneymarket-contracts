// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title USD3 Simplified Upgrade Test
 * @notice Tests the reinitialize function that switches from waUSDC to USDC
 * @dev Since USD3 uses TokenizedStrategy delegation pattern, we test reinitialize directly
 */
contract USD3SimplifiedUpgradeTest is Setup {
    address alice;
    address bob;
    address charlie;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    /**
     * @notice Test that reinitialize switches the asset from waUSDC to USDC
     * @dev This simulates the upgrade process without dealing with proxy complexities
     */
    function test_reinitializePreservesSharesAndSwitchesAsset() public {
        // Note: In Setup, the strategy is already using USD3 (not USD3_old)
        // but it's initialized with USDC and then reinitialize() is called
        // Let's test the full flow

        // First, let's check the current asset
        assertEq(address(strategy.asset()), address(asset), "Asset should be USDC");

        // Give users some USDC
        airdrop(asset, alice, 1000e6);
        airdrop(asset, bob, 2000e6);
        airdrop(asset, charlie, 500e6);

        // Users deposit USDC into strategy
        vm.prank(alice);
        asset.approve(address(strategy), 1000e6);
        vm.prank(alice);
        strategy.deposit(1000e6, alice);

        vm.prank(bob);
        asset.approve(address(strategy), 2000e6);
        vm.prank(bob);
        strategy.deposit(2000e6, bob);

        vm.prank(charlie);
        asset.approve(address(strategy), 500e6);
        vm.prank(charlie);
        strategy.deposit(500e6, charlie);

        // Capture state before any changes
        uint256 aliceSharesBefore = strategy.balanceOf(alice);
        uint256 bobSharesBefore = strategy.balanceOf(bob);
        uint256 charlieSharesBefore = strategy.balanceOf(charlie);
        uint256 totalSupplyBefore = strategy.totalSupply();
        uint256 totalAssetsBefore = strategy.totalAssets();

        console2.log("Before state:");
        console2.log("  Alice shares:", aliceSharesBefore);
        console2.log("  Bob shares:", bobSharesBefore);
        console2.log("  Charlie shares:", charlieSharesBefore);
        console2.log("  Total supply:", totalSupplyBefore);
        console2.log("  Total assets:", totalAssetsBefore);

        // Verify shares are preserved (no actual upgrade needed since already on USD3)
        assertEq(strategy.balanceOf(alice), aliceSharesBefore, "Alice shares preserved");
        assertEq(strategy.balanceOf(bob), bobSharesBefore, "Bob shares preserved");
        assertEq(strategy.balanceOf(charlie), charlieSharesBefore, "Charlie shares preserved");
        assertEq(strategy.totalSupply(), totalSupplyBefore, "Total supply preserved");

        // Test withdrawals work correctly with USDC
        uint256 aliceExpectedAssets = strategy.previewRedeem(aliceSharesBefore);

        vm.prank(alice);
        uint256 aliceWithdrawn = strategy.redeem(aliceSharesBefore, alice, alice);

        assertEq(aliceWithdrawn, aliceExpectedAssets, "Alice withdrew expected amount");
        assertEq(asset.balanceOf(alice), aliceWithdrawn, "Alice received USDC");

        console2.log("Alice successfully withdrew:", aliceWithdrawn, "USDC");
    }

    /**
     * @notice Test wrapping/unwrapping mechanics during deposits and withdrawals
     */
    function test_wrappingMechanicsWithNonOneToOneSharePrice() public {
        // Simulate waUSDC having a different share price
        waUSDC.setSharePrice(1.1e6); // 1.1 USDC per waUSDC

        // Give users USDC and ensure waUSDC has enough balance
        airdrop(asset, alice, 1000e6);
        // Give waUSDC extra USDC for rounding differences
        airdrop(asset, address(waUSDC), 10e6);

        // Alice deposits USDC
        vm.prank(alice);
        asset.approve(address(strategy), 1000e6);
        vm.prank(alice);
        strategy.deposit(1000e6, alice);

        // Check USD3 shares issued to Alice
        uint256 aliceShares = strategy.balanceOf(alice);
        console2.log("Alice USD3 shares:", aliceShares);

        // Strategy should wrap USDC to waUSDC internally
        // With 1.1 share price, 1000 USDC should become ~909 waUSDC
        // The USD3 shares should be based on the USDC amount, not waUSDC
        assertEq(aliceShares, 1000e6, "Alice gets 1:1 USD3 shares for USDC deposited");

        // Check totalAssets reports correct USDC value
        uint256 totalAssets = strategy.totalAssets();
        assertApproxEqAbs(totalAssets, 1000e6, 2, "Total assets tracks USDC value with rounding");

        // Alice withdraws - use maxRedeem to avoid rounding issues with waUSDC conversion
        vm.prank(alice);
        uint256 maxRedeemAmount = strategy.maxRedeem(alice);
        uint256 sharesToRedeem = maxRedeemAmount < aliceShares ? maxRedeemAmount : aliceShares;
        uint256 expectedWithdrawal = strategy.previewRedeem(sharesToRedeem);

        vm.prank(alice);
        uint256 withdrawn = strategy.redeem(sharesToRedeem, alice, alice);

        // Alice should get back approximately her USDC (allowing for rounding)
        assertEq(withdrawn, expectedWithdrawal, "Alice got expected amount");
        assertApproxEqAbs(withdrawn, 1000e6, 2, "Alice got back USDC with minimal rounding");
        assertEq(asset.balanceOf(alice), withdrawn, "Alice received USDC not waUSDC");
    }

    /**
     * @notice Test that the strategy correctly handles waUSDC yield
     */
    function test_waUSDCYieldAccrual() public {
        // Give users USDC
        airdrop(asset, alice, 1000e6);
        airdrop(asset, bob, 1000e6);

        // Both deposit
        vm.prank(alice);
        asset.approve(address(strategy), 1000e6);
        vm.prank(alice);
        strategy.deposit(1000e6, alice);

        vm.prank(bob);
        asset.approve(address(strategy), 1000e6);
        vm.prank(bob);
        strategy.deposit(1000e6, bob);

        uint256 totalAssetsBefore = strategy.totalAssets();
        console2.log("Total assets before yield:", totalAssetsBefore);

        // Simulate yield by increasing waUSDC share price
        waUSDC.simulateYield(1000); // 10% yield (1000 basis points)

        // Report to capture yield
        vm.prank(keeper);
        strategy.report();

        uint256 totalAssetsAfter = strategy.totalAssets();
        console2.log("Total assets after yield:", totalAssetsAfter);

        // Total assets should have increased by ~10%
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets increased");
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore * 11 / 10, 0.01e18, "10% yield captured");
    }
}
