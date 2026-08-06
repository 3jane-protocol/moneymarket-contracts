// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {AccessControl} from "../../lib/openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "../../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "../../lib/openzeppelin/contracts/access/IAccessControl.sol";
import {BeaconProxy} from "../../lib/openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "../../lib/openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {ILCCAdmissionsModule} from "./interfaces/ILCCAdmissionsModule.sol";
import {ILCCVault} from "./interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "./libraries/LCCErrorsLib.sol";

/// @title LCCVaultFactory
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Deploys {LCCVault} instances and provides family-wide authority and deposit admission.
/// @dev Factory registration is the supported deployment boundary. Although the beacon is public, an unregistered
/// proxy cannot pass this factory's deposit gate. For deterministic deployments, governance derives
/// `salt = keccak256(abi.encode(bytes32("3JANE_LCC_VAULT_V1"), block.chainid, facilityId))`, where `facilityId` is a
/// durable governance-assigned bytes32 identifier recorded in the deployment manifest. Tooling that starts from a
/// string uses `facilityId = keccak256(bytes(facilityIdString))`, with the string interpreted as UTF-8. Reusing a
/// salt with different params produces a different address because the initializer calldata changes the initcode
/// hash.
/// @dev OWNER_ROLE intentionally keeps DEFAULT_ADMIN_ROLE as its admin, and no account is granted
/// DEFAULT_ADMIN_ROLE. This preserves the single-owner invariant by making the two-step ownership functions the sole
/// owner transition path.
contract LCCVaultFactory is AccessControlEnumerable {
    /// @notice Role identifier for the sole family owner.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    /// @notice Role identifier for accounts allowed to manage the depositor whitelist.
    bytes32 public constant LISTER_ROLE = keccak256("LISTER_ROLE");
    /// @notice Role identifier reserved for commitment bounce operations.
    bytes32 public constant BOUNCER_ROLE = keccak256("BOUNCER_ROLE");
    /// @notice Role identifier for accounts allowed to pause family vaults.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Emitted when a vault is deployed through this factory.
    event VaultCreated(address indexed vault);
    /// @notice Emitted when ownership transfer is proposed.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    /// @notice Emitted when a pending owner accepts ownership.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted for each depositor whitelist update.
    event DepositorWhitelistUpdated(address indexed depositor, bool allowed);
    /// @notice Emitted when the whitelist kill switch changes.
    event WhitelistEnabledUpdated(bool enabled);
    /// @notice Emitted when the one-vault-policy kill switch changes.
    event OneVaultPolicyEnabledUpdated(bool enabled);
    /// @notice Emitted when an admissions module is replaced.
    event AdmissionsModuleUpdated(address indexed previousModule, address indexed newModule, uint256 version);
    /// @notice Emitted when a user's warm vault registration changes.
    event VaultRegistrationUpdated(address indexed user, address indexed vault);

    /// @notice Beacon used by vault proxies deployed through this factory.
    address public immutable beacon;
    /// @notice Proposed owner that must call {acceptOwnership}.
    address public pendingOwner;
    /// @notice Optional narrow admission-decision module; zero disables module checks.
    address public admissionsModule;
    /// @notice Monotone module configuration version included in update events.
    uint256 public admissionsModuleVersion;

    /// @notice Whether the global depositor whitelist is enforced.
    bool public whitelistEnabled = true;
    /// @notice Whether deposits are prospectively limited to one open family vault.
    bool public oneVaultPolicyEnabled = true;

    /// @notice Whether an address is approved to deposit into family vaults.
    mapping(address => bool) public isWhitelistedDepositor;
    /// @notice Whether an address is a vault deployed by this factory.
    mapping(address => bool) public isVault;
    /// @notice Most recently authorized family vault for a depositor.
    mapping(address => address) public vaultOf;

    address[] internal vaultList;

    /// @notice Deploys the factory and grants its single owner.
    /// @param owner_ Initial family owner.
    /// @param beacon_ UpgradeableBeacon serving LCC vault implementations.
    constructor(address owner_, address beacon_) {
        if (owner_ == address(0) || beacon_ == address(0)) revert LCCErrorsLib.ZeroAddress();
        // Probe the immutable beacon so a malformed target cannot permanently brick createVault.
        (bool ok, bytes memory data) = beacon_.staticcall(abi.encodeCall(IBeacon.implementation, ()));
        if (!ok || data.length != 32 || abi.decode(data, (address)) == address(0)) {
            revert LCCErrorsLib.InvalidParams();
        }

        beacon = beacon_;
        _grantRole(OWNER_ROLE, owner_);
        _setRoleAdmin(LISTER_ROLE, OWNER_ROLE);
        _setRoleAdmin(BOUNCER_ROLE, OWNER_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, OWNER_ROLE);
    }

    /// @notice Starts a two-step family ownership transfer, replacing any prior pending owner.
    function transferOwnership(address newOwner) external onlyRole(OWNER_ROLE) {
        address previousOwner = owner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(previousOwner, newOwner);
    }

    /// @notice Accepts a pending ownership transfer and atomically rotates the sole OWNER_ROLE member.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert LCCErrorsLib.Unauthorized();
        address previousOwner = owner();
        pendingOwner = address(0);
        if (msg.sender != previousOwner) {
            _grantRole(OWNER_ROLE, msg.sender);
            _revokeRole(OWNER_ROLE, previousOwner);
        }
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    /// @notice Blocks renouncing OWNER_ROLE to preserve family-wide emergency authority.
    function renounceRole(bytes32 role, address callerConfirmation) public override(AccessControl, IAccessControl) {
        if (role == OWNER_ROLE) revert LCCErrorsLib.Unauthorized();
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Returns the current sole owner, or zero if role storage is unexpectedly empty.
    function owner() public view returns (address) {
        uint256 count = getRoleMemberCount(OWNER_ROLE);
        return count == 0 ? address(0) : getRoleMember(OWNER_ROLE, 0);
    }

    /// @dev AUTHORITY-VIEW RULE: these views read only this factory's AccessControl role storage. They must never
    /// call an admissions module or any external contract, and must never loop; vault emergency and settlement paths
    /// rely on these non-upgradeable, STATICCALL-safe reads.
    function isOwner(address account) external view returns (bool) {
        return hasRole(OWNER_ROLE, account);
    }

    /// @dev See the authority-view rule above.
    function isGuardian(address account) external view returns (bool) {
        return hasRole(GUARDIAN_ROLE, account);
    }

    /// @dev See the authority-view rule above.
    function requireBouncer(address account) external view {
        if (!hasRole(BOUNCER_ROLE, account)) revert LCCErrorsLib.Unauthorized();
    }

    /// @notice Batch-updates the global depositor whitelist.
    function setDepositorsWhitelisted(address[] calldata depositors, bool allowed) external onlyRole(LISTER_ROLE) {
        for (uint256 i = 0; i < depositors.length; ++i) {
            isWhitelistedDepositor[depositors[i]] = allowed;
            emit DepositorWhitelistUpdated(depositors[i], allowed);
        }
    }

    /// @notice Enables or disables whitelist enforcement without clearing whitelist state.
    function setWhitelistEnabled(bool enabled) external onlyRole(OWNER_ROLE) {
        whitelistEnabled = enabled;
        emit WhitelistEnabledUpdated(enabled);
    }

    /// @notice Enables or disables prospective one-open-vault enforcement without clearing warm registrations.
    function setOneVaultPolicyEnabled(bool enabled) external onlyRole(OWNER_ROLE) {
        oneVaultPolicyEnabled = enabled;
        emit OneVaultPolicyEnabledUpdated(enabled);
    }

    /// @notice Replaces the optional admission-decision module after probing its narrow view interface.
    function setAdmissionsModule(address newModule) external onlyRole(OWNER_ROLE) {
        if (newModule != address(0)) {
            if (newModule.code.length == 0) revert LCCErrorsLib.InvalidParams();
            (bool ok, bytes memory data) =
                newModule.staticcall(abi.encodeCall(ILCCAdmissionsModule.canDeposit, (address(this), address(this))));
            if (!ok || data.length != 32) revert LCCErrorsLib.InvalidParams();
            abi.decode(data, (bool));
        }

        address previousModule = admissionsModule;
        admissionsModule = newModule;
        uint256 version = ++admissionsModuleVersion;
        emit AdmissionsModuleUpdated(previousModule, newModule, version);
    }

    /// @notice Authorizes and records a completed vault deposit.
    /// @dev While one-vault enforcement is disabled, `vaultOf` remains a warm last-deposit pointer but makes no
    /// exclusivity claim. Re-enabling the policy is prospective and does not close positions opened while disabled.
    function authorizeDeposit(address user, bool hadOpenExposure) external {
        if (!isVault[msg.sender]) revert LCCErrorsLib.NotVault();
        if (whitelistEnabled && !isWhitelistedDepositor[user]) revert LCCErrorsLib.NotWhitelistedDepositor();

        address currentVault = vaultOf[user];
        if (currentVault == msg.sender && hadOpenExposure) return;
        if (
            oneVaultPolicyEnabled && currentVault != address(0) && currentVault != msg.sender
                && !ILCCVault(currentVault).isAccountClosed(user)
        ) {
            revert LCCErrorsLib.RegisteredElsewhere(currentVault);
        }

        address module = admissionsModule;
        if (module != address(0) && !ILCCAdmissionsModule(module).canDeposit(user, msg.sender)) {
            revert LCCErrorsLib.Unauthorized();
        }

        // Under deposit reentrancy, last-write-wins means the OUTERMOST frame wins. With the policy off, nothing
        // reverts a nested double-deposit; this is acceptable because no exclusivity invariant is claimed while off.
        // This warm write is deliberately unconditional with respect to oneVaultPolicyEnabled.
        vaultOf[user] = msg.sender;
        emit VaultRegistrationUpdated(user, msg.sender);
    }

    /// @notice Deploys a new vault using the default salt and records it in the factory registry.
    function createVault(ILCCVault.VaultParams calldata params) external onlyRole(OWNER_ROLE) returns (address vault) {
        return _createAndRegister(params, bytes32(0));
    }

    /// @notice Deploys a new vault using an explicit CREATE2 salt and records it in the factory registry.
    function createVault(ILCCVault.VaultParams calldata params, bytes32 salt)
        external
        onlyRole(OWNER_ROLE)
        returns (address vault)
    {
        return _createAndRegister(params, salt);
    }

    /// @notice Predicts the address produced by createVault for the given params and salt.
    function predictVaultAddress(ILCCVault.VaultParams calldata params, bytes32 salt)
        external
        view
        returns (address vault)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BeaconProxy).creationCode, abi.encode(beacon, abi.encodeCall(ILCCVault.initialize, (params)))
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _createAndRegister(ILCCVault.VaultParams calldata params, bytes32 salt) internal returns (address vault) {
        vault = address(new BeaconProxy{salt: salt}(beacon, abi.encodeCall(ILCCVault.initialize, (params))));
        // initialize must not call an isVault-gated factory function: registration occurs only after construction.
        isVault[vault] = true;
        vaultList.push(vault);
        emit VaultCreated(vault);
    }

    /// @notice All vaults deployed by this factory, in deployment order.
    function allVaults() external view returns (address[] memory) {
        return vaultList;
    }

    /// @notice Number of vaults deployed by this factory.
    function numVaults() external view returns (uint256) {
        return vaultList.length;
    }
}
