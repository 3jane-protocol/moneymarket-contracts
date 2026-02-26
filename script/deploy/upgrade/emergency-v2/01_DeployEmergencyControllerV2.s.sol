// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {EmergencyController} from "../../../../src/EmergencyController.sol";
import {
    IAccessControlEnumerable
} from "../../../../lib/openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/// @title DeployEmergencyControllerV2
/// @notice Deploy the EmergencyController v2 (AccessControlEnumerable) with role-based access
contract DeployEmergencyControllerV2 is Script {
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run() external returns (address) {
        // Parse emergency signers from env, default to Safe only
        address[] memory emergencySigners = _getEmergencySigners();

        console2.log("=== Deploying EmergencyController V2 ===");
        console2.log("ProtocolConfig:", PROTOCOL_CONFIG);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Owner (Safe):", SAFE_ADDRESS);
        console2.log("Emergency signers:", emergencySigners.length);
        for (uint256 i = 0; i < emergencySigners.length; i++) {
            console2.log("  [%d]:", i, emergencySigners[i]);
        }
        console2.log("");

        vm.startBroadcast();

        EmergencyController ec = new EmergencyController(PROTOCOL_CONFIG, CREDIT_LINE, SAFE_ADDRESS, emergencySigners);

        vm.stopBroadcast();

        console2.log("=== EmergencyController V2 Deployed ===");
        console2.log("Address:", address(ec));
        console2.log("");
        console2.log("Verify configuration:");
        console2.log("  protocolConfig:", address(ec.protocolConfig()));
        console2.log("  creditLine:", address(ec.creditLine()));
        console2.log("  owner:", ec.owner());
        uint256 memberCount = IAccessControlEnumerable(address(ec)).getRoleMemberCount(ec.EMERGENCY_AUTHORIZED_ROLE());
        console2.log("  EMERGENCY_AUTHORIZED_ROLE members:", memberCount);
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Run 02_ScheduleEmergencyControllerUpgrade.s.sol with EMERGENCY_CONTROLLER=%s", address(ec));
        console2.log("2. Wait for Safe signers to approve the schedule transaction");
        console2.log("3. Wait for timelock delay, then run 03_ExecuteEmergencyControllerUpgrade.s.sol");

        return address(ec);
    }

    function _getEmergencySigners() internal view returns (address[] memory signers) {
        string memory raw = vm.envOr("EMERGENCY_SIGNERS", string(""));
        if (bytes(raw).length == 0) {
            signers = new address[](1);
            signers[0] = SAFE_ADDRESS;
            return signers;
        }

        string[] memory parts = vm.split(raw, ",");
        signers = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            signers[i] = vm.parseAddress(parts[i]);
        }
    }
}
