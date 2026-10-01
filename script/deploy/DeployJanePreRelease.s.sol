// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Jane} from "../../src/jane/Jane.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";

/**
 * @title DeployJanePreRelease
 * @notice Pre-release deployment of JANE token and RewardsDistributor for testing
 * @dev Simplified deployment that:
 *      1. Deploys Jane token with owner
 *      2. Deploys RewardsDistributor
 *      3. Grants MINTER_ROLE to RewardsDistributor
 *
 *      Environment Variables:
 *      - OWNER_ADDRESS (required): Address that will own both contracts
 *      - EPOCH_START_TIMESTAMP (optional): Start time for epoch 0, defaults to block.timestamp
 *      - USE_MINT_MODE (optional): True to mint on claim, false to transfer. Defaults to true
 */
contract DeployJanePreRelease is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function run() external returns (address janeAddress, address distributorAddress) {
        console.log("========================================");
        console.log("JANE PRE-RELEASE DEPLOYMENT");
        console.log("========================================");
        console.log("");

        // Load configuration
        address owner = vm.envAddress("OWNER_ADDRESS");

        uint256 epochStart;
        try vm.envUint("EPOCH_START_TIMESTAMP") returns (uint256 start) {
            epochStart = start;
        } catch {
            epochStart = block.timestamp;
        }

        bool useMint = true;
        try vm.envBool("USE_MINT_MODE") returns (bool mint) {
            useMint = mint;
        } catch {}

        console.log("Configuration:");
        console.log("  Owner:", owner);
        console.log("  Epoch start:", epochStart);
        console.log("  Use mint mode:", useMint);
        console.log("  Network:", block.chainid);
        console.log("");

        vm.startBroadcast();

        // Step 1: Deploy Jane token
        console.log("Step 1: Deploying Jane token...");
        Jane jane = new Jane(
            owner, // initialOwner
            address(0), // minter (will add RewardsDistributor next)
            address(0) // burner (for future use)
        );
        janeAddress = address(jane);
        console.log("  Jane deployed at:", janeAddress);
        console.log("  Symbol: JANE");
        console.log("  Transferable:", false);
        console.log("  Mint finalized:", false);
        console.log("");

        // Step 2: Deploy RewardsDistributor
        console.log("Step 2: Deploying RewardsDistributor...");
        RewardsDistributor distributor = new RewardsDistributor(
            owner, // initialOwner
            janeAddress, // jane token
            useMint, // use mint mode
            epochStart // epoch 0 start
        );
        distributorAddress = address(distributor);
        console.log("  RewardsDistributor deployed at:", distributorAddress);
        console.log("  Epoch 0 starts:", epochStart);
        console.log("  Epoch duration: 7 days");
        console.log("");

        // Step 3: Grant MINTER_ROLE to RewardsDistributor
        console.log("Step 3: Granting MINTER_ROLE to RewardsDistributor...");
        jane.grantRole(MINTER_ROLE, distributorAddress);
        console.log("  MINTER_ROLE granted");
        console.log("  RewardsDistributor can now mint JANE tokens");
        console.log("");

        vm.stopBroadcast();

        // Summary
        console.log("========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  Jane:                ", janeAddress);
        console.log("  RewardsDistributor:  ", distributorAddress);
        console.log("");
        console.log("Owner:", owner);
        console.log("");
        console.log("========================================");
        console.log("NEXT STEPS FOR TESTING");
        console.log("========================================");
        console.log("");
        console.log("1. Set epoch emissions:");
        console.log("   RewardsDistributor.setEpochEmissions(epochNumber, amount)");
        console.log("");
        console.log("2. Generate and set merkle root:");
        console.log("   - Create merkle tree with user allocations");
        console.log("   - Call RewardsDistributor.updateRoot(merkleRoot)");
        console.log("");
        console.log("3. Test claiming:");
        console.log("   - Users call RewardsDistributor.claim(user, totalAllocation, proof)");
        console.log("   - RewardsDistributor will mint JANE tokens to claimants");
        console.log("");
        console.log("4. (Optional) Enable transfers:");
        console.log("   - Call Jane.setTransferable() when ready");
        console.log("   - Transfers are disabled by default");
        console.log("");

        if (block.timestamp >= epochStart) {
            console.log("Current epoch:", (block.timestamp - epochStart) / 7 days);
        } else {
            console.log("Epochs start in:", (epochStart - block.timestamp) / 1 days, "days");
        }
        console.log("");

        return (janeAddress, distributorAddress);
    }
}
