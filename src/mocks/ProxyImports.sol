// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {TransparentUpgradeableProxy} from "lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

// Dummy contract to force Hardhat to generate types for OpenZeppelin proxy contracts
contract ProxyImports {
    // Empty contract - exists only to ensure proxy contract ABIs are included in compilation
}