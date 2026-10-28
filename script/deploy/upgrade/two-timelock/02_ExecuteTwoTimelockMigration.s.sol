// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TwoTimelockMigrationBase} from "./TwoTimelockMigrationBase.s.sol";

/// @title ExecuteTwoTimelockMigration
/// @notice Execute the scheduled two-timelock migration after the existing 24h timelock delay.
contract ExecuteTwoTimelockMigration is Script, SafeHelper, TwoTimelockMigrationBase {
    function run(bool send) external isBatch(MAIN_MULTISIG) isTimelock(EXISTING_24H_TIMELOCK) {
        address sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");
        _validatePreconditions(sevenDayTimelock);

        console2.log("=== Execute Two-Timelock Migration via 24h Timelock ===");
        console2.log("Safe address:", MAIN_MULTISIG);
        console2.log("Existing 24h timelock:", EXISTING_24H_TIMELOCK);
        console2.log("New 7d timelock:", sevenDayTimelock);
        console2.log("Send to Safe:", send);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(sevenDayTimelock);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(EXISTING_24H_TIMELOCK, operationId);
        console2.log("");

        requireOperationReady(EXISTING_24H_TIMELOCK, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(EXISTING_24H_TIMELOCK, executeCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed:");
            console2.log("  - Five ProxyAdmins will be owned by the 7d timelock");
            console2.log("  - Main multisig will no longer hold DEFAULT_ADMIN_ROLE on the 24h timelock");
            console2.log("  - EmergencyController pointers remain unchanged");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check status of the migration operation.
    function checkStatus() external view {
        address sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");
        _validateSevenDayTimelock(sevenDayTimelock);
        _validateNoPointerChange();

        console2.log("=== Checking Two-Timelock Migration Status ===");
        console2.log("New 7d timelock:", sevenDayTimelock);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(sevenDayTimelock);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(EXISTING_24H_TIMELOCK, operationId);
    }

    /// @notice Verify the migration was applied correctly.
    function verify() external view {
        address sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");

        console2.log("=== Verifying Two-Timelock Migration ===");
        console2.log("Expected 7d timelock:", sevenDayTimelock);
        console2.log("");

        _validateFinalState(sevenDayTimelock);

        console2.log("PASS: Five ProxyAdmins are owned by the 7d timelock");
        console2.log("PASS: Main multisig does not hold DEFAULT_ADMIN_ROLE on the 24h timelock");
        console2.log("PASS: ProtocolConfig.emergencyAdmin remains the current EmergencyController");
        console2.log("PASS: CreditLine.ozd remains the current EmergencyController");
    }

    function run() external {
        this.run(false);
    }
}
