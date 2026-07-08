// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {EmergencyController} from "../../../../src/EmergencyController.sol";

/// @title DeployEmergencyController
/// @notice Deploy the EmergencyController contract for emergency protocol operations
/// @dev EmergencyController provides:
///      - Binary stop controls via setConfig() (IS_PAUSED=1, DEBT_CAP=0, etc.)
///      - Credit line revocation via emergencyRevokeCreditLine()
contract DeployEmergencyController is Script {
    // Mainnet addresses
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant EMERGENCY_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run() external returns (address) {
        console2.log("=== Deploying EmergencyController ===");
        console2.log("ProtocolConfig:", PROTOCOL_CONFIG);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Emergency Safe (owner):", EMERGENCY_SAFE);
        console2.log("");

        vm.startBroadcast();

        EmergencyController ec = new EmergencyController(PROTOCOL_CONFIG, CREDIT_LINE, EMERGENCY_SAFE);

        vm.stopBroadcast();

        console2.log("=== EmergencyController Deployed ===");
        console2.log("EmergencyController address:", address(ec));
        console2.log("");
        console2.log("Verify configuration:");
        console2.log("  ec.protocolConfig():", address(ec.protocolConfig()));
        console2.log("  ec.creditLine():", address(ec.creditLine()));
        console2.log("  ec.owner():", ec.owner());
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Run 03_QueueProtocolConfigUpgrade.s.sol");
        console2.log("2. Wait 5 minutes, then run 04_ExecuteProtocolConfigUpgrade.s.sol");
        console2.log("3. Run 05_ConfigureEmergencyController.s.sol with EMERGENCY_CONTROLLER=%s", address(ec));

        return address(ec);
    }
}
