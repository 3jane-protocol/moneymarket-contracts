// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AdaptiveCurveIrm} from "../../../../src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";

/**
 * @title UpgradeIRM
 * @notice Deploy new AdaptiveCurveIrm implementation for v1.1
 * @dev This script ONLY deploys the new implementation.
 *      The actual upgrade MUST be executed via TimelockController.
 *
 *      Changes:
 *      - Constructor changed from 1 parameter to 3 parameters
 *      - Aave spread integration for dynamic base rate adjustment
 *      - New constructor: constructor(address morpho, address aavePool, address usdc)
 *
 *      ⚠️ IMPORTANT: After deployment, use ScheduleIRMUpgrade.s.sol
 *                   to schedule the upgrade via Safe → Timelock
 */
contract UpgradeIRM is Script {
    function run() external returns (address newImplementation) {
        // Load addresses
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        address aavePool = vm.envAddress("AAVE_POOL_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        console.log("Deploying new AdaptiveCurveIrm implementation...");
        console.log("  Morpho:", morpho);
        console.log("  Aave Pool:", aavePool);
        console.log("  USDC:", usdc);

        vm.startBroadcast();

        // Deploy new implementation
        AdaptiveCurveIrm newImpl = new AdaptiveCurveIrm(morpho, aavePool, usdc);
        newImplementation = address(newImpl);

        console.log("  New implementation deployed:", newImplementation);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Save this implementation address");
        console.log("  2. Run ScheduleIRMUpgrade.s.sol to schedule upgrade via Timelock");
        console.log("  3. Wait 2 days for timelock delay");
        console.log("  4. Execute upgrade via ExecuteTimelockViaSafe.s.sol");
        console.log("");
        console.log("Note: Aave spread integration will be active after upgrade");

        vm.stopBroadcast();

        return newImplementation;
    }
}
