// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {USD3} from "../../src/usd3/USD3.sol";

/**
 * @title DeployUSD3ImplementationSimple
 * @notice Deploys a new USD3 implementation contract without using OpenZeppelin upgrades library
 * @dev Simple deployment that relies on manual validation of storage compatibility
 */
contract DeployUSD3ImplementationSimple is Script {
    // Existing proxy address on mainnet
    address constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    function run() external returns (address) {
        console.log("=== Deploying New USD3 Implementation (Simple) ===");
        console.log("Existing USD3 Proxy:", USD3_PROXY);
        console.log("");

        vm.startBroadcast();

        // Deploy the new implementation directly
        USD3 newImplementation = new USD3();

        vm.stopBroadcast();

        address implAddress = address(newImplementation);

        console.log("New USD3 Implementation deployed at:", implAddress);
        console.log("");
        console.log("=== IMPORTANT: Manual Verification Required ===");
        console.log("1. Verify storage layout compatibility manually");
        console.log("2. Ensure no constructor logic in implementation");
        console.log("3. Verify the implementation on Etherscan");
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Use ScheduleUpgradeViaSafe to schedule the upgrade");
        console.log("2. Wait for timelock delay (typically 2 days)");
        console.log("3. Execute the upgrade using ExecuteTimelockViaSafe");

        // Save deployment info
        _saveDeployment(implAddress);

        return implAddress;
    }

    /**
     * @notice Save deployment information for reference
     */
    function _saveDeployment(address implementation) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/");
        string memory fileName = string.concat(deploymentsPath, "usd3-upgrade-", vm.toString(block.timestamp), ".json");

        // Create deployment directory if it doesn't exist
        vm.createDir(deploymentsPath, true);

        // Create JSON with deployment info
        string memory json = "deployment";
        vm.serializeAddress(json, "proxy", USD3_PROXY);
        vm.serializeAddress(json, "newImplementation", implementation);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "chainId", block.chainid);
        string memory finalJson = vm.serializeString(json, "description", "USD3 Implementation Upgrade");

        // Write to file
        vm.writeJson(finalJson, fileName);

        console.log("Deployment info saved to:", fileName);
    }
}
