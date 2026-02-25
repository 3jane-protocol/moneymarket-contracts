// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";

/**
 * @title UpgradeMorphoCredit
 * @notice Deploy new MorphoCredit implementation for v1.1
 * @dev This script ONLY deploys the new implementation.
 *      The actual upgrade MUST be executed via TimelockController.
 *
 *      Changes:
 *      - MarkdownManager → MarkdownController integration
 *      - Settlement calls burnJaneFull() directly
 *      - View functions moved to MorphoCreditLib
 *      - Gas optimizations
 *
 *      ⚠️ IMPORTANT: After deployment, use ScheduleMorphoCreditUpgrade.s.sol
 *                   to schedule the upgrade via Safe → Timelock
 */
contract UpgradeMorphoCredit is Script {
    function run() external returns (address newImplementation) {
        // Load addresses
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");

        console.log("Deploying new MorphoCredit implementation...");
        console.log("  ProtocolConfig:", protocolConfig);

        vm.startBroadcast();

        // Deploy new implementation
        MorphoCredit newImpl = new MorphoCredit(protocolConfig);
        newImplementation = address(newImpl);

        console.log("  New implementation deployed:", newImplementation);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Save this implementation address");
        console.log("  2. Run ScheduleMorphoCreditUpgrade.s.sol to schedule upgrade via Timelock");
        console.log("  3. Wait 2 days for timelock delay");
        console.log("  4. Execute upgrade via ExecuteTimelockViaSafe.s.sol");

        vm.stopBroadcast();

        return newImplementation;
    }
}
