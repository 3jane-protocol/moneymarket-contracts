// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {AccessControl} from "../lib/openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "../lib/openzeppelin/contracts/access/IAccessControl.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {Id, IMorphoCredit, MarketParams} from "./interfaces/IMorpho.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @title OperationalController
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Role-gated proxy for CreditLine and ProtocolConfig that provides tiered access:
/// OPERATOR_ROLE for routine credit operations, EMERGENCY_AUTHORIZED_ROLE for protocol safety actions.
/// @dev Deployed as both the CreditLine `ozd` and the ProtocolConfig `emergencyAdmin`.
/// @dev OPERATOR_ROLE is a trusted operational role. It can grant, resize, or revoke credit lines within
/// CreditLine validation; post repayment cycles and borrower obligations used by penalty accounting; and call
/// settle(), including the insurance-fund cover path. This controller does not add per-call caps or rate limits;
/// operator constraints come from multisig policy, CreditLine validation, and ProtocolConfig limits.
/// @dev OWNER_ROLE intentionally keeps DEFAULT_ADMIN_ROLE as its admin, and no account is granted
/// DEFAULT_ADMIN_ROLE. This preserves a single-owner invariant by making transferOwnership() the only owner
/// transition path.
contract OperationalController is AccessControlEnumerable {
    event CreditLineRevoked(address indexed borrower, address indexed executor);

    /// @notice Role identifier for the owner, which manages all controller roles.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Role identifier for accounts allowed to execute emergency actions.
    bytes32 public constant EMERGENCY_AUTHORIZED_ROLE = keccak256("EMERGENCY_AUTHORIZED_ROLE");

    /// @notice Role identifier for accounts allowed to execute routine credit operations.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Address of the ProtocolConfig contract.
    IProtocolConfig public immutable protocolConfig;

    /// @notice Address of the CreditLine contract.
    ICreditLine public immutable creditLine;

    /// @notice Initializes immutable contract references and grants initial roles.
    /// @param _protocolConfig Address of the ProtocolConfig contract.
    /// @param _creditLine Address of the CreditLine contract.
    /// @param _owner Initial owner address.
    /// @param _emergencyAuthorized Initial emergency-authorized accounts.
    /// @param _operators Initial operator accounts.
    constructor(
        address _protocolConfig,
        address _creditLine,
        address _owner,
        address[] memory _emergencyAuthorized,
        address[] memory _operators
    ) {
        if (_owner == address(0) || _protocolConfig == address(0) || _creditLine == address(0)) {
            revert ErrorsLib.ZeroAddress();
        }

        protocolConfig = IProtocolConfig(_protocolConfig);
        creditLine = ICreditLine(_creditLine);

        _grantRole(OWNER_ROLE, _owner);
        _setRoleAdmin(EMERGENCY_AUTHORIZED_ROLE, OWNER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, OWNER_ROLE);

        for (uint256 i = 0; i < _emergencyAuthorized.length; i++) {
            if (_emergencyAuthorized[i] == address(0)) revert ErrorsLib.ZeroAddress();
            _grantRole(EMERGENCY_AUTHORIZED_ROLE, _emergencyAuthorized[i]);
        }

        for (uint256 i = 0; i < _operators.length; i++) {
            if (_operators[i] == address(0)) revert ErrorsLib.ZeroAddress();
            _grantRole(OPERATOR_ROLE, _operators[i]);
        }
    }

    // ============ Emergency Stop Functions ============

    /// @notice Set an emergency protocol parameter (IS_PAUSED, DEBT_CAP, MAX_ON_CREDIT, USD3_SUPPLY_CAP).
    /// @dev Delegates to ProtocolConfig.setEmergencyConfig() which enforces binary constraints.
    function setConfig(bytes32 key, uint256 value) external onlyRole(EMERGENCY_AUTHORIZED_ROLE) {
        protocolConfig.setEmergencyConfig(key, value);
    }

    /// @notice Revoke a single borrower's credit line while preserving their current DRP.
    function emergencyRevokeCreditLine(Id id, address borrower) external onlyRole(EMERGENCY_AUTHORIZED_ROLE) {
        if (borrower == address(0)) revert ErrorsLib.ZeroAddress();

        address morpho = creditLine.MORPHO();
        (, uint128 currentDrp,) = IMorphoCredit(morpho).borrowerPremium(id, borrower);

        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = id;
        borrowers[0] = borrower;
        vv[0] = 1; // Set minimal vv to avoid division by zero in LTV check.
        credit[0] = 0; // Revoke credit.
        drp[0] = currentDrp; // Preserve existing DRP rate.

        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
        emit CreditLineRevoked(borrower, msg.sender);
    }

    // ============ Operator Functions ============

    /// @notice Batch-set borrower credit lines, DRP, and verified values.
    function setCreditLines(
        Id[] calldata ids,
        address[] calldata borrowers,
        uint256[] calldata vv,
        uint256[] calldata credit,
        uint128[] calldata drp
    ) external onlyRole(OPERATOR_ROLE) {
        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
    }

    /// @notice Close a payment cycle and post repayment obligations for borrowers.
    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external onlyRole(OPERATOR_ROLE) {
        creditLine.closeCycleAndPostObligations(id, endDate, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Add repayment obligations to the most recently closed cycle.
    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external onlyRole(OPERATOR_ROLE) {
        creditLine.addObligationsToLatestCycle(id, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Settle a borrower's position, optionally covering losses from the insurance fund.
    function settle(MarketParams memory marketParams, address borrower, uint256 assets, uint256 cover)
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        return creditLine.settle(marketParams, borrower, assets, cover);
    }

    // ============ Ownership ============

    /// @notice Transfers ownership to a new address atomically.
    function transferOwnership(address newOwner) external onlyRole(OWNER_ROLE) {
        if (newOwner == address(0)) revert ErrorsLib.ZeroAddress();
        address previousOwner = _msgSender();
        if (newOwner == previousOwner) revert ErrorsLib.AlreadySet();
        _grantRole(OWNER_ROLE, newOwner);
        _revokeRole(OWNER_ROLE, previousOwner);
        emit EventsLib.SetOwner(newOwner);
    }

    /// @notice Blocks renouncing OWNER_ROLE to prevent permanent admin lockout.
    function renounceRole(bytes32 role, address callerConfirmation) public override(AccessControl, IAccessControl) {
        if (role == OWNER_ROLE) revert ErrorsLib.CannotRenounceOwnerRole();
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Returns the current owner address.
    function owner() public view returns (address) {
        uint256 count = getRoleMemberCount(OWNER_ROLE);
        return count > 0 ? getRoleMember(OWNER_ROLE, 0) : address(0);
    }
}
