// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";
import {
    IAccessControlEnumerable
} from "../../../../lib/openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

interface IOperationalControllerView {
    function OWNER_ROLE() external view returns (bytes32);
    function EMERGENCY_AUTHORIZED_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function protocolConfig() external view returns (address);
    function creditLine() external view returns (address);
}

interface IProtocolConfigSetEmergencyAdmin {
    function setEmergencyAdmin(address _emergencyAdmin) external;
}

interface IProtocolConfigEmergencyAdmin {
    function emergencyAdmin() external view returns (address);
}

interface ICreditLineSetOzd {
    function setOzd(address newOzd) external;
}

/// @notice Shared constants and calldata construction for OperationalController upgrade scripts.
abstract contract OperationalControllerUpgradeBase is TimelockHelper {
    address constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address constant FAST_SAFE = 0x4444444444Da32a2D5eEc7f56d4889ce79B2bb96;
    address constant DEPLOYER_EOA = 0x1226858E04b9d077258F153275613734421cD06B;

    bytes32 constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 constant EMERGENCY_AUTHORIZED_ROLE = keccak256("EMERGENCY_AUTHORIZED_ROLE");
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 constant OPERATIONAL_TIMELOCK_DELAY = 24 hours;

    function _buildOperation(address newController, address operationalTimelock)
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
        targets = new address[](4);
        values = new uint256[](4);
        datas = new bytes[](4);

        targets[0] = PROTOCOL_CONFIG;
        values[0] = 0;
        datas[0] = abi.encodeCall(IProtocolConfigSetEmergencyAdmin.setEmergencyAdmin, (newController));

        targets[1] = CREDIT_LINE;
        values[1] = 0;
        datas[1] = abi.encodeCall(ICreditLineSetOzd.setOzd, (newController));

        targets[2] = operationalTimelock;
        values[2] = 0;
        datas[2] = abi.encodeCall(ITimelockController.revokeRole, (bytes32(0), operationalTimelock));

        targets[3] = TIMELOCK;
        values[3] = 0;
        datas[3] = abi.encodeCall(ITimelockController.revokeRole, (bytes32(0), SAFE_ADDRESS));

        salt = generateSalt("OperationalController Upgrade");
        predecessor = bytes32(0);
    }

    function _validateNewController(address newController, address operationalTimelock) internal view {
        require(newController != address(0), "OPERATIONAL_CONTROLLER not set");
        require(newController.code.length > 0, "OPERATIONAL_CONTROLLER has no code");
        require(operationalTimelock != address(0), "OPERATIONAL_TIMELOCK not set");
        require(operationalTimelock.code.length > 0, "OPERATIONAL_TIMELOCK has no code");

        IOperationalControllerView controller = IOperationalControllerView(newController);
        require(controller.protocolConfig() == PROTOCOL_CONFIG, "controller protocolConfig mismatch");
        require(controller.creditLine() == CREDIT_LINE, "controller creditLine mismatch");
        require(controller.OWNER_ROLE() == OWNER_ROLE, "controller OWNER_ROLE mismatch");
        require(
            controller.EMERGENCY_AUTHORIZED_ROLE() == EMERGENCY_AUTHORIZED_ROLE,
            "controller EMERGENCY_AUTHORIZED_ROLE mismatch"
        );
        require(controller.OPERATOR_ROLE() == OPERATOR_ROLE, "controller OPERATOR_ROLE mismatch");

        IAccessControlEnumerable controllerEnumerable = IAccessControlEnumerable(newController);
        address currentEmergencyController = IProtocolConfigEmergencyAdmin(PROTOCOL_CONFIG).emergencyAdmin();
        require(currentEmergencyController != address(0), "ProtocolConfig.emergencyAdmin not set");
        require(currentEmergencyController.code.length > 0, "emergencyAdmin has no code");
        IOperationalControllerView currentController = IOperationalControllerView(currentEmergencyController);
        require(currentController.OWNER_ROLE() == OWNER_ROLE, "current OWNER_ROLE mismatch");
        require(
            currentController.EMERGENCY_AUTHORIZED_ROLE() == EMERGENCY_AUTHORIZED_ROLE,
            "current EMERGENCY_AUTHORIZED_ROLE mismatch"
        );

        IAccessControlEnumerable currentEnumerable = IAccessControlEnumerable(currentEmergencyController);
        _validateOwnerIsSlowTimelock(controllerEnumerable);
        _validateCopiedEmergencyMembers(currentEnumerable, controllerEnumerable);
        _validateSingleOperator(controllerEnumerable, operationalTimelock);
        _validateOperationalTimelock(operationalTimelock);
    }

    function _validateOwnerIsSlowTimelock(IAccessControlEnumerable controllerEnumerable) internal view {
        uint256 newOwnerCount = controllerEnumerable.getRoleMemberCount(OWNER_ROLE);
        require(newOwnerCount == 1, "new OWNER_ROLE count must be 1");
        require(controllerEnumerable.getRoleMember(OWNER_ROLE, 0) == TIMELOCK, "OWNER_ROLE must be slow timelock");
    }

    function _validateCopiedEmergencyMembers(
        IAccessControlEnumerable currentEnumerable,
        IAccessControlEnumerable controllerEnumerable
    ) internal view {
        uint256 currentCount = currentEnumerable.getRoleMemberCount(EMERGENCY_AUTHORIZED_ROLE);
        uint256 newCount = controllerEnumerable.getRoleMemberCount(EMERGENCY_AUTHORIZED_ROLE);
        require(currentCount == newCount, "EMERGENCY_AUTHORIZED_ROLE count mismatch");

        for (uint256 i = 0; i < currentCount; i++) {
            address member = currentEnumerable.getRoleMember(EMERGENCY_AUTHORIZED_ROLE, i);
            require(
                _hasRoleMember(controllerEnumerable, EMERGENCY_AUTHORIZED_ROLE, member),
                "missing EMERGENCY_AUTHORIZED_ROLE member"
            );
        }
    }

    function _validateSingleOperator(IAccessControlEnumerable controllerEnumerable, address operationalTimelock)
        internal
        view
    {
        uint256 operatorCount = controllerEnumerable.getRoleMemberCount(OPERATOR_ROLE);
        require(operatorCount == 1, "OPERATOR_ROLE count must be 1");
        require(controllerEnumerable.getRoleMember(OPERATOR_ROLE, 0) == operationalTimelock, "OPERATOR_ROLE mismatch");
    }

    function _validateOperationalTimelock(address operationalTimelock) internal view {
        ITimelockController timelock = ITimelockController(operationalTimelock);
        bytes32 defaultAdminRole = timelock.DEFAULT_ADMIN_ROLE();
        require(defaultAdminRole == bytes32(0), "timelock DEFAULT_ADMIN_ROLE mismatch");
        require(timelock.getMinDelay() == OPERATIONAL_TIMELOCK_DELAY, "operational timelock delay mismatch");
        require(timelock.hasRole(defaultAdminRole, TIMELOCK), "slow timelock missing admin role");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), FAST_SAFE), "fast safe missing proposer role");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), FAST_SAFE), "fast safe missing canceller role");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), FAST_SAFE), "fast safe missing executor role");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEPLOYER_EOA), "deployer EOA missing executor role");
    }

    function _validateOperationalTimelockAdminFinalized(address operationalTimelock) internal view {
        ITimelockController timelock = ITimelockController(operationalTimelock);
        bytes32 defaultAdminRole = timelock.DEFAULT_ADMIN_ROLE();
        require(timelock.hasRole(defaultAdminRole, TIMELOCK), "slow timelock missing admin role");
        require(!timelock.hasRole(defaultAdminRole, operationalTimelock), "operational timelock still self-admin");
    }

    function _validateSlowTimelockAdminPreconditions() internal view {
        ITimelockController slowTimelock = ITimelockController(TIMELOCK);
        bytes32 defaultAdminRole = slowTimelock.DEFAULT_ADMIN_ROLE();
        require(defaultAdminRole == bytes32(0), "slow timelock DEFAULT_ADMIN_ROLE mismatch");
        require(slowTimelock.hasRole(defaultAdminRole, TIMELOCK), "slow timelock missing self admin role");
        require(slowTimelock.hasRole(defaultAdminRole, SAFE_ADDRESS), "main multisig missing slow timelock admin role");
    }

    function _validateSlowTimelockAdminFinalized() internal view {
        ITimelockController slowTimelock = ITimelockController(TIMELOCK);
        bytes32 defaultAdminRole = slowTimelock.DEFAULT_ADMIN_ROLE();
        require(defaultAdminRole == bytes32(0), "slow timelock DEFAULT_ADMIN_ROLE mismatch");
        require(slowTimelock.hasRole(defaultAdminRole, TIMELOCK), "slow timelock missing self admin role");
        require(!slowTimelock.hasRole(defaultAdminRole, SAFE_ADDRESS), "main multisig still slow timelock admin");
    }

    function _hasRoleMember(IAccessControlEnumerable enumerable, bytes32 role, address member)
        internal
        view
        returns (bool)
    {
        uint256 count = enumerable.getRoleMemberCount(role);
        for (uint256 i = 0; i < count; i++) {
            if (enumerable.getRoleMember(role, i) == member) return true;
        }
        return false;
    }
}
