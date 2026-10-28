// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {
    IAccessControlEnumerable
} from "../../../../lib/openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {OperationalController} from "../../../../src/OperationalController.sol";

interface IProtocolConfigEmergencyAdmin {
    function emergencyAdmin() external view returns (address);
}

interface IRoleConstants {
    function OWNER_ROLE() external view returns (bytes32);
    function EMERGENCY_AUTHORIZED_ROLE() external view returns (bytes32);
}

/// @title DeployOperationalController
/// @notice Deploy the OperationalController with separate emergency and operator roles.
contract DeployOperationalController is Script {
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant SLOW_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    bytes32 constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 constant EMERGENCY_AUTHORIZED_ROLE = keccak256("EMERGENCY_AUTHORIZED_ROLE");

    function run() external returns (address) {
        address operationalTimelock = vm.envAddress("OPERATIONAL_TIMELOCK");
        require(operationalTimelock != address(0), "OPERATIONAL_TIMELOCK not set");
        require(operationalTimelock.code.length > 0, "OPERATIONAL_TIMELOCK has no code");

        address currentEmergencyController = IProtocolConfigEmergencyAdmin(PROTOCOL_CONFIG).emergencyAdmin();
        require(currentEmergencyController != address(0), "ProtocolConfig.emergencyAdmin not set");
        require(currentEmergencyController.code.length > 0, "emergencyAdmin has no code");
        _validateRoleConstants(currentEmergencyController);

        IAccessControlEnumerable currentEnumerable = IAccessControlEnumerable(currentEmergencyController);
        address[] memory emergencySigners = _copyRoleMembers(currentEnumerable, EMERGENCY_AUTHORIZED_ROLE);
        address[] memory operators = new address[](1);
        operators[0] = operationalTimelock;

        console2.log("=== Deploying OperationalController ===");
        console2.log("ProtocolConfig:", PROTOCOL_CONFIG);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Current emergency controller:", currentEmergencyController);
        console2.log("Owner (slow timelock):", SLOW_TIMELOCK);
        _logAddresses("Copied emergency members", emergencySigners);
        _logAddresses("Operators", operators);
        console2.log("");

        vm.startBroadcast();

        OperationalController controller = new OperationalController{salt: "3jane"}(
            PROTOCOL_CONFIG, CREDIT_LINE, SLOW_TIMELOCK, emergencySigners, operators
        );

        vm.stopBroadcast();

        console2.log("=== OperationalController Deployed ===");
        console2.log("Address:", address(controller));
        console2.log("");
        console2.log("Verify configuration:");
        console2.log("  protocolConfig:", address(controller.protocolConfig()));
        console2.log("  creditLine:", address(controller.creditLine()));
        console2.log("  owner:", controller.owner());

        IAccessControlEnumerable enumerable = IAccessControlEnumerable(address(controller));
        uint256 emergencyCount = enumerable.getRoleMemberCount(controller.EMERGENCY_AUTHORIZED_ROLE());
        uint256 operatorCount = enumerable.getRoleMemberCount(controller.OPERATOR_ROLE());
        console2.log("  EMERGENCY_AUTHORIZED_ROLE members:", emergencyCount);
        console2.log("  OPERATOR_ROLE members:", operatorCount);
        console2.log("");
        console2.log("Next steps:");
        console2.log(
            "1. Run 02_ScheduleOperationalControllerUpgrade.s.sol with OPERATIONAL_CONTROLLER=%s", address(controller)
        );
        console2.log("   and OPERATIONAL_TIMELOCK=%s", operationalTimelock);
        console2.log("2. Wait for Safe signers to approve the schedule transaction");
        console2.log("3. Wait for timelock delay, then run 03_ExecuteOperationalControllerUpgrade.s.sol");

        return address(controller);
    }

    function _validateRoleConstants(address controller) internal view {
        IRoleConstants roles = IRoleConstants(controller);
        require(roles.OWNER_ROLE() == OWNER_ROLE, "current OWNER_ROLE mismatch");
        require(
            roles.EMERGENCY_AUTHORIZED_ROLE() == EMERGENCY_AUTHORIZED_ROLE, "current EMERGENCY_AUTHORIZED_ROLE mismatch"
        );
    }

    function _copyRoleMembers(IAccessControlEnumerable enumerable, bytes32 role)
        internal
        view
        returns (address[] memory members)
    {
        uint256 count = enumerable.getRoleMemberCount(role);
        members = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            members[i] = enumerable.getRoleMember(role, i);
            require(members[i] != address(0), "zero address role member");
        }
    }

    function _logAddresses(string memory label, address[] memory addrs) internal pure {
        console2.log("%s (count=%d):", label, addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            console2.log("  [%d]:", i, addrs[i]);
        }
    }
}
