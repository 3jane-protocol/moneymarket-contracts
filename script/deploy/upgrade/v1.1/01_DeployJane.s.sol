// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";
import {Jane} from "../../../../src/jane/Jane.sol";

/**
 * @title DeployJane
 * @notice Deploy Jane token for v1.1 upgrade via CREATE3
 * @dev Deploys with owner and distributor using CreateX CREATE3 for deterministic addressing
 *      Minter role (RewardsDistributor) will be added in Phase 3
 */
contract DeployJane is Script, CreateXScript {
    function setUp() public withCreateX {
        // withCreateX modifier ensures CreateX factory is available
        // Auto-deploys on local testnet (chainID 31337) if missing
    }

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

        // Load CREATE3 salt from environment
        bytes32 salt = vm.envBytes32("JANE_CREATE3_SALT");

        console.log("Deploying Jane token via CREATE3...");
        console.log("  Owner:", owner);
        console.log("  Distributor:", distributor);
        console.log("  Salt:", vm.toString(salt));
        console.log("  Note: Minter role will be granted to RewardsDistributor in Phase 3");

        vm.startBroadcast();

        // CREATE3 deployment for constructor-agnostic deterministic addressing
        bytes memory initCode = abi.encodePacked(type(Jane).creationCode, abi.encode(owner, distributor));

        address janeAddress = create3(salt, initCode);

        console.log("Jane token deployed at:", janeAddress);
        console.log("  transferable:", false, "(default)");
        console.log("  deployment method: CREATE3 (via CreateX)");

        vm.stopBroadcast();

        return janeAddress;
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
