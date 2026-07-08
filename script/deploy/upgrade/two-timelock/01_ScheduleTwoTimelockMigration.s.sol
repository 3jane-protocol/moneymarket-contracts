// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TwoTimelockMigrationBase} from "./TwoTimelockMigrationBase.s.sol";

/// @title ScheduleTwoTimelockMigration
/// @notice Schedule ProxyAdmin ownership transfer to the new 7-day timelock.
contract ScheduleTwoTimelockMigration is Script, SafeHelper, TwoTimelockMigrationBase {
    function run(bool send) external isBatch(MAIN_MULTISIG) isTimelock(EXISTING_24H_TIMELOCK) {
        address sevenDayTimelock = vm.envAddress("SEVEN_DAY_TIMELOCK");
        _validatePreconditions(sevenDayTimelock);

        console2.log("=== Schedule Two-Timelock Migration via 24h Timelock ===");
        console2.log("Safe address:", MAIN_MULTISIG);
        console2.log("Existing 24h timelock:", EXISTING_24H_TIMELOCK);
        console2.log("New 7d timelock:", sevenDayTimelock);
        console2.log("Send to Safe:", send);
        console2.log("");

        _logDiscoveredProxyAdmins();

        uint256 minDelay = getMinDelay(EXISTING_24H_TIMELOCK);
        console2.log("Existing timelock minimum delay:", minDelay, "seconds");
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(sevenDayTimelock);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Target[0] (ProtocolConfig ProxyAdmin.transferOwnership):", targets[0]);
        console2.log("  Target[1] (MorphoCredit ProxyAdmin.transferOwnership):", targets[1]);
        console2.log("  Target[2] (AdaptiveCurveIrm ProxyAdmin.transferOwnership):", targets[2]);
        console2.log("  Target[3] (USD3 ProxyAdmin.transferOwnership):", targets[3]);
        console2.log("  Target[4] (sUSD3 ProxyAdmin.transferOwnership):", targets[4]);
        console2.log("  Target[5] (24h Timelock.revokeRole DEFAULT_ADMIN_ROLE):", targets[5]);
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        if (isOperation(EXISTING_24H_TIMELOCK, operationId)) {
            logOperationState(EXISTING_24H_TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use 02_ExecuteTwoTimelockMigration.s.sol to execute.");
            return;
        }

        simulateExecution(EXISTING_24H_TIMELOCK, targets, values, datas);
        console2.log("");
        console2.log("Validating simulated final state...");
        _validateFinalState(sevenDayTimelock);
        console2.log("PASS: Five ProxyAdmins are owned by the 7d timelock");
        console2.log("PASS: Five ProxyAdmins are no longer owned by the 24h timelock");
        console2.log("PASS: Main multisig does not hold DEFAULT_ADMIN_ROLE on the 24h timelock");
        console2.log("");

        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(EXISTING_24H_TIMELOCK, scheduleCalldata);

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
            console2.log("3. Run 02_ExecuteTwoTimelockMigration.s.sol with SEVEN_DAY_TIMELOCK=%s", sevenDayTimelock);
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
