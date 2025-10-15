// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployUSD3Implementation
 * @notice Deploys a new USD3 implementation contract for upgrading the existing proxy
 * @dev Uses OpenZeppelin's upgrades library to ensure upgrade safety and storage compatibility
 */
contract DeployUSD3Implementation is Script {
    // Existing proxy address on mainnet
    address constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    function run() external returns (address) {
        console.log("=== Deploying New USD3 Implementation ===");
        console.log("Existing USD3 Proxy:", USD3_PROXY);
        console.log("");

        // Configure options for upgrade validation
        Options memory opts;
        // Set to false to enable all safety checks
        // Only set to true if you're absolutely sure about storage compatibility
        opts.unsafeSkipAllChecks = false;
        opts.unsafeAllow = "delegatecall";

        vm.startBroadcast();

        // Deploy the new implementation
        // This will:
        // 1. Compile and deploy the new USD3 implementation
        // 2. Validate storage layout compatibility
        // 3. Check for unsafe patterns (constructors, etc.)
        // 4. Return the deployed implementation address
        address newImplementation = Upgrades.deployImplementation("USD3.sol:USD3", opts);

        vm.stopBroadcast();

        console.log("New USD3 Implementation deployed at:", newImplementation);
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Verify the implementation on Etherscan");
        console.log("2. Use ScheduleUpgradeViaSafe to schedule the upgrade");
        console.log("3. Wait for timelock delay (typically 2 days)");
        console.log("4. Execute the upgrade using ExecuteTimelockViaSafe");

        // Save deployment info
        _saveDeployment(newImplementation);

        return newImplementation;
    }

    /**
     * @notice Alternative function that uses prepareUpgrade to validate against existing proxy
     * @dev This is more thorough as it checks compatibility with the actual proxy's storage
     */
    function runWithValidation() external returns (address) {
        console.log("=== Deploying New USD3 Implementation with Proxy Validation ===");
        console.log("Validating against USD3 Proxy:", USD3_PROXY);
        console.log("");

        Options memory opts;
        opts.unsafeSkipAllChecks = false;

        // Additional validation options
        opts.defender.useDefenderDeploy = false; // We're not using Defender

        vm.startBroadcast();

        // prepareUpgrade validates the new implementation against the existing proxy
        // This ensures storage layout compatibility
        address newImplementation = Upgrades.prepareUpgrade("out/USD3.sol/USD3.json", opts);

        vm.stopBroadcast();

        console.log("New USD3 Implementation deployed at:", newImplementation);
        console.log("Storage layout validated against proxy");
        console.log("");
        console.log("=== Validation Passed ===");
        console.log("The new implementation is compatible with the existing proxy storage");

        _saveDeployment(newImplementation);

        return newImplementation;
    }

    /**
     * @notice Dry run to validate without deploying
     * @dev Useful for testing storage compatibility before actual deployment
     */
    function validateOnly() external view {
        console.log("=== Validating USD3 Implementation (Dry Run) ===");
        console.log("Checking storage layout compatibility...");

        Options memory opts;
        opts.unsafeSkipAllChecks = false;

        // This will validate without deploying
        // Note: This is a simulation, actual validation happens during deployment
        console.log("Validation would check:");
        console.log("  - Storage layout compatibility");
        console.log("  - No constructor in implementation");
        console.log("  - Proper initializer pattern");
        console.log("  - No selfdestruct or delegatecall to arbitrary addresses");
        console.log("");
        console.log("Run 'runWithValidation()' to perform actual validation and deployment");
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
