// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LeveragedCallableCreditVault} from "./LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "./interfaces/ILeveragedCallableCreditVault.sol";

/// @title LeveragedCallableCreditVaultFactory
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Deploys {LeveragedCallableCreditVault} instances and records them in a provenance registry.
/// @dev Vault creation is permissionless with arbitrary parameters; registry membership (isVault/allVaults) records
/// provenance only and confers no trust in a vault's owner, oracle, or assets.
contract LeveragedCallableCreditVaultFactory {
    /// @notice Emitted when a vault is deployed through this factory.
    /// @param vault The newly deployed vault.
    /// @param owner The vault's configured owner.
    event VaultCreated(address indexed vault, address indexed owner);

    /// @notice Whether an address is a vault deployed by this factory.
    mapping(address => bool) public isVault;

    address[] internal vaultList;

    /// @notice Deploys a new vault with the given parameters and records it in the registry.
    /// @param params The facility configuration; see {ILeveragedCallableCreditVault.VaultParams}.
    /// @return vault The address of the newly deployed vault.
    function createVault(ILeveragedCallableCreditVault.VaultParams calldata params) external returns (address vault) {
        vault = address(new LeveragedCallableCreditVault(params));
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
