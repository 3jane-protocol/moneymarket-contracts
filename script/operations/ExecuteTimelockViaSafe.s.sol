// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";

/// @title ExecuteTimelockViaSafe Script
/// @notice Execute a scheduled TimelockController operation via Safe multisig
/// @dev Reconstructs operation data from the operation ID and executes when ready
contract ExecuteTimelockViaSafe is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice Event signatures for parsing
    bytes32 private constant CALL_SCHEDULED_TOPIC =
        keccak256("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)");
    bytes32 private constant CALL_SALT_TOPIC = keccak256("CallSalt(bytes32,bytes32)");

    /// @notice Execute a scheduled operation by fetching data from events
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

        console2.log("Fetching operation data from events...");
        console2.log("");

        // Fetch operation data from events
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 predecessor, bytes32 salt) =
            _fetchOperationData(operationId);

        // Log the fetched data
        console2.log("Operation data fetched successfully:");
        console2.log("  Targets:", targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            console2.log("    Target", i, ":", targets[i]);
            console2.log("    Value", i, ":", values[i]);
        }
        console2.log("  Predecessor:", vm.toString(predecessor));
        console2.log("  Salt:", vm.toString(salt));
        console2.log("");

        // Verify the operation ID matches
        bytes32 calculatedId = calculateBatchOperationId(targets, values, datas, predecessor, salt);
        require(calculatedId == operationId, "Operation ID mismatch after fetching data");

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

    /// @notice Fetch operation data from CallScheduled and CallSalt events
    /// @param operationId The operation ID to search for
    /// @return targets Array of target addresses
    /// @return values Array of ETH values
    /// @return datas Array of calldata
    /// @return predecessor Predecessor dependency
    /// @return salt Salt value
    function _fetchOperationData(bytes32 operationId)
        private
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory datas,
            bytes32 predecessor,
            bytes32 salt
        )
    {
        // Search for CallScheduled events with this operation ID
        // The operation ID is the first indexed topic
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = CALL_SCHEDULED_TOPIC;
        topics[1] = operationId;

        // Get logs from the last 30 days (approximately)
        uint256 fromBlock = block.number > 216000 ? block.number - 216000 : 0;
        Vm.EthGetLogs[] memory scheduledLogs = vm.eth_getLogs(fromBlock, block.number, TIMELOCK, topics);

        require(scheduledLogs.length > 0, "No CallScheduled events found for this operation ID");

        // Count unique indices to determine array sizes
        uint256 maxIndex = 0;
        for (uint256 i = 0; i < scheduledLogs.length; i++) {
            // Index is the second indexed topic
            uint256 index = uint256(scheduledLogs[i].topics[2]);
            if (index > maxIndex) {
                maxIndex = index;
            }
        }

        // Initialize arrays with the correct size
        uint256 arraySize = maxIndex + 1;
        targets = new address[](arraySize);
        values = new uint256[](arraySize);
        datas = new bytes[](arraySize);

        // Parse CallScheduled events
        for (uint256 i = 0; i < scheduledLogs.length; i++) {
            uint256 index = uint256(scheduledLogs[i].topics[2]);

            // Decode the non-indexed parameters from data
            (address target, uint256 value, bytes memory data, bytes32 pred, uint256 delay) =
                abi.decode(scheduledLogs[i].data, (address, uint256, bytes, bytes32, uint256));

            targets[index] = target;
            values[index] = value;
            datas[index] = data;

            // Predecessor should be the same for all events in the batch
            if (i == 0) {
                predecessor = pred;
            } else {
                require(predecessor == pred, "Inconsistent predecessor in batch");
            }
        }

        // Search for CallSalt event
        bytes32[] memory saltTopics = new bytes32[](2);
        saltTopics[0] = CALL_SALT_TOPIC;
        saltTopics[1] = operationId;

        Vm.EthGetLogs[] memory saltLogs = vm.eth_getLogs(fromBlock, block.number, TIMELOCK, saltTopics);

        if (saltLogs.length > 0) {
            // Decode salt from the event data
            salt = abi.decode(saltLogs[0].data, (bytes32));
        } else {
            // If no CallSalt event, salt is likely bytes32(0)
            salt = bytes32(0);
        }

        return (targets, values, datas, predecessor, salt);
    }
}
