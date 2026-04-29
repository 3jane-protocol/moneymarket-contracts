// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {OperationalControllerUpgradeBase} from "./OperationalControllerUpgradeBase.s.sol";

/// @title ScheduleOperationalControllerUpgrade
/// @notice Schedule pointer reconfiguration for OperationalController through Timelock via Safe.
contract ScheduleOperationalControllerUpgrade is Script, SafeHelper, OperationalControllerUpgradeBase {
    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        address newController = vm.envAddress("OPERATIONAL_CONTROLLER");
        require(newController != address(0), "OPERATIONAL_CONTROLLER not set");

        console2.log("=== Schedule OperationalController Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New OperationalController:", newController);
        console2.log("Send to Safe:", send);
        console2.log("");

        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("Timelock minimum delay:", minDelay, "seconds");
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newController);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Target[0] (ProtocolConfig.setEmergencyAdmin):", targets[0]);
        console2.log("  Target[1] (CreditLine.setOzd):", targets[1]);
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use 03_ExecuteOperationalControllerUpgrade.s.sol to execute.");
            return;
        }

        simulateExecution(TIMELOCK, targets, values, datas);
        console2.log("");

        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

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
            console2.log("3. Run 03_ExecuteOperationalControllerUpgrade.s.sol with:");
            console2.log("   OPERATIONAL_CONTROLLER=%s", newController);
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
