// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolConfig} from "../../../../src/ProtocolConfig.sol";

/// @title DeployProtocolConfigImpl
/// @notice Deploy a new ProtocolConfig implementation for the emergency admin upgrade
/// @dev The new implementation includes:
///      - emergencyAdmin state variable
///      - setEmergencyAdmin() function
///      - setEmergencyConfig() function with binary constraints
contract DeployProtocolConfigImpl is Script {
    function run() external returns (address) {
        vm.startBroadcast();

        ProtocolConfig impl = new ProtocolConfig();

        console2.log("=== ProtocolConfig Implementation Deployed ===");
        console2.log("Implementation address:", address(impl));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Run 02_DeployEmergencyController.s.sol");
        console2.log("2. Run 03_QueueProtocolConfigUpgrade.s.sol with PROTOCOL_CONFIG_IMPL=%s", address(impl));

        vm.stopBroadcast();

        return address(impl);
    }
}
