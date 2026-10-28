// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {OperationalControllerUpgradeBase} from "./OperationalControllerUpgradeBase.s.sol";

/// @title ExecuteOperationalControllerUpgrade
/// @notice Execute the scheduled OperationalController pointer reconfiguration after timelock delay.
contract ExecuteOperationalControllerUpgrade is Script, SafeHelper, OperationalControllerUpgradeBase {
    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        address newController = vm.envAddress("OPERATIONAL_CONTROLLER");
        address operationalTimelock = vm.envAddress("OPERATIONAL_TIMELOCK");
        _validateNewController(newController, operationalTimelock);
        _validateSlowTimelockAdminPreconditions();

        console2.log("=== Execute OperationalController Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New OperationalController:", newController);
        console2.log("Operational timelock:", operationalTimelock);
        console2.log("Send to Safe:", send);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newController, operationalTimelock);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);
        console2.log("");

        requireOperationReady(TIMELOCK, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(TIMELOCK, executeCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed:");
            console2.log("  - ProtocolConfig.emergencyAdmin -> %s", newController);
            console2.log("  - CreditLine.ozd -> %s", newController);
            console2.log("  - Operational timelock self DEFAULT_ADMIN_ROLE revoked");
            console2.log("  - Main multisig slow timelock DEFAULT_ADMIN_ROLE revoked");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check status of the upgrade operation.
    function checkStatus() external view {
        address newController = vm.envAddress("OPERATIONAL_CONTROLLER");
        address operationalTimelock = vm.envAddress("OPERATIONAL_TIMELOCK");
        _validateNewController(newController, operationalTimelock);

        console2.log("=== Checking OperationalController Upgrade Status ===");
        console2.log("New OperationalController:", newController);
        console2.log("Operational timelock:", operationalTimelock);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newController, operationalTimelock);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);
    }

    /// @notice Verify the upgrade was applied correctly.
    function verify() external view {
        address newController = vm.envAddress("OPERATIONAL_CONTROLLER");
        address operationalTimelock = vm.envAddress("OPERATIONAL_TIMELOCK");
        _validateNewController(newController, operationalTimelock);

        console2.log("=== Verifying OperationalController Upgrade ===");
        console2.log("Expected OperationalController:", newController);
        console2.log("Expected operational timelock:", operationalTimelock);
        console2.log("");

        (bool ok1, bytes memory data1) = PROTOCOL_CONFIG.staticcall(abi.encodeWithSignature("emergencyAdmin()"));
        require(ok1, "Failed to read ProtocolConfig.emergencyAdmin");
        address currentAdmin = abi.decode(data1, (address));
        console2.log("ProtocolConfig.emergencyAdmin:", currentAdmin);

        (bool ok2, bytes memory data2) = CREDIT_LINE.staticcall(abi.encodeWithSignature("ozd()"));
        require(ok2, "Failed to read CreditLine.ozd");
        address currentOzd = abi.decode(data2, (address));
        console2.log("CreditLine.ozd:", currentOzd);

        console2.log("");
        if (currentAdmin == newController && currentOzd == newController) {
            console2.log("PASS: Both pointers updated correctly");
        } else {
            if (currentAdmin != newController) {
                console2.log("FAIL: ProtocolConfig.emergencyAdmin mismatch");
            }
            if (currentOzd != newController) {
                console2.log("FAIL: CreditLine.ozd mismatch");
            }
        }

        _validateOperationalTimelockAdminFinalized(operationalTimelock);
        console2.log("PASS: Operational timelock admin finalized");
        _validateSlowTimelockAdminFinalized();
        console2.log("PASS: Slow timelock admin finalized");
    }

    function run() external {
        this.run(false);
    }
}
