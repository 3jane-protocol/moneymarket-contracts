// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PYTLocker} from "../../../../src/jane/PYTLocker.sol";

/**
 * @title DeployPYTLocker
 * @notice Deploy PYTLocker for v1.1 upgrade
 * @dev Optional deployment for Pendle yield token integration
 *      PYT tokens must be added via addToken() in Phase 3
 */
contract DeployPYTLocker is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("pytLocker");
        if (existing != address(0)) {
            console.log("PYTLocker already deployed at:", existing);
            return existing;
        }

        // Load owner from environment
        address owner = vm.envAddress("OWNER_ADDRESS");

        console.log("Deploying PYTLocker (optional - Pendle integration)...");
        console.log("  Owner:", owner);

        vm.startBroadcast();

        PYTLocker pytLocker = new PYTLocker(owner);

        console.log("PYTLocker deployed at:", address(pytLocker));
        console.log("Note: Add supported PYT tokens via addToken() in Phase 3");

        vm.stopBroadcast();

        return address(pytLocker);
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
