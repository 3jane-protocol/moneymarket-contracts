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

/// @title ScheduleEmergencyControllerUpgrade
/// @notice Schedule pointer reconfiguration for EmergencyController V2 through Timelock via Safe
/// @dev Updates both ProtocolConfig.emergencyAdmin and CreditLine.ozd to the new controller
contract ScheduleEmergencyControllerUpgrade is Script, SafeHelper, TimelockHelper {
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

        // Call 1: ProtocolConfig.setEmergencyAdmin(newController)
        targets[0] = PROTOCOL_CONFIG;
        values[0] = 0;
        datas[0] = abi.encodeCall(IProtocolConfigSetEmergencyAdmin.setEmergencyAdmin, (newController));

        // Call 2: CreditLine.setOzd(newController)
        targets[1] = CREDIT_LINE;
        values[1] = 0;
        datas[1] = abi.encodeCall(ICreditLineSetOzd.setOzd, (newController));

        salt = generateSalt("EmergencyController V2 Upgrade");
        predecessor = bytes32(0);
    }

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        address newController = vm.envAddress("EMERGENCY_CONTROLLER");
        require(newController != address(0), "EMERGENCY_CONTROLLER not set");

        console2.log("=== Schedule EmergencyController V2 Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("New EmergencyController:", newController);
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

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use 03_ExecuteEmergencyControllerUpgrade.s.sol to execute.");
            return;
        }

        // Simulate execution to verify calls will succeed
        simulateExecution(TIMELOCK, targets, values, datas);
        console2.log("");

        // Encode the schedule call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        // Add to Safe batch
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
            console2.log("3. Run 03_ExecuteEmergencyControllerUpgrade.s.sol with:");
            console2.log("   EMERGENCY_CONTROLLER=%s", newController);
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
