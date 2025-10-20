// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

/**
 * @title DeployJane
 * @notice Deploy Jane token for v1.1 upgrade
 * @dev Deploys with owner, minter and burner as address(0) initially
 *      Minter (RewardsDistributor) and Burner (MarkdownController) will be added in Phase 3
 */
contract DeployJane is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("jane");
        if (existing != address(0)) {
            console.log("Jane already deployed at:", existing);
            return existing;
        }

        // Load owner from environment
        address owner = vm.envAddress("OWNER_ADDRESS");

        console.log("Deploying Jane token...");
        console.log("  Owner:", owner);
        console.log("  Initial minter: 0x0 (will add RewardsDistributor in Phase 3)");
        console.log("  Initial burner: 0x0 (will add MarkdownController in Phase 3)");

        vm.startBroadcast();

        Jane jane = new Jane(
            owner, // initialOwner
            address(0), // minter (add RewardsDistributor later)
            address(0) // burner (add MarkdownController later)
        );

        console.log("Jane token deployed at:", address(jane));
        console.log("  transferable:", false, "(default)");
        console.log("  mintFinalized:", false, "(default)");

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
