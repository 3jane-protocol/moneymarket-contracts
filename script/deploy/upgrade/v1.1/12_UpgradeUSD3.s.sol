// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";

/**
 * @title UpgradeUSD3
 * @notice Deploy new USD3 implementation for v1.1 upgrade
 * @dev ⚠️ CRITICAL: This script ONLY deploys the new implementation
 *      The actual upgrade MUST be executed via multisig batch (script 23)
 *
 *      Changes:
 *      - Asset switched from waUSDC to USDC
 *      - New reinitialize() function for migration
 *      - waUSDC managed internally for yield generation
 *
 *      ⚠️ DANGER: Upgrading without the atomic multisig batch will cause user losses!
 *      See: test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol
 */
contract UpgradeUSD3 is Script {
    function run() external returns (address newImplementation) {
        console.log("WARNING: USD3 upgrade requires ATOMIC MULTISIG BATCH");
        console.log("WARNING: This script ONLY deploys the new implementation");
        console.log("WARNING: Use script 23_USD3MultisigBatch.s.sol for actual upgrade");
        console.log("");

        console.log("Deploying new USD3 implementation...");

        vm.startBroadcast();

        // Deploy new implementation
        // Note: Constructor parameters will be handled by proxy initialization
        USD3 newUsd3Impl = new USD3();

        newImplementation = address(newUsd3Impl);

        console.log("New USD3 implementation deployed at:", newImplementation);
        console.log("");
        console.log("WARNING: DO NOT upgrade directly!");
        console.log("WARNING: Follow multisig batch procedure in script 23");
        console.log("WARNING: Batch order:");
        console.log("    1. setPerformanceFee(0)");
        console.log("    2. setProfitMaxUnlockTime(0)");
        console.log("    3. report()");
        console.log("    4. upgrade(newImplementation)");
        console.log("    5. reinitialize()");
        console.log("    6. syncTrancheShare()");
        console.log("    7. restore performance fee settings");

        vm.stopBroadcast();

        return newImplementation;
    }
}
