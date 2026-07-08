// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {ProtocolConfig as IProtocolConfig} from "../../../../src/ProtocolConfig.sol";
import {ICreditLine} from "../../../../src/interfaces/ICreditLine.sol";

/// @title ConfigureEmergencyController
/// @notice Configure EmergencyController as emergencyAdmin on ProtocolConfig and ozd on CreditLine
/// @dev This script creates an atomic batch transaction to:
///      1. ProtocolConfig.setEmergencyAdmin(emergencyController)
///      2. CreditLine.setOzd(emergencyController)
contract ConfigureEmergencyController is Script, SafeHelper {
    // Mainnet addresses
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run(bool send) external isBatch(SAFE_ADDRESS) {
        // Get EmergencyController address from environment
        address emergencyController = vm.envAddress("EMERGENCY_CONTROLLER");
        require(emergencyController != address(0), "EMERGENCY_CONTROLLER not set");

        console2.log("=== Configure EmergencyController Roles ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("EmergencyController:", emergencyController);
        console2.log("ProtocolConfig:", PROTOCOL_CONFIG);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Check current state
        address currentEmergencyAdmin = IProtocolConfig(PROTOCOL_CONFIG).emergencyAdmin();
        address currentOzd = ICreditLine(CREDIT_LINE).ozd();

        console2.log("Current state:");
        console2.log("  ProtocolConfig.emergencyAdmin():", currentEmergencyAdmin);
        console2.log("  CreditLine.ozd():", currentOzd);
        console2.log("");

        if (currentEmergencyAdmin == emergencyController && currentOzd == emergencyController) {
            console2.log("EmergencyController is already configured!");
            return;
        }

        // Encode the configuration calls
        bytes memory setEmergencyAdminCall = abi.encodeCall(IProtocolConfig.setEmergencyAdmin, (emergencyController));

        bytes memory setOzdCall = abi.encodeCall(ICreditLine.setOzd, (emergencyController));

        console2.log("Batch operations:");
        console2.log("  1. ProtocolConfig.setEmergencyAdmin(%s)", emergencyController);
        console2.log("  2. CreditLine.setOzd(%s)", emergencyController);
        console2.log("");

        // Add calls to batch
        addToBatch(PROTOCOL_CONFIG, setEmergencyAdminCall);
        addToBatch(CREDIT_LINE, setOzdCall);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed, EmergencyController will be able to:");
            console2.log("  - Call setConfig(IS_PAUSED, 1) to pause protocol");
            console2.log("  - Call setConfig(DEBT_CAP, 0) to stop borrowing");
            console2.log("  - Call setConfig(MAX_ON_CREDIT, 0) to stop credit deployments");
            console2.log("  - Call setConfig(USD3_SUPPLY_CAP, 0) to stop deposits");
            console2.log("  - Call emergencyRevokeCreditLine() to revoke credit lines");
            console2.log("");
            console2.log("=== Deployment Complete! ===");
            console2.log("Update Notion with the new addresses.");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Verify the configuration after deployment
    function verify() external view {
        address emergencyController = vm.envAddress("EMERGENCY_CONTROLLER");
        require(emergencyController != address(0), "EMERGENCY_CONTROLLER not set");

        console2.log("=== Verifying EmergencyController Configuration ===");
        console2.log("Expected EmergencyController:", emergencyController);
        console2.log("");

        address actualEmergencyAdmin = IProtocolConfig(PROTOCOL_CONFIG).emergencyAdmin();
        address actualOzd = ICreditLine(CREDIT_LINE).ozd();

        console2.log("ProtocolConfig.emergencyAdmin():", actualEmergencyAdmin);
        if (actualEmergencyAdmin == emergencyController) {
            console2.log("  [OK] Matches EmergencyController");
        } else {
            console2.log("  [FAIL] Does not match EmergencyController");
        }

        console2.log("");
        console2.log("CreditLine.ozd():", actualOzd);
        if (actualOzd == emergencyController) {
            console2.log("  [OK] Matches EmergencyController");
        } else {
            console2.log("  [FAIL] Does not match EmergencyController");
        }

        console2.log("");
        if (actualEmergencyAdmin == emergencyController && actualOzd == emergencyController) {
            console2.log("=== All checks passed! ===");
        } else {
            console2.log("=== Some checks failed! ===");
        }
    }

    function run() external {
        this.run(false);
    }
}
