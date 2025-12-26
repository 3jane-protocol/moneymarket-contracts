// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";

/// @title QueueTimelockDelayExtension
/// @notice Queue a timelock operation to extend the delay from 5 minutes to 24 hours
/// @dev This script:
///      1. Encodes Timelock.updateDelay(86400) - 24 hours
///      2. Wraps in Timelock.schedule() with minimum delay
///      3. Submits to Safe for proposer signatures
contract QueueTimelockDelayExtension is Script, SafeHelper, TimelockHelper {
    // Mainnet addresses
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    // New delay: 24 hours in seconds
    uint256 constant NEW_DELAY = 86400;

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        console2.log("=== Queue Timelock Delay Extension ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New delay:", NEW_DELAY, "seconds (24 hours)");
        console2.log("Send to Safe:", send);
        console2.log("");

        // Get current delay from timelock
        uint256 currentDelay = getMinDelay(TIMELOCK);
        console2.log("Current delay:", currentDelay, "seconds");
        console2.log("");

        if (currentDelay == NEW_DELAY) {
            console2.log("Delay is already set to 24 hours!");
            return;
        }

        // Encode the updateDelay call
        bytes memory updateDelayCalldata = abi.encodeCall(ITimelockController.updateDelay, (NEW_DELAY));

        // Create timelock operation - target is the timelock itself
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = TIMELOCK;
        values[0] = 0;
        datas[0] = updateDelayCalldata;

        // Generate salt from description
        bytes32 salt = generateSalt("Extend Timelock Delay to 24 Hours");
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID for reference
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Target:", targets[0]);
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use 07_ExecuteTimelockDelayExtension.s.sol to execute.");
            return;
        }

        // Encode the schedule call
        bytes memory scheduleCalldata = encodeScheduleBatch(
            targets,
            values,
            datas,
            predecessor,
            salt,
            currentDelay // Use current delay as the minimum
        );

        // Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("=== IMPORTANT: Save these values for execution ===");
            console2.log("Operation ID: %s", vm.toString(operationId));
            console2.log("Salt: %s", vm.toString(salt));
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Wait for Safe signers to approve and execute the schedule transaction");
            console2.log("2. Wait %d seconds after scheduling", currentDelay);
            console2.log("3. Run 07_ExecuteTimelockDelayExtension.s.sol");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
            console2.log("Operation ID would be: %s", vm.toString(operationId));
        }
    }

    function run() external {
        this.run(false);
    }
}
