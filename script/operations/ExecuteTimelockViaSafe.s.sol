// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";

/// @title ExecuteTimelockViaSafe Script
/// @notice Execute a scheduled TimelockController operation via Safe multisig
/// @dev Reconstructs operation data from the operation ID and executes when ready
contract ExecuteTimelockViaSafe is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice Storage for operation data (would typically be stored off-chain)
    mapping(bytes32 => TimelockOperation) private operations;

    /// @notice Execute a scheduled operation
    /// @param operationId The ID of the operation to execute
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(bytes32 operationId, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        console2.log("=== Executing Timelock Operation via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Check operation state
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Ensure operation is ready
        requireOperationReady(TIMELOCK, operationId);

        // For this example, we need to reconstruct the operation data
        // In practice, this would be stored off-chain or passed as parameters
        console2.log("[INFO] Operation is ready for execution");
        console2.log("[INFO] You need to provide the original operation data");
        console2.log("");

        // Note: In a real scenario, you would either:
        // 1. Store operation data in a mapping when scheduling
        // 2. Pass all operation data as parameters
        // 3. Retrieve from an off-chain storage system

        revert("Please use runWithData() and provide the operation data");
    }

    /// @notice Execute operation with provided data
    /// @param operationId The ID of the operation to execute
    /// @param targets Array of target addresses
    /// @param values Array of ETH values
    /// @param datas Array of calldata
    /// @param salt Salt used when scheduling
    /// @param send Whether to send transaction to Safe API
    function runWithData(
        bytes32 operationId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory datas,
        bytes32 salt,
        bool send
    ) external isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) isTimelock(TIMELOCK) {
        console2.log("=== Executing Timelock Operation via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Targets:", targets.length);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Verify operation ID matches
        bytes32 predecessor = bytes32(0); // Assuming no predecessor
        bytes32 calculatedId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        require(calculatedId == operationId, "Operation ID mismatch");

        // Check operation state
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Ensure operation is ready
        requireOperationReady(TIMELOCK, operationId);

        // Encode the executeBatch call
        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        // Add to Safe batch
        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(TIMELOCK, executeCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed, the operation will be marked as Done");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Cancel a scheduled operation
    /// @param operationId The ID of the operation to cancel
    /// @param send Whether to send transaction to Safe API
    function cancel(bytes32 operationId, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        console2.log("=== Cancelling Timelock Operation via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Check operation state
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Ensure operation is pending
        require(isOperationPending(TIMELOCK, operationId), "Operation not pending");

        // Encode the cancel call
        bytes memory cancelCalldata = encodeCancel(operationId);

        // Add to Safe batch
        console2.log("Adding cancel call to Safe transaction...");
        addToBatch(TIMELOCK, cancelCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("Operation will be cancelled once executed");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check the status of an operation
    /// @param operationId The ID of the operation to check
    function checkStatus(bytes32 operationId) external view {
        console2.log("=== Checking Timelock Operation Status ===");
        console2.log("Timelock address:", TIMELOCK);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        if (!isOperation(TIMELOCK, operationId)) {
            console2.log("Operation does not exist");
            return;
        }

        logOperationState(TIMELOCK, operationId);

        ITimelockController.OperationState state = getOperationState(TIMELOCK, operationId);

        if (state == ITimelockController.OperationState.Ready) {
            console2.log("");
            console2.log("Operation is ready for execution!");
            console2.log("Run this script with the operation data to execute");
        } else if (state == ITimelockController.OperationState.Waiting) {
            uint256 timestamp = getOperationTimestamp(TIMELOCK, operationId);
            uint256 remaining = timestamp - block.timestamp;
            console2.log("");
            console2.log("Operation is waiting");
            console2.log("Time remaining (seconds):", remaining);
            console2.log("  Hours:", remaining / 3600);
            console2.log("  Minutes:", (remaining % 3600) / 60);
        }
    }
}
