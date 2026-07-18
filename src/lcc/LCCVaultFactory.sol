// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {BeaconProxy} from "../../lib/openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IBeacon} from "../../lib/openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {ILCCVault} from "./interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "./libraries/LCCErrorsLib.sol";

/// @title LCCVaultFactory
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Deploys {LCCVault} instances and records them in a provenance registry.
/// @dev Vault creation is owner-gated; registry membership (isVault/allVaults) records owner-vetted provenance, not
/// exclusive deployment authority. Non-factory BeaconProxy instances can point at the same public beacon and remain
/// unregistered. For deterministic deployments, governance derives
/// `salt = keccak256(abi.encode(bytes32("3JANE_LCC_VAULT_V1"), block.chainid, facilityId))`, where `facilityId` is a
/// durable governance-assigned bytes32 identifier recorded in the deployment manifest. Tooling that starts from a
/// string uses `facilityId = keccak256(bytes(facilityIdString))`, with the string interpreted as UTF-8. An exact
/// duplicate `(salt, params)` fails closed on the CREATE2 collision, while reusing a salt with different params
/// produces a different address because the initializer calldata changes the initcode hash.
contract LCCVaultFactory {
    /// @notice Emitted when a vault is deployed through this factory.
    /// @param vault The newly deployed vault.
    /// @param owner The vault's configured owner.
    event VaultCreated(address indexed vault, address indexed owner);

    /// @notice Address authorized to deploy vaults through this factory.
    address public immutable owner;
    /// @notice Beacon used by vault proxies deployed through this factory.
    address public immutable beacon;

    /// @notice Whether an address is a vault deployed by this factory.
    mapping(address => bool) public isVault;

    address[] internal vaultList;

    /// @notice Deploys the factory with its permanent owner.
    /// @param owner_ Address authorized to deploy vaults.
    /// @param beacon_ UpgradeableBeacon serving LCC vault implementations.
    constructor(address owner_, address beacon_) {
        if (owner_ == address(0) || beacon_ == address(0)) revert LCCErrorsLib.ZeroAddress();
        // Probes the beacon so a factory wired to a non-beacon address (EOA, wrong contract, or a beacon with no
        // implementation) fails at deployment with a typed error rather than leaving an immutable, permanently
        // unusable createVault.
        (bool ok, bytes memory data) = beacon_.staticcall(abi.encodeCall(IBeacon.implementation, ()));
        if (!ok || data.length != 32 || abi.decode(data, (address)) == address(0)) {
            revert LCCErrorsLib.InvalidParams();
        }
        owner = owner_;
        beacon = beacon_;
    }

    /// @notice Deploys a new vault with the given parameters and records it in the registry.
    /// @dev Equivalent to the two-argument overload with the default salt `bytes32(0)`. Deploying identical params
    /// through this path twice reverts on the CREATE2 collision; pass an explicit salt to deploy a duplicate facility.
    /// @param params The facility configuration; see {ILCCVault.VaultParams}.
    /// @return vault The deterministic address of the newly deployed vault.
    function createVault(ILCCVault.VaultParams calldata params) external returns (address vault) {
        if (msg.sender != owner) revert LCCErrorsLib.NotOwner();
        return _createAndRegister(params, bytes32(0));
    }

    /// @notice Deploys a new vault at a salt-chosen deterministic address and records it in the registry.
    /// @dev Governance should derive `salt` using the contract-level facility identifier policy. Repeating the same
    /// `(salt, params)` reverts on a CREATE2 collision; the same salt with different params has different initcode and
    /// therefore a different address.
    /// @param params The facility configuration; see {ILCCVault.VaultParams}.
    /// @param salt The governance-derived CREATE2 salt.
    /// @return vault The deterministic address of the newly deployed vault.
    function createVault(ILCCVault.VaultParams calldata params, bytes32 salt) external returns (address vault) {
        if (msg.sender != owner) revert LCCErrorsLib.NotOwner();
        return _createAndRegister(params, salt);
    }

    /// @notice Predicts the address produced by createVault for the given params and salt.
    /// @dev For the single-argument createVault overload, pass the default salt `bytes32(0)`.
    /// @param params The facility configuration included in the BeaconProxy initializer calldata.
    /// @param salt The governance-derived CREATE2 salt.
    /// @return vault The address at which this factory will deploy the vault.
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

        isVault[vault] = true;
        vaultList.push(vault);

        emit VaultCreated(vault, params.owner);
    }

    /// @notice All vaults deployed by this factory, in deployment order.
    /// @return The list of vault addresses.
    function allVaults() external view returns (address[] memory) {
        return vaultList;
    }

    /// @notice Number of vaults deployed by this factory.
    /// @return The vault count.
    function numVaults() external view returns (uint256) {
        return vaultList.length;
    }
}
