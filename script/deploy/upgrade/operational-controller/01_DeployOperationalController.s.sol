// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {
    IAccessControlEnumerable
} from "../../../../lib/openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {OperationalController} from "../../../../src/OperationalController.sol";

/// @title DeployOperationalController
/// @notice Deploy the OperationalController with separate emergency and operator roles.
contract DeployOperationalController is Script {
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run() external returns (address) {
        address[] memory emergencySigners = _getEmergencySigners();
        address[] memory operators = _getOperators();

        console2.log("=== Deploying OperationalController ===");
        console2.log("ProtocolConfig:", PROTOCOL_CONFIG);
        console2.log("CreditLine:", CREDIT_LINE);
        console2.log("Owner (Safe):", SAFE_ADDRESS);
        _logAddresses("Emergency signers", emergencySigners);
        _logAddresses("Operators", operators);
        console2.log("");

        vm.startBroadcast();

        OperationalController controller =
            new OperationalController(PROTOCOL_CONFIG, CREDIT_LINE, SAFE_ADDRESS, emergencySigners, operators);

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
        console2.log("2. Wait for Safe signers to approve the schedule transaction");
        console2.log("3. Wait for timelock delay, then run 03_ExecuteOperationalControllerUpgrade.s.sol");

        return address(controller);
    }

    function _getEmergencySigners() internal view returns (address[] memory signers) {
        string memory raw = vm.envOr("EMERGENCY_SIGNERS", string(""));
        if (bytes(raw).length == 0) {
            signers = new address[](1);
            signers[0] = SAFE_ADDRESS;
            return signers;
        }

        return _parseAddressList(raw);
    }

    function _getOperators() internal view returns (address[] memory operators) {
        string memory raw = vm.envString("OPERATORS");
        require(bytes(raw).length > 0, "OPERATORS not set");
        operators = _parseAddressList(raw);
        require(operators.length > 0, "OPERATORS empty");
    }

    function _parseAddressList(string memory raw) internal pure returns (address[] memory addrs) {
        string[] memory parts = vm.split(raw, ",");
        addrs = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            addrs[i] = vm.parseAddress(parts[i]);
            require(addrs[i] != address(0), "zero address in list");
        }
    }

    function _logAddresses(string memory label, address[] memory addrs) internal pure {
        console2.log("%s:", label, addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            console2.log("  [%d]:", i, addrs[i]);
        }
    }
}
