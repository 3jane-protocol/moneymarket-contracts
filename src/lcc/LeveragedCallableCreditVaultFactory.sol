// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LeveragedCallableCreditVault} from "./LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "./interfaces/ILeveragedCallableCreditVault.sol";

contract LeveragedCallableCreditVaultFactory {
    error DuplicateFacility();

    event VaultCreated(bytes32 indexed facilityId, address indexed vault, address indexed owner);

    mapping(bytes32 => address) public vaultFor;
    mapping(address => bool) public isVault;

    address[] internal vaultList;

    function createVault(bytes32 facilityId, ILeveragedCallableCreditVault.VaultParams calldata params)
        external
        returns (address vault)
    {
        if (vaultFor[facilityId] != address(0)) revert DuplicateFacility();

        vault = address(new LeveragedCallableCreditVault(params));
        vaultFor[facilityId] = vault;
        isVault[vault] = true;
        vaultList.push(vault);

        emit VaultCreated(facilityId, vault, params.owner);
    }

    function allVaults() external view returns (address[] memory) {
        return vaultList;
    }

    function numVaults() external view returns (uint256) {
        return vaultList.length;
    }
}
