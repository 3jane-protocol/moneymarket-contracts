// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

/**
 * @title ComputeJaneAddress
 * @notice Pre-compute Jane token deployment address using CREATE3
 * @dev Calculates the deterministic address before actual deployment
 *      Useful for verification and planning
 */
contract ComputeJaneAddress is Script, CreateXScript {
    function setUp() public withCreateX {
        // withCreateX modifier ensures CreateX factory is available
    }

    function run() external view {
        // Load salt from environment
        bytes32 salt = vm.envBytes32("JANE_CREATE3_SALT");

        // Load deployer address (msg.sender during actual deployment)
        address deployer = vm.envAddress("OWNER_ADDRESS");

        // Compute CREATE3 address
        address computedAddress = computeCreate3Address(salt, deployer);

        // Display results
        console.log("========================================");
        console.log("JANE CREATE3 Address Computation");
        console.log("========================================");
        console.log("");
        console.log("Salt:              ", vm.toString(salt));
        console.log("Deployer:          ", deployer);
        console.log("");
        console.log("Computed Address:  ", computedAddress);
        console.log("");
        console.log("========================================");
        console.log("");
        console.log("This address will be the same regardless of:");
        console.log("  - Constructor parameters (owner, distributor)");
        console.log("  - Contract bytecode changes");
        console.log("  - Nonce or transaction ordering");
        console.log("");
        console.log("CreateX Factory:   ", 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
        console.log("========================================");
    }
}
