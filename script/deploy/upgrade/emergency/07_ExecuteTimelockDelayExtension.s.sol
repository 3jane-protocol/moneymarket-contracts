// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";

/// @title ExecuteTimelockDelayExtension
/// @notice Execute the queued timelock delay extension after the delay period
/// @dev This script:
///      1. Reconstructs the operation data
///      2. Verifies operation is ready
///      3. Executes via Safe multisig
contract ExecuteTimelockDelayExtension is Script, SafeHelper, TimelockHelper {
    // Mainnet addresses
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    // New delay: 24 hours in seconds
    uint256 constant NEW_DELAY = 86400;

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        console2.log("=== Execute Timelock Delay Extension ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New delay:", NEW_DELAY, "seconds (24 hours)");
        console2.log("Send to Safe:", send);
        console2.log("");

        // Reconstruct the updateDelay call
        bytes memory updateDelayCalldata = abi.encodeCall(ITimelockController.updateDelay, (NEW_DELAY));

        // Create timelock operation arrays
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = TIMELOCK;
        values[0] = 0;
        datas[0] = updateDelayCalldata;

        // Use same salt as queue script
        bytes32 salt = generateSalt("Extend Timelock Delay to 24 Hours");
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        // Check operation state
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Verify operation is ready
        requireOperationReady(TIMELOCK, operationId);

        // Encode the execute call
        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        // Add to Safe batch
        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(TIMELOCK, executeCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed:");
            console2.log("  - Timelock delay will be extended to 24 hours");
            console2.log("  - All future timelock operations will require 24-hour wait");
            console2.log("");
            console2.log("Next step:");
            console2.log("  Run 08_TransferOwnershipsToTimelock.s.sol");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check status of the delay extension operation
    function checkStatus() external view {
        console2.log("=== Checking Timelock Delay Extension Status ===");
        console2.log("");

        // Reconstruct operation ID
        bytes memory updateDelayCalldata = abi.encodeCall(ITimelockController.updateDelay, (NEW_DELAY));

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = TIMELOCK;
        values[0] = 0;
        datas[0] = updateDelayCalldata;

        bytes32 salt = generateSalt("Extend Timelock Delay to 24 Hours");
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);

        // Also show current delay
        uint256 currentDelay = getMinDelay(TIMELOCK);
        console2.log("");
        console2.log("Current timelock delay:", currentDelay, "seconds");
    }

    function run() external {
        this.run(false);
    }
}
