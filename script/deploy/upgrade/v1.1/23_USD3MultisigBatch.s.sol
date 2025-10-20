// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IUSD3} from "../../../../src/usd3/interfaces/IUSD3.sol";

/**
 * @title USD3MultisigBatch
 * @notice Generate atomic multisig batch transaction for USD3 upgrade
 * @dev ⚠️ CRITICAL: Must be executed atomically to prevent user losses
 *
 *      Problem: After reinitialize() switches asset to USDC, totalAssets() is stale
 *      (still shows waUSDC amounts). If waUSDC appreciated (PPS > 1), users withdrawing
 *      would receive less than entitled value.
 *
 *      Solution: Execute report() BEFORE and AFTER upgrade to update totalAssets correctly.
 *
 *      Multisig Batch Order (8 operations):
 *      1. setPerformanceFee(0) - Prevent fee distribution during report
 *      2. setProfitMaxUnlockTime(0) - Ensure immediate profit availability
 *      3. report() - Update totalAssets with old implementation
 *      4. upgrade(newImplementation) - Upgrade proxy implementation
 *      5. report() - Update totalAssets with new implementation
 *      6. reinitialize() - Switch asset from waUSDC to USDC
 *      7. syncTrancheShare() - Restore performance fee to sUSD3
 *      8. Restore performance fee settings
 *
 *      See: test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol
 */
contract USD3MultisigBatch is Script {
    function run() external {
        console.log("========================================");
        console.log("USD3 UPGRADE MULTISIG BATCH GENERATOR");
        console.log("========================================");
        console.log("");

        // Load addresses
        address usd3Proxy = vm.envAddress("USD3_ADDRESS");
        address newUsd3Impl = vm.envAddress("USD3_NEW_IMPL_ADDRESS");

        // Get current settings to restore later
        console.log("Step 0: Reading current USD3 settings...");
        console.log("  USD3 Proxy:", usd3Proxy);
        console.log("  New Implementation:", newUsd3Impl);

        IUSD3 usd3 = IUSD3(usd3Proxy);

        // Read current performance fee settings
        // Note: These functions might not be in interface, add if needed
        console.log("");
        console.log("Current settings (save these for step 7):");
        console.log("  Current asset:", usd3.asset());
        console.log("  (Performance fee and profit unlock time to be saved manually)");

        console.log("");
        console.log("========================================");
        console.log("MULTISIG BATCH TRANSACTION CALLS");
        console.log("========================================");
        console.log("");
        console.log("Execute the following calls atomically in a single transaction:");
        console.log("");

        // Generate call data for each step
        console.log("1. usd3.setPerformanceFee(0)");
        bytes memory call1 = abi.encodeWithSignature("setPerformanceFee(uint16)", uint16(0));
        console.log("   Calldata:", vm.toString(call1));
        console.log("");

        console.log("2. usd3.setProfitMaxUnlockTime(0)");
        bytes memory call2 = abi.encodeWithSignature("setProfitMaxUnlockTime(uint256)", uint256(0));
        console.log("   Calldata:", vm.toString(call2));
        console.log("");

        console.log("3. usd3.report()");
        bytes memory call3 = abi.encodeWithSignature("report()");
        console.log("   Calldata:", vm.toString(call3));
        console.log("   Purpose: Updates totalAssets with OLD implementation");
        console.log("");

        console.log("4. ProxyAdmin.upgrade(usd3Proxy, newImplementation)");
        address proxyAdmin = Upgrades.getAdminAddress(usd3Proxy);
        bytes memory call4 = abi.encodeWithSignature("upgrade(address,address)", usd3Proxy, newUsd3Impl);
        console.log("   ProxyAdmin:", proxyAdmin);
        console.log("   Calldata:", vm.toString(call4));
        console.log("");

        console.log("5. usd3.report()");
        bytes memory call5 = abi.encodeWithSignature("report()");
        console.log("   Calldata:", vm.toString(call5));
        console.log("   Purpose: Updates totalAssets with NEW implementation");
        console.log("");

        console.log("6. usd3.reinitialize()");
        bytes memory call6 = abi.encodeWithSignature("reinitialize()");
        console.log("   Calldata:", vm.toString(call6));
        console.log("   Purpose: Switches asset from waUSDC to USDC");
        console.log("");

        console.log("7. usd3.syncTrancheShare()");
        bytes memory call7 = abi.encodeWithSignature("syncTrancheShare()");
        console.log("   Calldata:", vm.toString(call7));
        console.log("   Purpose: Restore performance fee distribution to sUSD3");
        console.log("");

        console.log("8. Restore performance fee settings");
        console.log("   usd3.setPerformanceFee(previousValue)");
        console.log("   usd3.setProfitMaxUnlockTime(previousValue)");
        console.log("   (Use values from Step 0)");
        console.log("");

        console.log("========================================");
        console.log("VERIFICATION");
        console.log("========================================");
        console.log("");
        console.log("After execution, verify:");
        console.log("  - usd3.asset() == USDC_ADDRESS");
        console.log("  - totalAssets() reflects correct USDC value");
        console.log("  - User withdrawals receive correct amounts");
        console.log("");
    }
}
