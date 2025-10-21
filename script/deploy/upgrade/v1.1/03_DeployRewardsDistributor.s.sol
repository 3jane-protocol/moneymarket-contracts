// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RewardsDistributor} from "../../../../src/jane/RewardsDistributor.sol";

/**
 * @title DeployRewardsDistributor
 * @notice Deploy RewardsDistributor for v1.1 upgrade
 * @dev Manages Jane token rewards distribution with 7-day epochs
 */
contract DeployRewardsDistributor is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("rewardsDistributor");
        if (existing != address(0)) {
            console.log("RewardsDistributor already deployed at:", existing);
            return existing;
        }

        // Load addresses from environment
        address owner = vm.envAddress("OWNER_ADDRESS");
        address jane = vm.envAddress("JANE_ADDRESS");

        // Use current block timestamp as epoch 0 start if not provided
        uint256 epochStart;
        try vm.envUint("EPOCH_START_TIMESTAMP") returns (uint256 start) {
            epochStart = start;
        } catch {
            epochStart = block.timestamp;
        }

        // Default to mint mode (can toggle later)
        bool useMint = true;
        try vm.envBool("USE_MINT_MODE") returns (bool mint) {
            useMint = mint;
        } catch {}

        // Maximum amount of JANE that can be minted during phase 1 LM program
        uint256 maxLMMintable;
        try vm.envUint("MAX_LM_MINTABLE") returns (uint256 max) {
            maxLMMintable = max;
        } catch {
            maxLMMintable = 100_000_000e18; // Default: 100M JANE
        }

        console.log("Deploying RewardsDistributor...");
        console.log("  Owner:", owner);
        console.log("  Jane:", jane);
        console.log("  Use mint mode:", useMint);
        console.log("  Epoch 0 start:", epochStart);
        console.log("  Max LM mintable:", maxLMMintable / 1e18, "JANE");

        vm.startBroadcast();

        RewardsDistributor rewardsDistributor = new RewardsDistributor(
            owner, // initialOwner
            jane, // jane token address
            useMint, // use mint mode
            epochStart, // epoch 0 start timestamp (7-day epochs)
            maxLMMintable // maximum mintable for phase 1 LM program
        );

        console.log("RewardsDistributor deployed at:", address(rewardsDistributor));
        console.log("Note: Will be added as minter to Jane in Phase 3");

        vm.stopBroadcast();

        return address(rewardsDistributor);
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
