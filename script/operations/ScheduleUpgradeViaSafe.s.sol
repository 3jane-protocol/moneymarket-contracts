// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title ScheduleUpgradeViaSafe Script
/// @notice Schedule a contract upgrade through TimelockController via Safe multisig
/// @dev Uses both SafeHelper and TimelockHelper for Safe + Timelock workflow
contract ScheduleUpgradeViaSafe is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice Example addresses - replace with actual values
    address private constant PROXY_ADMIN = address(0); // Set actual ProxyAdmin address
    address private constant PROXY_CONTRACT = address(0); // Set actual proxy to upgrade

    /// @notice Main execution function
    /// @param newImplementation Address of the new implementation contract
    /// @param description Description of the upgrade (used for salt generation)
    /// @param delay Delay in seconds before the operation can be executed
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(address newImplementation, string memory description, uint256 delay, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        console2.log("=== Scheduling Contract Upgrade via Safe + Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("ProxyAdmin address:", PROXY_ADMIN);
        console2.log("Proxy to upgrade:", PROXY_CONTRACT);
        console2.log("New implementation:", newImplementation);
        console2.log("Description:", description);
        console2.log("Delay (seconds):", delay);
        console2.log("Delay (hours):", delay / 3600);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Validate inputs
        require(PROXY_ADMIN != address(0), "ProxyAdmin address not set");
        require(PROXY_CONTRACT != address(0), "Proxy contract address not set");
        require(newImplementation != address(0), "New implementation cannot be zero address");
        require(delay >= getMinDelay(TIMELOCK), "Delay less than minimum");

        // Step 1: Prepare the upgrade operation
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        // The actual upgrade call that will be executed after timelock
        targets[0] = PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(PROXY_CONTRACT), newImplementation, "")
        );

        // Generate salt from description
        bytes32 salt = generateSalt(description);
        bytes32 predecessor = bytes32(0); // No predecessor

        // Calculate operation ID for tracking
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Target:", targets[0]);
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            ITimelockController.OperationState state = getOperationState(TIMELOCK, operationId);
            console2.log("[WARNING] Operation already exists!");
            logOperationState(TIMELOCK, operationId);
            revert("Operation already scheduled");
        }

        // Step 2: Encode the scheduleBatch call for TimelockController
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, delay);

        // Step 3: Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        // Step 4: Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }

        // Step 5: Log important information for execution
        console2.log("");
        console2.log("=== IMPORTANT: Save this information for execution ===");
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Ready for execution at:", block.timestamp + delay);
        console2.log("To execute, run ExecuteTimelockViaSafe with this operation ID");
        console2.log("");
        console2.log("Execution command:");
        console2.log("  yarn script:forge ExecuteTimelockViaSafe --sig \"run(bytes32,bool)\" <operationId> false");
        console2.log("  Operation ID:", vm.toString(operationId));
    }

    /// @notice Alternative entry point with example values
    function runExample() external {
        // Example values - replace with actual
        address newImpl = address(0x1234567890123456789012345678901234567890);
        string memory desc = "Upgrade to v2.0.0";
        uint256 delayTime = 2 days;

        this.run(newImpl, desc, delayTime, false);
    }
}
