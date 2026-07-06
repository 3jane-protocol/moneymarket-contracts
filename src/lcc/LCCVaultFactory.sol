// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {LCCVault} from "./LCCVault.sol";
import {ILCCVault} from "./interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "./libraries/LCCErrorsLib.sol";

/// @title LCCVaultFactory
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Deploys {LCCVault} instances and records them in a provenance registry.
/// @dev Vault creation is owner-gated; registry membership (isVault/allVaults) records owner-vetted provenance.
contract LCCVaultFactory {
    /// @notice Emitted when a vault is deployed through this factory.
    /// @param vault The newly deployed vault.
    /// @param owner The vault's configured owner.
    event VaultCreated(address indexed vault, address indexed owner);

    /// @notice Address authorized to deploy vaults through this factory.
    address public immutable owner;

    /// @notice Whether an address is a vault deployed by this factory.
    mapping(address => bool) public isVault;

    address[] internal vaultList;

    /// @notice Deploys the factory with its permanent owner.
    /// @param owner_ Address authorized to deploy vaults.
    constructor(address owner_) {
        if (owner_ == address(0)) revert LCCErrorsLib.ZeroAddress();
        owner = owner_;
    }

    /// @notice Deploys a new vault with the given parameters and records it in the registry.
    /// @param params The facility configuration; see {ILCCVault.VaultParams}.
    /// @return vault The address of the newly deployed vault.
    function createVault(ILCCVault.VaultParams calldata params) external returns (address vault) {
        if (msg.sender != owner) revert LCCErrorsLib.NotOwner();

        vault = address(new LCCVault(params));
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
