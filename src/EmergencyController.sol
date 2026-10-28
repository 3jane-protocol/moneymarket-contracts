// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Id, MarketParams} from "./interfaces/IMorpho.sol";
import {IMorphoCredit} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {CreditLine} from "./CreditLine.sol";
import {AccessControlEnumerable} from "../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControl} from "../lib/openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "../lib/openzeppelin/contracts/access/IAccessControl.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ProtocolConfigLib} from "./libraries/ProtocolConfigLib.sol";

/// @title EmergencyController
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Emergency controller for immediate protocol safety actions
/// @dev Provides binary stop controls via setConfig() and credit line revocation
/// @dev setConfig() enforces binary constraints through ProtocolConfig.setEmergencyConfig():
/// - IS_PAUSED: Can only be set to 1 (pause protocol)
/// - DEBT_CAP: Can only be set to 0 (stop new borrowing)
/// - MAX_ON_CREDIT: Can only be set to 0 (stop USD3 deployments to MorphoCredit)
/// - USD3_SUPPLY_CAP: Can only be set to 0 (stop new deposits)
/// @dev emergencyRevokeCreditLine() removes individual borrower's credit line while preserving DRP
contract EmergencyController is AccessControlEnumerable {
    // Custom events
    event CreditLineRevoked(address indexed borrower, address indexed executor);

    /// @notice Role identifier for the owner (can manage all roles and contract parameters)
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Role identifier for accounts allowed to execute emergency actions
    bytes32 public constant EMERGENCY_AUTHORIZED_ROLE = keccak256("EMERGENCY_AUTHORIZED_ROLE");

    /// @notice Address of the ProtocolConfig contract
    IProtocolConfig public immutable protocolConfig;

    /// @notice Address of the CreditLine contract
    ICreditLine public immutable creditLine;

    /// @notice Constructor to set immutable addresses
    /// @param _protocolConfig Address of the ProtocolConfig contract
    /// @param _creditLine Address of the CreditLine contract
    /// @param _owner Initial owner address (role admin)
    /// @param _emergencyAuthorized Initial list of addresses authorized for emergency actions
    constructor(address _protocolConfig, address _creditLine, address _owner, address[] memory _emergencyAuthorized) {
        if (_owner == address(0) || _protocolConfig == address(0) || _creditLine == address(0)) {
            revert ErrorsLib.ZeroAddress();
        }

        _grantRole(OWNER_ROLE, _owner);
        _setRoleAdmin(EMERGENCY_AUTHORIZED_ROLE, OWNER_ROLE);
        protocolConfig = IProtocolConfig(_protocolConfig);
        creditLine = ICreditLine(_creditLine);

        for (uint256 i = 0; i < _emergencyAuthorized.length; i++) {
            if (_emergencyAuthorized[i] == address(0)) revert ErrorsLib.ZeroAddress();
            _grantRole(EMERGENCY_AUTHORIZED_ROLE, _emergencyAuthorized[i]);
        }
    }

    // ============ Emergency Stop Functions ============

    /// @notice Set emergency configuration with binary constraints
    /// @param key Configuration key (IS_PAUSED, DEBT_CAP, MAX_ON_CREDIT, USD3_SUPPLY_CAP)
    /// @param value Configuration value (binary constraints enforced by ProtocolConfig)
    /// @dev IS_PAUSED can only be set to 1, others can only be set to 0
    function setConfig(bytes32 key, uint256 value) external onlyRole(EMERGENCY_AUTHORIZED_ROLE) {
        protocolConfig.setEmergencyConfig(key, value);
    }

    // ============ Credit Line Control ============

    /// @notice Revoke a single borrower's credit line
    /// @param id Market ID
    /// @param borrower Address to revoke credit from
    /// @dev Sets the borrower's credit line to 0, preventing further borrowing
    /// @dev Preserves the borrower's existing DRP rate so they continue paying risk premium on existing debt
    function emergencyRevokeCreditLine(Id id, address borrower) external onlyRole(EMERGENCY_AUTHORIZED_ROLE) {
        if (borrower == address(0)) revert ErrorsLib.ZeroAddress();

        // Query the borrower's current DRP to preserve it
        address morpho = creditLine.MORPHO();
        (, uint128 currentDrp,) = IMorphoCredit(morpho).borrowerPremium(id, borrower);

        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = id;
        borrowers[0] = borrower;
        vv[0] = 1; // Set minimal vv to avoid division by zero in LTV check
        credit[0] = 0; // Revoke credit
        drp[0] = currentDrp; // Preserve existing DRP rate

        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
        emit CreditLineRevoked(borrower, msg.sender);
    }

    // ============ Ownership ============

    /// @notice Transfers ownership to a new address atomically
    /// @dev Only callable by current owner. Grants to new owner before revoking from caller.
    /// @param newOwner Address that will become the new owner
    function transferOwnership(address newOwner) external onlyRole(OWNER_ROLE) {
        if (newOwner == address(0)) revert ErrorsLib.ZeroAddress();
        address previousOwner = _msgSender();
        if (newOwner == previousOwner) revert ErrorsLib.AlreadySet();
        _grantRole(OWNER_ROLE, newOwner);
        _revokeRole(OWNER_ROLE, previousOwner);
        emit EventsLib.SetOwner(newOwner);
    }

    /// @notice Blocks renouncing OWNER_ROLE to prevent permanent admin lockout
    /// @dev EMERGENCY_AUTHORIZED_ROLE can still be renounced by its holders
    function renounceRole(bytes32 role, address callerConfirmation) public override(AccessControl, IAccessControl) {
        if (role == OWNER_ROLE) revert ErrorsLib.CannotRenounceOwnerRole();
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Returns the current owner address
    /// @return The owner address, or address(0) if no owner exists
    function owner() public view returns (address) {
        uint256 count = getRoleMemberCount(OWNER_ROLE);
        return count > 0 ? getRoleMember(OWNER_ROLE, 0) : address(0);
    }
}
