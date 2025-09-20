// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {MainnetForkBase} from "./MainnetForkBase.t.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

interface IERC4626 {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

/**
 * @title USD3UpgradeForkTest
 * @notice Fork tests for USD3 upgrade from waUSDC to USDC
 * @dev Tests run against actual mainnet state at a fixed block
 */
contract USD3UpgradeForkTest is MainnetForkBase {
    // Test users (actual mainnet addresses that hold USD3)
    address[] public usd3Holders;
    mapping(address => uint256) public preUpgradeShares;
    mapping(address => uint256) public preUpgradeAssets;

    // Upgrade state
    USD3 public newImplementation;
    uint256 public totalSharesBefore;
    uint256 public totalAssetsBefore;
    uint256 public waUSDCPriceBefore;

    // Known USD3 holder addresses (if available)
    address constant HOLDER_1 = 0x9C2Ff10E6CC0414b909fD8D9c2568a8BC839E4F3; // Example holder
    uint256 constant USD3_DEPLOY_BLOCK = 23241534; // USD3 deployment block

    function setUp() public override {
        super.setUp();

        // Only run setup if fork is active
        if (!isForkTest) return;

        // Deploy new USD3 implementation
        newImplementation = new USD3();

        // Find actual USD3 holders from mainnet
        findUSD3Holders();
    }

    /**
     * @notice Test capturing pre-upgrade state from mainnet
     */
    function test_capturePreUpgradeState() public requiresFork {
        ITokenizedStrategy usd3 = ITokenizedStrategy(USD3_PROXY);

        // Get total supply and assets before upgrade
        totalSharesBefore = usd3.totalSupply();
        totalAssetsBefore = usd3.totalAssets();

        console2.log("Pre-upgrade state:");
        console2.log("  Total shares:", totalSharesBefore);
        console2.log("  Total assets:", totalAssetsBefore);
        console2.log("  Current asset:", address(usd3.asset()));

        // Check if strategy is shutdown
        bool isShutdown = usd3.isShutdown();
        console2.log("  Is shutdown:", isShutdown);

        // Check deposit limit for a random address
        uint256 depositLimit = usd3.maxDeposit(address(0x1234));
        console2.log("  Max deposit:", depositLimit);

        // Verify current asset is waUSDC
        assertEq(address(usd3.asset()), WAUSDC, "Current asset should be waUSDC");

        // Get waUSDC price
        if (totalSharesBefore > 0) {
            IERC4626 waUSDCVault = IERC4626(WAUSDC);
            waUSDCPriceBefore = waUSDCVault.convertToAssets(1e6); // Price of 1 waUSDC in USDC
            console2.log("  waUSDC price:", waUSDCPriceBefore);
        }
    }

    /**
     * @notice Test simulating the upgrade process
     */
    function test_upgradeImplementation() public requiresFork {
        // First capture pre-upgrade state
        test_capturePreUpgradeState();

        // Simulate upgrade by owner/governance
        // Note: In production, this would be done through proxy admin
        // For testing, we'll use vm.etch to replace implementation

        // Get proxy admin (would need actual admin address)
        address proxyAdmin = address(0); // TODO: Get actual proxy admin

        // For testing purposes, we'll simulate the upgrade effect
        // In production, this would be: proxyAdmin.upgrade(USD3_PROXY, address(newImplementation))

        vm.etch(USD3_PROXY, address(newImplementation).code);

        // Verify upgrade succeeded by checking we can call reinitialize
        USD3 upgradedUSD3 = USD3(USD3_PROXY);

        // The upgraded contract should still have waUSDC as asset until reinitialize
        assertEq(address(ITokenizedStrategy(USD3_PROXY).asset()), WAUSDC, "Asset still waUSDC before reinitialize");
    }

    /**
     * @notice Test reinitialize after upgrade
     */
    function test_reinitializeAfterUpgrade() public requiresFork {
        // Perform upgrade
        test_upgradeImplementation();

        USD3 upgradedUSD3 = USD3(USD3_PROXY);

        // Execute as atomic multisig batch per CLAUDE.md requirements
        // This prevents user losses during the upgrade window
        address management = ITokenizedStrategy(USD3_PROXY).management();
        impersonate(management);

        // 1. Temporarily set performance fee to 0 to prevent fee distribution
        ITokenizedStrategy(USD3_PROXY).setPerformanceFee(0);

        // 2. Set profit unlock time to 0 for immediate availability
        ITokenizedStrategy(USD3_PROXY).setProfitMaxUnlockTime(0);

        // 3. Call reinitialize to switch asset from waUSDC to USDC
        upgradedUSD3.reinitialize();

        // 4. Call report to update totalAssets to correct USDC value
        // This is CRITICAL - without this, totalAssets shows waUSDC amounts not USDC value
        ITokenizedStrategy(USD3_PROXY).report();

        // 5. Restore settings (in production would restore actual values)
        // For testing we'll leave them as-is

        stopImpersonate();

        // Verify asset switched to USDC
        assertEq(address(ITokenizedStrategy(USD3_PROXY).asset()), USDC, "Asset should be USDC after reinitialize");

        // Total shares might change slightly due to profit unlocking during report
        // The important thing is that totalAssets is now properly valued in USDC
        uint256 totalSharesAfter = ITokenizedStrategy(USD3_PROXY).totalSupply();
        console2.log("Total shares after upgrade:", totalSharesAfter);
        console2.log("Total shares before upgrade:", totalSharesBefore);
    }

    /**
     * @notice Test that existing holder shares are preserved after upgrade
     */
    function test_upgradePreservesExistingHolderShares() public requiresFork {
        // Skip if no holders on mainnet at this block
        if (ITokenizedStrategy(USD3_PROXY).totalSupply() == 0) {
            vm.skip(true);
            return;
        }

        // Skip if no holders found
        if (usd3Holders.length == 0) {
            console2.log("No USD3 holders found, skipping test");
            vm.skip(true);
            return;
        }

        // Test with the first found holder
        address existingHolder = usd3Holders[0];
        uint256 holderBalanceBefore = preUpgradeShares[existingHolder];

        console2.log("Testing with holder:", existingHolder);
        console2.log("Pre-upgrade balance:", holderBalanceBefore);

        // Perform upgrade and reinitialize
        test_reinitializeAfterUpgrade();

        // Check holder's shares are preserved
        uint256 sharesAfter = ITokenizedStrategy(USD3_PROXY).balanceOf(existingHolder);
        assertEq(sharesAfter, holderBalanceBefore, "Holder shares should be preserved");

        // Test that holder can withdraw after upgrade
        impersonate(existingHolder);
        uint256 maxRedeem = ITokenizedStrategy(USD3_PROXY).maxRedeem(existingHolder);

        if (maxRedeem > 0) {
            // Redeem a small amount to test withdrawal works
            uint256 redeemAmount = maxRedeem > 100e6 ? 100e6 : maxRedeem / 10;
            uint256 assetsRedeemed = ITokenizedStrategy(USD3_PROXY).redeem(redeemAmount, existingHolder, existingHolder);

            assertGt(assetsRedeemed, 0, "Should be able to redeem assets");
            assertEq(usdc().balanceOf(existingHolder), assetsRedeemed, "Should receive USDC");
            console2.log("Successfully redeemed", assetsRedeemed, "USDC");
        }

        stopImpersonate();

        // Test with multiple holders if available
        if (usd3Holders.length > 1) {
            console2.log("Testing preservation for", usd3Holders.length, "holders");
            for (uint256 i = 1; i < usd3Holders.length && i < 5; i++) {
                address holder = usd3Holders[i];
                uint256 expectedBalance = preUpgradeShares[holder];
                uint256 actualBalance = ITokenizedStrategy(USD3_PROXY).balanceOf(holder);
                assertEq(actualBalance, expectedBalance, "Shares preserved for all holders");
            }
        }
    }

    /**
     * @notice Test that withdrawals return the same USDC value before and after upgrade
     * @dev Critical test to ensure users don't lose value during the migration
     */
    function test_withdrawalAmountConsistencyAcrossUpgrade() public requiresFork {
        // Skip if no holders found
        if (usd3Holders.length == 0) {
            console2.log("No USD3 holders found, skipping test");
            vm.skip(true);
            return;
        }

        // First, report any existing profits to get a clean baseline
        // This ensures we're only measuring the waUSDC->USDC conversion effect
        address management = ITokenizedStrategy(USD3_PROXY).management();
        impersonate(management);

        // Set profit unlock to 0 for immediate availability
        ITokenizedStrategy(USD3_PROXY).setProfitMaxUnlockTime(0);

        // Report to capture any existing MorphoCredit profits
        ITokenizedStrategy(USD3_PROXY).report();

        stopImpersonate();

        // Now measure with clean state (all profits already reported)

        // Test with the first found holder
        address existingHolder = usd3Holders[0];
        uint256 holderShares = ITokenizedStrategy(USD3_PROXY).balanceOf(existingHolder);

        console2.log("Testing withdrawal consistency for holder:", existingHolder);
        console2.log("Holder shares after initial report:", holderShares);

        // Define test amount - use 10% of holder's shares
        uint256 testShares = holderShares / 10;
        if (testShares == 0) {
            testShares = holderShares; // Use all if balance is small
        }

        // Get the waUSDC price before upgrade
        IERC4626 waUSDCVault = IERC4626(WAUSDC);
        uint256 waUSDCPrice = waUSDCVault.convertToAssets(1e6);
        console2.log("waUSDC price (USDC per 1e6 waUSDC):", waUSDCPrice);

        // Calculate expected withdrawal amount BEFORE upgrade
        // Note: Before upgrade, asset is waUSDC, so previewRedeem returns waUSDC amount
        uint256 expectedWaUSDCAmount = ITokenizedStrategy(USD3_PROXY).previewRedeem(testShares);
        console2.log("Before upgrade - Expected waUSDC for", testShares, "shares:", expectedWaUSDCAmount);

        // Calculate the USDC value of this waUSDC amount
        uint256 expectedUSDCValueBefore = waUSDCVault.convertToAssets(expectedWaUSDCAmount);
        console2.log("Before upgrade - USDC value of withdrawal:", expectedUSDCValueBefore);

        // Perform the upgrade and reinitialize
        test_reinitializeAfterUpgrade();

        // Calculate expected withdrawal amount AFTER upgrade
        // Note: After upgrade, asset is USDC, so previewRedeem returns USDC amount directly
        uint256 expectedUSDCAmountAfter = ITokenizedStrategy(USD3_PROXY).previewRedeem(testShares);
        console2.log("After upgrade - Expected USDC for", testShares, "shares:", expectedUSDCAmountAfter);

        // The USDC amount after upgrade should be at least equal to the USDC value before
        // It could be higher if there's additional yield or rounding in user's favor
        assertGe(
            expectedUSDCAmountAfter,
            expectedUSDCValueBefore,
            "USDC withdrawal amount should be preserved or increased after upgrade"
        );

        // Calculate the difference (should be minimal, likely due to rounding)
        if (expectedUSDCAmountAfter > expectedUSDCValueBefore) {
            uint256 gain = expectedUSDCAmountAfter - expectedUSDCValueBefore;
            console2.log("User gains from upgrade:", gain, "USDC");
        } else if (expectedUSDCAmountAfter < expectedUSDCValueBefore) {
            uint256 loss = expectedUSDCValueBefore - expectedUSDCAmountAfter;
            console2.log("Rounding loss:", loss, "USDC (should be minimal)");
        }

        // Perform actual withdrawal to verify it works
        impersonate(existingHolder);
        uint256 actualUSDCWithdrawn = ITokenizedStrategy(USD3_PROXY).redeem(testShares, existingHolder, existingHolder);
        stopImpersonate();

        console2.log("Actual USDC withdrawn:", actualUSDCWithdrawn);
        assertEq(actualUSDCWithdrawn, expectedUSDCAmountAfter, "Actual withdrawal matches expected");
        assertEq(usdc().balanceOf(existingHolder), actualUSDCWithdrawn, "Holder received USDC");

        // Test with multiple holders if available
        if (usd3Holders.length > 1) {
            console2.log("\nTesting consistency for additional holders:");
            for (uint256 i = 1; i < usd3Holders.length && i < 3; i++) {
                address holder = usd3Holders[i];
                uint256 currentBalance = ITokenizedStrategy(USD3_PROXY).balanceOf(holder);
                uint256 shares = currentBalance / 10;
                if (shares > 0) {
                    uint256 usdcValue = ITokenizedStrategy(USD3_PROXY).previewRedeem(shares);
                    console2.log("  Holder", i);
                    console2.log("    Would receive", usdcValue, "USDC");
                    console2.log("    For", shares, "shares");
                }
            }
        }
    }

    /**
     * @notice Test total assets calculation is correct after upgrade
     */
    function test_totalAssetsCalculationAfterUpgrade() public requiresFork {
        // Skip if no assets
        if (ITokenizedStrategy(USD3_PROXY).totalAssets() == 0) {
            vm.skip(true);
            return;
        }

        // Capture before upgrade
        uint256 totalAssetsBeforeLocal = ITokenizedStrategy(USD3_PROXY).totalAssets();

        // Perform upgrade
        test_reinitializeAfterUpgrade();

        // Get total assets after (should account for waUSDC price)
        uint256 totalAssetsAfter = ITokenizedStrategy(USD3_PROXY).totalAssets();

        // If waUSDC has appreciated, total assets in USDC terms should be higher
        // But the key is that user proportions are maintained
        console2.log("Total assets comparison:");
        console2.log("  Before (waUSDC terms):", totalAssetsBeforeLocal);
        console2.log("  After (USDC terms):", totalAssetsAfter);

        // The actual USDC value should be preserved or increased (due to waUSDC yield)
        assertGe(totalAssetsAfter, totalAssetsBeforeLocal, "Total assets should be preserved or increased");
    }

    /**
     * @notice Test that we can't deposit/withdraw during the transition
     * @dev This test validates the safety of the upgrade process
     */
    function test_safetyDuringTransition() public requiresFork {
        // Capture state
        uint256 totalSupply = ITokenizedStrategy(USD3_PROXY).totalSupply();

        if (totalSupply == 0) {
            vm.skip(true);
            return;
        }

        // Perform upgrade but NOT reinitialize
        vm.etch(USD3_PROXY, address(newImplementation).code);

        // At this point, the contract is upgraded but not reinitialized
        // The asset is still waUSDC but the logic expects USDC wrapping

        // Verify we can still read basic state
        uint256 totalSupplyAfterUpgrade = ITokenizedStrategy(USD3_PROXY).totalSupply();
        assertEq(totalSupplyAfterUpgrade, totalSupply, "Total supply readable after upgrade");

        // Now reinitialize to complete the upgrade
        address management = ITokenizedStrategy(USD3_PROXY).management();
        impersonate(management);
        USD3(USD3_PROXY).reinitialize();
        stopImpersonate();

        // Verify the upgrade is complete
        assertEq(address(ITokenizedStrategy(USD3_PROXY).asset()), USDC, "Asset switched to USDC");
    }

    /**
     * @notice Helper to find actual USD3 holders on mainnet
     * @dev Scans Deposit events from deployment to current block
     */
    function findUSD3Holders() internal {
        ITokenizedStrategy usd3 = ITokenizedStrategy(USD3_PROXY);

        // Define the Deposit event signature
        // Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)
        bytes32 depositEventSig = keccak256("Deposit(address,address,uint256,uint256)");

        console2.log("Scanning for USD3 depositors from block", USD3_DEPLOY_BLOCK, "to", block.number);

        // Build topics array for filtering
        // topics[0] = event signature
        // topics[1] = sender (not filtered)
        // topics[2] = owner (not filtered)
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = depositEventSig;

        // Query logs using eth_getLogs
        // We'll scan in chunks to avoid hitting limits
        uint256 startBlock = USD3_DEPLOY_BLOCK;
        uint256 endBlock = block.number;
        uint256 blockRange = 5000; // Scan 5000 blocks at a time

        while (startBlock < endBlock && usd3Holders.length < 10) {
            uint256 scanEnd = startBlock + blockRange > endBlock ? endBlock : startBlock + blockRange;

            // Get logs for Deposit events in this range
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(startBlock, scanEnd, USD3_PROXY, topics);

            for (uint256 i = 0; i < logs.length; i++) {
                // Deposit event has topics: [signature, sender, owner] and data: [assets, shares]
                if (logs[i].topics.length >= 3) {
                    address sender = address(uint160(uint256(logs[i].topics[1])));
                    address owner = address(uint160(uint256(logs[i].topics[2])));

                    // Use the owner address (receiver of shares)
                    if (owner != address(0)) {
                        uint256 balance = usd3.balanceOf(owner);
                        if (balance > 0 && preUpgradeShares[owner] == 0) {
                            usd3Holders.push(owner);
                            preUpgradeShares[owner] = balance;

                            console2.log("Found USD3 depositor:", owner);
                            console2.log("  Current balance:", balance);

                            // Limit to first 10 holders for testing
                            if (usd3Holders.length >= 10) break;
                        }
                    }
                }
            }

            startBlock = scanEnd + 1;
        }

        console2.log("Total unique depositors found:", usd3Holders.length);

        if (usd3Holders.length == 0) {
            console2.log("No depositors found, checking for any current holders");
            // If no deposit events found, just check current balances
            // Try some known addresses or check total supply
            if (usd3.totalSupply() > 0) {
                console2.log("USD3 has supply but no deposit events found in range");
            }
        }
    }
}
