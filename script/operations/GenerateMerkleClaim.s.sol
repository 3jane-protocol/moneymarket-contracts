// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Jane} from "../../src/jane/Jane.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";

/**
 * @title GenerateMerkleClaim
 * @notice Generates merkle tree and proofs for JANE token rewards distribution
 * @dev Operational script for testing merkle claims on deployed RewardsDistributor
 *
 * Usage:
 *   forge script script/operations/GenerateMerkleClaim.s.sol --sig "dryRun()"
 */
contract GenerateMerkleClaim is Script {
    /// @notice JANE token address (mainnet)
    address private constant JANE = 0xFf031e9FCDeE6207fC17E1F1fefc66D346fD72fc;

    /// @notice RewardsDistributor address (mainnet)
    address private constant REWARDS_DISTRIBUTOR = 0xc95f8F5ff078b65125C7d00f2cC7b4ae062f555c;

    /// @notice Test claim address
    address private constant TEST_USER = 0x9C14ca2486E824eCcC0e0f95969D1DF22DA9D207;

    /// @notice Test allocation amount (1,000 JANE)
    uint256 private constant TEST_ALLOCATION = 1000 ether;

    /**
     * @notice Computes a leaf hash from user address and amount
     * @dev Matches the leaf computation in RewardsDistributor
     * @param user The user address
     * @param amount The claim amount
     * @return The leaf hash
     */
    function computeLeaf(address user, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
    }

    /**
     * @notice Computes merkle root for single user
     * @dev For single-user tree, root = leaf
     * @param user The user address
     * @param amount The claim amount
     * @return The merkle root
     */
    function computeSingleUserRoot(address user, uint256 amount) public pure returns (bytes32) {
        return computeLeaf(user, amount);
    }

    /**
     * @notice Dry run function - generates merkle tree and outputs claim commands
     */
    function dryRun() external view {
        console2.log("========================================");
        console2.log("JANE MERKLE CLAIM GENERATOR");
        console2.log("========================================");
        console2.log("");

        console2.log("Contract Addresses:");
        console2.log("  JANE:                ", JANE);
        console2.log("  RewardsDistributor:  ", REWARDS_DISTRIBUTOR);
        console2.log("");

        // Verify contracts exist
        uint256 janeCodeSize;
        uint256 distributorCodeSize;

        assembly {
            janeCodeSize := extcodesize(JANE)
            distributorCodeSize := extcodesize(REWARDS_DISTRIBUTOR)
        }

        if (janeCodeSize == 0) {
            console2.log("[ERROR] JANE contract not found at address");
            return;
        } else {
            console2.log("[SUCCESS] JANE contract found");
        }

        if (distributorCodeSize == 0) {
            console2.log("[ERROR] RewardsDistributor contract not found at address");
            return;
        } else {
            console2.log("[SUCCESS] RewardsDistributor contract found");
        }

        console2.log("");
        console2.log("========================================");
        console2.log("TEST CLAIM CONFIGURATION");
        console2.log("========================================");
        console2.log("");

        console2.log("User:       ", TEST_USER);
        console2.log("Allocation: ", TEST_ALLOCATION / 1e18, "JANE");
        console2.log("");

        // Generate merkle tree (single user = leaf is root)
        bytes32 leaf = computeLeaf(TEST_USER, TEST_ALLOCATION);
        bytes32 merkleRoot = leaf; // For single user, root = leaf

        console2.log("Merkle Root:", vm.toString(merkleRoot));
        console2.log("Leaf Hash:  ", vm.toString(leaf));
        console2.log("");

        // For single-user tree, proof is empty
        console2.log("Merkle Proof: [] (empty for single-user tree)");
        console2.log("");

        console2.log("========================================");
        console2.log("STEP 1: SET EPOCH EMISSIONS");
        console2.log("========================================");
        console2.log("");
        console2.log("Allocate 10,000 JANE for epoch 0:");
        console2.log("");
        console2.log("cast send", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "setEpochEmissions(uint256,uint256)" \\');
        console2.log("  0 \\");
        console2.log("  10000000000000000000000 \\");
        console2.log("  --rpc-url $RPC_URL \\");
        console2.log("  --account <your-account>");
        console2.log("");

        console2.log("========================================");
        console2.log("STEP 2: UPDATE MERKLE ROOT");
        console2.log("========================================");
        console2.log("");
        console2.log("Set the merkle root in RewardsDistributor:");
        console2.log("");
        console2.log("cast send", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "updateRoot(bytes32)" \\');
        console2.log("  ", vm.toString(merkleRoot), "\\");
        console2.log("  --rpc-url $RPC_URL \\");
        console2.log("  --account <your-account>");
        console2.log("");

        console2.log("========================================");
        console2.log("STEP 3: VERIFY PROOF (OPTIONAL)");
        console2.log("========================================");
        console2.log("");
        console2.log("Verify the merkle proof is valid:");
        console2.log("");
        console2.log("cast call", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "verify(address,uint256,bytes32[])" \\');
        console2.log("  ", TEST_USER, "\\");
        console2.log("  ", TEST_ALLOCATION, "\\");
        console2.log('  "[]" \\');
        console2.log("  --rpc-url $RPC_URL");
        console2.log("");
        console2.log("Expected output: true");
        console2.log("");

        console2.log("========================================");
        console2.log("STEP 4: CLAIM REWARDS");
        console2.log("========================================");
        console2.log("");
        console2.log("Execute the claim (as the user or on behalf of):");
        console2.log("");
        console2.log("cast send", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "claim(address,uint256,bytes32[])" \\');
        console2.log("  ", TEST_USER, "\\");
        console2.log("  ", TEST_ALLOCATION, "\\");
        console2.log('  "[]" \\');
        console2.log("  --rpc-url $RPC_URL \\");
        console2.log("  --account <your-account>");
        console2.log("");

        console2.log("========================================");
        console2.log("STEP 5: VERIFY CLAIM");
        console2.log("========================================");
        console2.log("");
        console2.log("Check JANE balance after claim:");
        console2.log("");
        console2.log("cast call", JANE, "\\");
        console2.log('  "balanceOf(address)" \\');
        console2.log("  ", TEST_USER, "\\");
        console2.log("  --rpc-url $RPC_URL");
        console2.log("");
        console2.log("Expected: 1000000000000000000000 (1,000 JANE)");
        console2.log("");

        console2.log("========================================");
        console2.log("ADDITIONAL COMMANDS");
        console2.log("========================================");
        console2.log("");

        console2.log("Check current epoch:");
        console2.log("cast call", REWARDS_DISTRIBUTOR, '"epoch()"', "--rpc-url $RPC_URL");
        console2.log("");

        console2.log("Check claimable amount:");
        console2.log("cast call", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "getClaimable(address,uint256)" \\');
        console2.log("  ", TEST_USER, "\\");
        console2.log("  ", TEST_ALLOCATION, "\\");
        console2.log("  --rpc-url $RPC_URL");
        console2.log("");

        console2.log("Check already claimed amount:");
        console2.log("cast call", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "claimed(address)" \\');
        console2.log("  ", TEST_USER, "\\");
        console2.log("  --rpc-url $RPC_URL");
        console2.log("");
    }

    /**
     * @notice Execution function to set emissions and update root on-chain
     * @dev Only runs if WALLET_TYPE=account is set
     */
    function run() external {
        console2.log("========================================");
        console2.log("EXECUTING MERKLE SETUP ON-CHAIN");
        console2.log("========================================");
        console2.log("");

        // Check wallet type
        string memory walletType = vm.envString("WALLET_TYPE");
        require(keccak256(bytes(walletType)) == keccak256("account"), "Execution requires WALLET_TYPE=account");

        // Generate merkle root
        bytes32 merkleRoot = computeSingleUserRoot(TEST_USER, TEST_ALLOCATION);
        console2.log("Merkle Root:", vm.toString(merkleRoot));
        console2.log("");

        vm.startBroadcast();

        RewardsDistributor distributor = RewardsDistributor(REWARDS_DISTRIBUTOR);

        // Step 1: Set epoch emissions
        console2.log("Setting epoch 0 emissions to 10,000 JANE...");
        distributor.setEpochEmissions(0, 10_000 ether);
        console2.log("[SUCCESS] Epoch emissions set");
        console2.log("");

        // Step 2: Update merkle root
        console2.log("Updating merkle root...");
        distributor.updateRoot(merkleRoot);
        console2.log("[SUCCESS] Merkle root updated");
        console2.log("");

        vm.stopBroadcast();

        console2.log("========================================");
        console2.log("SETUP COMPLETE");
        console2.log("========================================");
        console2.log("");
        console2.log("Next step: User can now claim using the commands from dryRun()");
        console2.log("");
    }
}
