// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title USD3 Upgrade Multisig Batch Test
 * @notice Tests the multisig batch upgrade process to prevent user losses when waUSDC PPS > 1
 * @dev Demonstrates that executing report() immediately after reinitialize() prevents accounting issues
 */
contract USD3UpgradeMultisigBatchTest is Setup {
    address alice;
    address bob;
    address charlie;

    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC per user
    uint256 constant WAUSDC_PRICE_110 = 1.1e6; // 1.1 USDC per waUSDC
    uint256 constant WAUSDC_PRICE_120 = 1.2e6; // 1.2 USDC per waUSDC

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
    }

    /**
     * @notice Helper function to simulate multisig batch upgrade
     * @param includeReport Whether to include report() in the batch (correct upgrade)
     */
    function executeUpgradeBatch(bool includeReport) internal {
        // Store current values
        uint256 currentProfitMaxUnlockTime = strategy.profitMaxUnlockTime();

        // Step 1: Set performance fee to 0
        vm.prank(management);
        strategy.setPerformanceFee(0);

        // Step 2: Set profit unlock time to 0
        vm.prank(management);
        strategy.setProfitMaxUnlockTime(0);

        // Step 3: Report (only if correct upgrade)
        if (includeReport) {
            vm.prank(keeper);
            strategy.report();
        }

        // Step 4: Sync tranche share (restores performance fee)
        vm.prank(keeper);
        strategy.syncTrancheShare();

        // Step 5: Restore profit unlock time
        vm.prank(management);
        strategy.setProfitMaxUnlockTime(currentProfitMaxUnlockTime);
    }

    /**
     * @notice Test that users lose value when upgrading WITHOUT report
     * @dev This demonstrates the problem we're trying to avoid
     */
    function test_upgradeWithoutReport_userLosses() public {
        // Start with waUSDC at 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Users deposit USDC
        airdrop(asset, alice, INITIAL_DEPOSIT);
        airdrop(asset, bob, INITIAL_DEPOSIT);
        airdrop(asset, charlie, INITIAL_DEPOSIT);

        vm.prank(alice);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(alice);
        strategy.deposit(INITIAL_DEPOSIT, alice);

        vm.prank(bob);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(bob);
        strategy.deposit(INITIAL_DEPOSIT, bob);

        vm.prank(charlie);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(charlie);
        strategy.deposit(INITIAL_DEPOSIT, charlie);

        // Capture state before upgrade
        uint256 aliceSharesBefore = strategy.balanceOf(alice);
        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 totalSupplyBefore = strategy.totalSupply();

        console2.log("Before upgrade (without report):");
        console2.log("  Alice shares:", aliceSharesBefore);
        console2.log("  Total assets:", totalAssetsBefore);
        console2.log("  Total supply:", totalSupplyBefore);
        console2.log("  Share price:", totalAssetsBefore * 1e18 / totalSupplyBefore);

        // Simulate time passing and waUSDC appreciating
        vm.warp(block.timestamp + 30 days);
        waUSDC.setSharePrice(WAUSDC_PRICE_120); // Now 1.2 USDC per waUSDC

        // Execute upgrade WITHOUT report (incorrect process)
        executeUpgradeBatch(false);

        // Check state after incorrect upgrade
        uint256 totalAssetsAfter = strategy.totalAssets();
        uint256 sharePrice = totalAssetsAfter * 1e18 / strategy.totalSupply();

        console2.log("\nAfter upgrade (without report):");
        console2.log("  Total assets:", totalAssetsAfter);
        console2.log("  Share price:", sharePrice);

        // Alice tries to withdraw
        uint256 alicePreview = strategy.previewRedeem(aliceSharesBefore);
        console2.log("  Alice can withdraw:", alicePreview);

        // Alice gets back LESS than she deposited because totalAssets wasn't updated
        // totalAssets still shows 3000 (old waUSDC amount) instead of 3600 (actual USDC value)
        assertEq(totalAssetsAfter, totalAssetsBefore, "Total assets not updated");
        assertEq(alicePreview, INITIAL_DEPOSIT, "Alice gets original amount, not appreciated value");

        // The actual value should be 1200 USDC (1000 * 1.2) but Alice only gets 1000
        uint256 expectedValue = INITIAL_DEPOSIT * WAUSDC_PRICE_120 / 1e6;
        uint256 lossAmount = expectedValue - alicePreview;
        console2.log("  Alice LOSES:", lossAmount, "USDC");

        assertGt(lossAmount, 0, "User should lose value without report");
    }

    /**
     * @notice Test correct upgrade WITH multisig batch including report
     * @dev This demonstrates the correct upgrade process
     */
    function test_upgradeWithMultisigBatch_noLosses() public {
        // Start with waUSDC at 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Users deposit USDC
        airdrop(asset, alice, INITIAL_DEPOSIT);
        airdrop(asset, bob, INITIAL_DEPOSIT);
        airdrop(asset, charlie, INITIAL_DEPOSIT);

        vm.prank(alice);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(alice);
        strategy.deposit(INITIAL_DEPOSIT, alice);

        vm.prank(bob);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(bob);
        strategy.deposit(INITIAL_DEPOSIT, bob);

        vm.prank(charlie);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(charlie);
        strategy.deposit(INITIAL_DEPOSIT, charlie);

        // Capture state before upgrade
        uint256 aliceSharesBefore = strategy.balanceOf(alice);
        uint256 totalAssetsBefore = strategy.totalAssets();
        uint256 totalSupplyBefore = strategy.totalSupply();

        console2.log("Before upgrade (with report):");
        console2.log("  Alice shares:", aliceSharesBefore);
        console2.log("  Total assets:", totalAssetsBefore);
        console2.log("  Total supply:", totalSupplyBefore);
        console2.log("  Share price:", totalAssetsBefore * 1e18 / totalSupplyBefore);

        // Simulate time passing and waUSDC appreciating
        vm.warp(block.timestamp + 30 days);
        waUSDC.setSharePrice(WAUSDC_PRICE_120); // Now 1.2 USDC per waUSDC

        // Execute upgrade WITH report (correct process)
        executeUpgradeBatch(true);

        // Check state after correct upgrade
        uint256 totalAssetsAfter = strategy.totalAssets();
        uint256 sharePrice = totalAssetsAfter * 1e18 / strategy.totalSupply();

        console2.log("\nAfter upgrade (with report):");
        console2.log("  Total assets:", totalAssetsAfter);
        console2.log("  Share price:", sharePrice);

        // Alice tries to withdraw
        uint256 alicePreview = strategy.previewRedeem(aliceSharesBefore);
        console2.log("  Alice can withdraw:", alicePreview);

        // Total assets should now reflect the true USDC value
        uint256 expectedTotalAssets = 3000e6 * WAUSDC_PRICE_120 / 1e6; // 3600 USDC
        assertApproxEqAbs(totalAssetsAfter, expectedTotalAssets, 3, "Total assets correctly updated");

        // Alice gets her proportional share of the appreciated value
        uint256 expectedAliceValue = INITIAL_DEPOSIT * WAUSDC_PRICE_120 / 1e6;
        assertApproxEqAbs(alicePreview, expectedAliceValue, 3, "Alice gets full appreciated value");

        console2.log("  Alice receives FULL value, no loss!");

        // Actually withdraw to verify
        vm.prank(alice);
        uint256 withdrawn = strategy.redeem(aliceSharesBefore, alice, alice);
        assertApproxEqAbs(withdrawn, expectedAliceValue, 3, "Actual withdrawal matches expected");
        assertEq(asset.balanceOf(alice), withdrawn, "Alice received USDC");
    }

    /**
     * @notice Fuzz test upgrade with various waUSDC prices
     * @param appreciationPercent The percentage waUSDC appreciates (bounded between 0 and 100%)
     */
    function test_upgradeMultisigBatch_variousPrices(uint256 appreciationPercent) public {
        // Bound appreciation between 0 and 100%
        appreciationPercent = bound(appreciationPercent, 0, 100);

        console2.log("Testing with appreciation percent:", appreciationPercent);

        // Always start with 1:1 for initial deposits
        waUSDC.setSharePrice(1e6);

        // Users deposit USDC
        airdrop(asset, alice, INITIAL_DEPOSIT);
        airdrop(asset, bob, INITIAL_DEPOSIT);

        vm.prank(alice);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(alice);
        strategy.deposit(INITIAL_DEPOSIT, alice);

        vm.prank(bob);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(bob);
        strategy.deposit(INITIAL_DEPOSIT, bob);

        // Record initial shares
        uint256 aliceShares = strategy.balanceOf(alice);
        uint256 bobShares = strategy.balanceOf(bob);
        uint256 totalSupply = strategy.totalSupply();

        // Simulate waUSDC appreciation
        uint256 newSharePrice = 1e6 * (100 + appreciationPercent) / 100;
        waUSDC.setSharePrice(newSharePrice);

        // Execute correct upgrade with report
        executeUpgradeBatch(true);

        // Verify total assets updated correctly
        uint256 totalAssetsAfter = strategy.totalAssets();
        uint256 expectedTotalAssets = 2000e6 * newSharePrice / 1e6; // Scale from 1:1 initial ratio

        // Allow for some rounding error
        assertApproxEqRel(
            totalAssetsAfter,
            expectedTotalAssets,
            0.001e18, // 0.1% tolerance
            "Total assets correctly updated for various prices"
        );

        // Verify users can withdraw their proportional share
        uint256 aliceWithdrawable = strategy.previewRedeem(aliceShares);
        uint256 bobWithdrawable = strategy.previewRedeem(bobShares);

        uint256 aliceExpected = expectedTotalAssets * aliceShares / totalSupply;
        uint256 bobExpected = expectedTotalAssets * bobShares / totalSupply;

        assertApproxEqAbs(aliceWithdrawable, aliceExpected, 10, "Alice gets correct value");
        assertApproxEqAbs(bobWithdrawable, bobExpected, 10, "Bob gets correct value");

        // Verify no value is lost
        uint256 totalWithdrawable = aliceWithdrawable + bobWithdrawable;
        assertApproxEqAbs(totalWithdrawable, totalAssetsAfter, 10, "No value lost in upgrade");
    }

    /**
     * @notice Test that report updates totalAssets correctly for waUSDC pricing
     */
    function test_reportUpdatesTotalAssetsCorrectly() public {
        // Initial setup with waUSDC at 1:1
        waUSDC.setSharePrice(1e6);

        // User deposits
        airdrop(asset, alice, INITIAL_DEPOSIT);
        vm.prank(alice);
        asset.approve(address(strategy), INITIAL_DEPOSIT);
        vm.prank(alice);
        strategy.deposit(INITIAL_DEPOSIT, alice);

        uint256 totalAssetsBefore = strategy.totalAssets();
        assertEq(totalAssetsBefore, INITIAL_DEPOSIT, "Initial total assets");

        // waUSDC appreciates
        waUSDC.setSharePrice(WAUSDC_PRICE_110);

        // Before report, totalAssets unchanged
        assertEq(strategy.totalAssets(), totalAssetsBefore, "Total assets unchanged before report");

        // After report, totalAssets reflects new value
        vm.prank(keeper);
        strategy.report();

        uint256 totalAssetsAfter = strategy.totalAssets();
        uint256 expectedAssets = INITIAL_DEPOSIT * WAUSDC_PRICE_110 / 1e6;
        assertApproxEqAbs(totalAssetsAfter, expectedAssets, 2, "Total assets updated after report");

        console2.log("Report correctly updated totalAssets:");
        console2.log("  Before:", totalAssetsBefore);
        console2.log("  After:", totalAssetsAfter);
        console2.log("  Gain:", totalAssetsAfter - totalAssetsBefore);
    }
}
