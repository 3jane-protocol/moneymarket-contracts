// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";

interface IProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
}

/// @title QueueProtocolConfigUpgrade
/// @notice Queue the ProtocolConfig proxy upgrade through the Timelock
/// @dev This script:
///      1. Encodes ProxyAdmin.upgradeAndCall(proxy, newImpl, "")
///      2. Wraps in Timelock.schedule() with minimum delay
///      3. Submits to Safe for proposer signatures
contract QueueProtocolConfigUpgrade is Script, SafeHelper, TimelockHelper {
    // Mainnet addresses
    address constant PROTOCOL_CONFIG_PROXY = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant PROTOCOL_CONFIG_PROXY_ADMIN = 0x2C4A7eb2e31BaaF4A98a38dC590321FdB9eFDbA8;
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        // Get new implementation address from environment
        address newImpl = vm.envAddress("PROTOCOL_CONFIG_IMPL");
        require(newImpl != address(0), "PROTOCOL_CONFIG_IMPL not set");

        console2.log("=== Queue ProtocolConfig Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("ProxyAdmin address:", PROTOCOL_CONFIG_PROXY_ADMIN);
        console2.log("ProtocolConfig Proxy:", PROTOCOL_CONFIG_PROXY);
        console2.log("New Implementation:", newImpl);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Get minimum delay from timelock
        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("Timelock minimum delay:", minDelay, "seconds");
        console2.log("");

        // Encode the upgrade call: ProxyAdmin.upgradeAndCall(proxy, newImpl, "")
        bytes memory upgradeCalldata = abi.encodeCall(IProxyAdmin.upgradeAndCall, (PROTOCOL_CONFIG_PROXY, newImpl, ""));

        // Create timelock operation
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = PROTOCOL_CONFIG_PROXY_ADMIN;
        values[0] = 0;
        datas[0] = upgradeCalldata;

        // Generate salt from description
        bytes32 salt = generateSalt("ProtocolConfig Emergency Admin Upgrade");
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
            console2.log("Operation already exists. Use 04_ExecuteProtocolConfigUpgrade.s.sol to execute.");
            return;
        }

        // Encode the schedule call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

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
            console2.log("2. Wait %d seconds after scheduling", minDelay);
            console2.log("3. Run 04_ExecuteProtocolConfigUpgrade.s.sol with:");
            console2.log("   PROTOCOL_CONFIG_IMPL=%s OPERATION_ID=%s", newImpl, vm.toString(operationId));
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
