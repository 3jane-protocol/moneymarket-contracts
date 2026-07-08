// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";

/**
 * @title UpgradeSUSD3
 * @notice Deploy new sUSD3 implementation for v1.1
 * @dev This script ONLY deploys the new implementation.
 *      The actual upgrade MUST be executed via TimelockController.
 *
 *      Changes:
 *      - Subordination logic now uses USDC values instead of USD3 share ratios
 *      - Updated availableDepositLimit() calculation
 *      - New subordinated debt cap/floor logic from ProtocolConfig
 *
 *      ⚠️ IMPORTANT: Must be executed AFTER USD3 upgrade is complete
 *      ⚠️ IMPORTANT: After deployment, use ScheduleSUSD3Upgrade.s.sol
 *                   to schedule the upgrade via Safe → Timelock
 */
contract UpgradeSUSD3 is Script {
    function run() external returns (address newImplementation) {
        console.log("Deploying new sUSD3 implementation...");

        vm.startBroadcast();

        // Deploy new implementation
        sUSD3 newImpl = new sUSD3();
        newImplementation = address(newImpl);

        console.log("  New implementation deployed:", newImplementation);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Save this implementation address");
        console.log("  2. WAIT for USD3 upgrade to complete");
        console.log("  3. Run ScheduleSUSD3Upgrade.s.sol to schedule upgrade via Timelock");
        console.log("  4. Wait 2 days for timelock delay");
        console.log("  5. Execute upgrade via ExecuteTimelockViaSafe.s.sol");
        console.log("");
        console.log("Note: Subordination logic will use USDC values after upgrade");

        vm.stopBroadcast();

        return newImplementation;
    }
}
