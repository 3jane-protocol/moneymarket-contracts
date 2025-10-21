// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

/**
 * @title DeployJane
 * @notice Deploy Jane token for v1.1 upgrade
 * @dev Deploys with owner and distributor
 *      Minter role (RewardsDistributor) will be added in Phase 3
 */
contract DeployJane is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("jane");
        if (existing != address(0)) {
            console.log("Jane already deployed at:", existing);
            return existing;
        }

        // Load owner and distributor from environment
        address owner = vm.envAddress("OWNER_ADDRESS");
        address distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");

        console.log("Deploying Jane token...");
        console.log("  Owner:", owner);
        console.log("  Distributor:", distributor);
        console.log("  Note: Minter role will be granted to RewardsDistributor in Phase 3");

        vm.startBroadcast();

        Jane jane = new Jane(
            owner, // initialOwner
            distributor // distributor for redistributed tokens
        );

        console.log("Jane token deployed at:", address(jane));
        console.log("  transferable:", false, "(default)");

        vm.stopBroadcast();

        return address(jane);
    }

    function _loadAddress(string memory key) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        try vm.readFile(deploymentsPath) returns (string memory json) {
            try vm.parseJsonAddress(json, string.concat(".", key)) returns (address addr) {
                return addr;
            } catch {
                return address(0);
            }
        } catch {
            return address(0);
        }
    }
}
