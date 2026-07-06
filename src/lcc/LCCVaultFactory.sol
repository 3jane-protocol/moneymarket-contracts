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
/// unregistered.
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
    /// @param params The facility configuration; see {ILCCVault.VaultParams}.
    /// @return vault The address of the newly deployed vault.
    function createVault(ILCCVault.VaultParams calldata params) external returns (address vault) {
        if (msg.sender != owner) revert LCCErrorsLib.NotOwner();

        vault = address(new BeaconProxy(beacon, abi.encodeCall(ILCCVault.initialize, (params))));
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
