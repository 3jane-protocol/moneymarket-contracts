// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LeveragedCallableCreditVault} from "./LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "./interfaces/ILeveragedCallableCreditVault.sol";

contract LeveragedCallableCreditVaultFactory {
    event VaultCreated(address indexed vault, address indexed owner);

    mapping(address => bool) public isVault;

    address[] internal vaultList;

    function createVault(ILeveragedCallableCreditVault.VaultParams calldata params) external returns (address vault) {
        vault = address(new LeveragedCallableCreditVault(params));
        isVault[vault] = true;
        vaultList.push(vault);

        emit VaultCreated(vault, params.owner);
    }

    function allVaults() external view returns (address[] memory) {
        return vaultList;
    }

    function numVaults() external view returns (uint256) {
        return vaultList.length;
    }
}
