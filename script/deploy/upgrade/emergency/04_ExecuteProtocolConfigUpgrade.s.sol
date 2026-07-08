// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";

interface IProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
}

/// @title ExecuteProtocolConfigUpgrade
/// @notice Execute the queued ProtocolConfig proxy upgrade after timelock delay
/// @dev This script:
///      1. Reconstructs the operation data
///      2. Verifies operation is ready
///      3. Executes via Safe multisig
contract ExecuteProtocolConfigUpgrade is Script, SafeHelper, TimelockHelper {
    // Mainnet addresses
    address constant PROTOCOL_CONFIG_PROXY = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant PROTOCOL_CONFIG_PROXY_ADMIN = 0x2C4A7eb2e31BaaF4A98a38dC590321FdB9eFDbA8;
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        // Get implementation address and operation ID from environment
        address newImpl = vm.envAddress("PROTOCOL_CONFIG_IMPL");
        require(newImpl != address(0), "PROTOCOL_CONFIG_IMPL not set");

        console2.log("=== Execute ProtocolConfig Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New Implementation:", newImpl);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Reconstruct the upgrade call
        bytes memory upgradeCalldata = abi.encodeCall(IProxyAdmin.upgradeAndCall, (PROTOCOL_CONFIG_PROXY, newImpl, ""));

        // Create timelock operation arrays
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = PROTOCOL_CONFIG_PROXY_ADMIN;
        values[0] = 0;
        datas[0] = upgradeCalldata;

        // Use same salt as queue script
        bytes32 salt = generateSalt("ProtocolConfig Emergency Admin Upgrade");
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
            console2.log("  - ProtocolConfig will be upgraded to new implementation");
            console2.log("  - emergencyAdmin and setEmergencyConfig will be available");
            console2.log("");
            console2.log("Next step:");
            console2.log("  Run 05_ConfigureEmergencyController.s.sol");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check status of the upgrade operation
    function checkStatus() external view {
        address newImpl = vm.envAddress("PROTOCOL_CONFIG_IMPL");
        require(newImpl != address(0), "PROTOCOL_CONFIG_IMPL not set");

        console2.log("=== Checking ProtocolConfig Upgrade Status ===");
        console2.log("New Implementation:", newImpl);
        console2.log("");

        // Reconstruct operation ID
        bytes memory upgradeCalldata = abi.encodeCall(IProxyAdmin.upgradeAndCall, (PROTOCOL_CONFIG_PROXY, newImpl, ""));

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = PROTOCOL_CONFIG_PROXY_ADMIN;
        values[0] = 0;
        datas[0] = upgradeCalldata;

        bytes32 salt = generateSalt("ProtocolConfig Emergency Admin Upgrade");
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);
    }

    function run() external {
        this.run(false);
    }
}
