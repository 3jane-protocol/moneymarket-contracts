// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";

interface IProtocolConfigSetEmergencyAdmin {
    function setEmergencyAdmin(address _emergencyAdmin) external;
}

interface ICreditLineSetOzd {
    function setOzd(address newOzd) external;
}

/// @title ExecuteEmergencyControllerUpgrade
/// @notice Execute the scheduled EmergencyController V2 pointer reconfiguration after timelock delay
contract ExecuteEmergencyControllerUpgrade is Script, SafeHelper, TimelockHelper {
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function _buildOperation(address newController)
        internal
        pure
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory datas,
            bytes32 salt,
            bytes32 predecessor
        )
    {
        targets = new address[](2);
        values = new uint256[](2);
        datas = new bytes[](2);

        targets[0] = PROTOCOL_CONFIG;
        values[0] = 0;
        datas[0] = abi.encodeCall(IProtocolConfigSetEmergencyAdmin.setEmergencyAdmin, (newController));

        targets[1] = CREDIT_LINE;
        values[1] = 0;
        datas[1] = abi.encodeCall(ICreditLineSetOzd.setOzd, (newController));

        salt = generateSalt("EmergencyController V2 Upgrade");
        predecessor = bytes32(0);
    }

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        address newController = vm.envAddress("EMERGENCY_CONTROLLER");
        require(newController != address(0), "EMERGENCY_CONTROLLER not set");

        console2.log("=== Execute EmergencyController V2 Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New EmergencyController:", newController);
        console2.log("Send to Safe:", send);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newController);

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

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed:");
            console2.log("  - ProtocolConfig.emergencyAdmin -> %s", newController);
            console2.log("  - CreditLine.ozd -> %s", newController);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check status of the upgrade operation
    function checkStatus() external view {
        address newController = vm.envAddress("EMERGENCY_CONTROLLER");
        require(newController != address(0), "EMERGENCY_CONTROLLER not set");

        console2.log("=== Checking EmergencyController V2 Upgrade Status ===");
        console2.log("New EmergencyController:", newController);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newController);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);
    }

    /// @notice Verify the upgrade was applied correctly
    function verify() external view {
        address newController = vm.envAddress("EMERGENCY_CONTROLLER");
        require(newController != address(0), "EMERGENCY_CONTROLLER not set");

        console2.log("=== Verifying EmergencyController V2 Upgrade ===");
        console2.log("Expected EmergencyController:", newController);
        console2.log("");

        // Check ProtocolConfig.emergencyAdmin
        (bool ok1, bytes memory data1) = PROTOCOL_CONFIG.staticcall(abi.encodeWithSignature("emergencyAdmin()"));
        require(ok1, "Failed to read ProtocolConfig.emergencyAdmin");
        address currentAdmin = abi.decode(data1, (address));
        console2.log("ProtocolConfig.emergencyAdmin:", currentAdmin);

        // Check CreditLine.ozd
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
    }

    function run() external {
        this.run(false);
    }
}
