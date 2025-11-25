// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {Jane} from "../../src/jane/Jane.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";

/**
 * @title GenerateMerkleClaim
 * @notice Generates merkle tree and proofs for JANE token rewards distribution via Safe multisig
 * @dev Updates merkle root on RewardsDistributor through Safe transaction
 *
 * Usage:
 *   forge script script/operations/GenerateMerkleClaim.s.sol --sig "run(string,bool)" "data/allocations.json" false  #
 * Dry run
 *   forge script script/operations/GenerateMerkleClaim.s.sol --sig "run(string,bool)" "data/allocations.json" true   #
 * Send to Safe
 */
contract GenerateMerkleClaim is Script, SafeHelper {
    /// @notice JANE token address (mainnet)
    address private constant JANE = 0xFf031e9FCDeE6207fC17E1F1fefc66D346fD72fc;

    /// @notice RewardsDistributor address (mainnet)
    address private constant REWARDS_DISTRIBUTOR = 0xaC6985D4dBcd89CCAD71DB9bf0309eaF57F064e8;

    /// @notice Test claim address
    address private constant TEST_USER = 0x9C14ca2486E824eCcC0e0f95969D1DF22DA9D207;

    /// @notice Test allocation amount (1,000 JANE)
    uint256 private constant TEST_ALLOCATION = 100 ether;

    /// @notice Struct for JSON parsing allocations
    struct Allocation {
        uint256 amount;
        address user;
    }

    /// @notice Struct to hold merkle tree data
    struct MerkleData {
        bytes32 root;
        bytes32[] leaves;
        mapping(address => bytes32[]) userProofs;
        mapping(address => uint256) userAmounts;
        address[] users;
    }

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
     * @notice Sorts two hashes for merkle tree construction
     * @param a First hash
     * @param b Second hash
     * @return The hashes in sorted order
     */
    function sortPair(bytes32 a, bytes32 b) private pure returns (bytes32, bytes32) {
        return a < b ? (a, b) : (b, a);
    }

    /**
     * @notice Computes parent hash from two child hashes
     * @param a First child hash
     * @param b Second child hash
     * @return Parent hash
     */
    function hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        (bytes32 left, bytes32 right) = sortPair(a, b);
        return keccak256(abi.encodePacked(left, right));
    }

    /**
     * @notice Generates a merkle tree from allocations
     * @param allocations Array of user allocations
     * @return root The merkle root
     * @return leaves The sorted merkle leaves
     * @return proofs Array of merkle proofs for each allocation
     */
    function generateMerkleTree(Allocation[] memory allocations)
        public
        pure
        returns (bytes32 root, bytes32[] memory leaves, bytes32[][] memory proofs)
    {
        uint256 n = allocations.length;
        require(n > 0, "No allocations provided");

        // Generate leaves
        leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = computeLeaf(allocations[i].user, allocations[i].amount);
        }

        // Sort leaves for deterministic tree
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (leaves[j] > leaves[j + 1]) {
                    bytes32 temp = leaves[j];
                    leaves[j] = leaves[j + 1];
                    leaves[j + 1] = temp;

                    // Also swap allocations to maintain alignment
                    Allocation memory tempAlloc = allocations[j];
                    allocations[j] = allocations[j + 1];
                    allocations[j + 1] = tempAlloc;
                }
            }
        }

        // Handle single leaf case
        if (n == 1) {
            proofs = new bytes32[][](1);
            proofs[0] = new bytes32[](0); // Empty proof for single leaf
            return (leaves[0], leaves, proofs);
        }

        // Build merkle tree
        proofs = new bytes32[][](n);
        for (uint256 i = 0; i < n; i++) {
            proofs[i] = new bytes32[](0); // Initialize empty proofs
        }

        // Build tree level by level
        bytes32[] memory currentLevel = leaves;
        uint256 levelSize = n;

        while (levelSize > 1) {
            bytes32[] memory nextLevel = new bytes32[]((levelSize + 1) / 2);
            uint256 nextIndex = 0;

            for (uint256 i = 0; i < levelSize; i += 2) {
                bytes32 left = currentLevel[i];
                bytes32 right = (i + 1 < levelSize) ? currentLevel[i + 1] : left;
                nextLevel[nextIndex] = hashPair(left, right);

                // Update proofs for leaves at this level
                if (levelSize == n) {
                    // First level (leaves)
                // For left leaf, add right as proof element
                    if (i < n) {
                        bytes32[] memory newProof = new bytes32[](proofs[i].length + 1);
                        for (uint256 k = 0; k < proofs[i].length; k++) {
                            newProof[k] = proofs[i][k];
                        }
                        newProof[proofs[i].length] = right;
                        proofs[i] = newProof;
                    }

                    // For right leaf, add left as proof element
                    if (i + 1 < n && i + 1 < levelSize) {
                        bytes32[] memory newProof = new bytes32[](proofs[i + 1].length + 1);
                        for (uint256 k = 0; k < proofs[i + 1].length; k++) {
                            newProof[k] = proofs[i + 1][k];
                        }
                        newProof[proofs[i + 1].length] = left;
                        proofs[i + 1] = newProof;
                    }
                }

                nextIndex++;
            }

            currentLevel = nextLevel;
            levelSize = nextLevel.length;
        }

        root = currentLevel[0];
        return (root, leaves, proofs);
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
        console2.log("Allocation: %s JANE", TEST_ALLOCATION / 1e18);
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
     * @notice Generate merkle tree and optionally update root via Safe multisig
     * @param jsonPath Path to JSON file containing allocations
     * @param send Whether to send transaction to Safe (true) or just simulate (false)
     */
    function run(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("========================================");
        console2.log("JANE MERKLE CLAIM GENERATOR");
        console2.log("========================================");
        console2.log("");

        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Mode:", send ? "SEND TO SAFE" : "DRY RUN");
        console2.log("Reading allocations from:", jsonPath);
        console2.log("");

        // Read and parse JSON file
        string memory json = vm.readFile(jsonPath);

        // Parse as array of objects with "address" and "amount" fields
        // Note: JSON uses "address" but our struct uses "user"
        bytes memory data = vm.parseJson(json);

        // First decode with field name that matches JSON
        string memory modifiedJson = json;
        // Since Solidity doesn't have built-in JSON field mapping, we need to handle this
        // The JSON has "address" field but our struct expects "user"
        // For simplicity, we'll parse directly matching the JSON structure
        bytes memory jsonBytes = vm.parseJson(json);

        // Parse JSON with matching field names
        Allocation[] memory allocations = abi.decode(vm.parseJson(json), (Allocation[]));

        console2.log("Found %s allocations", allocations.length);
        console2.log("");

        // Calculate total allocation
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocation += allocations[i].amount;
        }

        console2.log("Total allocation: %s JANE", totalAllocation / 1e18);
        console2.log("");

        // Generate merkle tree
        (bytes32 root, bytes32[] memory leaves, bytes32[][] memory proofs) = generateMerkleTree(allocations);

        console2.log("========================================");
        console2.log("MERKLE TREE GENERATED");
        console2.log("========================================");
        console2.log("");
        console2.log("Merkle Root:", vm.toString(root));
        console2.log("");

        // Output command for setup
        console2.log("========================================");
        console2.log("SETUP COMMAND");
        console2.log("========================================");
        console2.log("");

        console2.log("Update merkle root:");
        console2.log("");
        console2.log("cast send", REWARDS_DISTRIBUTOR, "\\");
        console2.log('  "updateRoot(bytes32)" \\');
        console2.log("  ", vm.toString(root), "\\");
        console2.log("  --rpc-url $RPC_URL \\");
        console2.log("  --account <your-account>");
        console2.log("");

        // Output individual user proofs (first 3 as examples)
        console2.log("========================================");
        console2.log("USER CLAIMS (showing first 3)");
        console2.log("========================================");
        console2.log("");

        uint256 displayCount = allocations.length < 3 ? allocations.length : 3;
        for (uint256 i = 0; i < displayCount; i++) {
            console2.log("User %s: %s", i + 1, allocations[i].user);
            console2.log("Amount: %s JANE", allocations[i].amount / 1e18);
            console2.log("Proof:");

            // Format proof array
            if (proofs[i].length == 0) {
                console2.log('  "[]"');
            } else {
                console2.log('  "[');
                for (uint256 j = 0; j < proofs[i].length; j++) {
                    if (j < proofs[i].length - 1) {
                        console2.log('    "%s",', vm.toString(proofs[i][j]));
                    } else {
                        console2.log('    "%s"', vm.toString(proofs[i][j]));
                    }
                }
                console2.log('  ]"');
            }

            console2.log("");
            console2.log("Claim command:");
            console2.log("cast send", REWARDS_DISTRIBUTOR, "\\");
            console2.log('  "claim(address,uint256,bytes32[])" \\');
            console2.log("  ", allocations[i].user, "\\");
            console2.log("  ", allocations[i].amount, "\\");

            // Inline proof for command
            if (proofs[i].length == 0) {
                console2.log('  "[]" \\');
            } else {
                string memory proofStr = '  "[';
                for (uint256 j = 0; j < proofs[i].length; j++) {
                    proofStr = string.concat(proofStr, vm.toString(proofs[i][j]));
                    if (j < proofs[i].length - 1) {
                        proofStr = string.concat(proofStr, ",");
                    }
                }
                proofStr = string.concat(proofStr, ']" \\');
                console2.log(proofStr);
            }

            console2.log("  --rpc-url $RPC_URL \\");
            console2.log("  --account <user-or-authorized-claimer>");
            console2.log("");
            console2.log("----------------------------------------");
            console2.log("");
        }

        if (allocations.length > 3) {
            console2.log("... and %s more users", allocations.length - 3);
            console2.log("");
        }

        // Save output to file
        string memory outputPath = string.concat("data/merkle-output-", vm.toString(block.timestamp), ".json");
        console2.log("Saving merkle data to:", outputPath);

        // Build output JSON
        string memory outputJson = "{\n";
        outputJson = string.concat(outputJson, '  "root": "', vm.toString(root), '",\n');
        outputJson = string.concat(outputJson, '  "total": "', vm.toString(totalAllocation), '",\n');
        outputJson = string.concat(outputJson, '  "claims": [\n');

        for (uint256 i = 0; i < allocations.length; i++) {
            outputJson = string.concat(outputJson, "    {\n");
            outputJson = string.concat(outputJson, '      "address": "', vm.toString(allocations[i].user), '",\n');
            outputJson = string.concat(outputJson, '      "amount": "', vm.toString(allocations[i].amount), '",\n');
            outputJson = string.concat(outputJson, '      "proof": [');

            for (uint256 j = 0; j < proofs[i].length; j++) {
                outputJson = string.concat(outputJson, '"', vm.toString(proofs[i][j]), '"');
                if (j < proofs[i].length - 1) {
                    outputJson = string.concat(outputJson, ",");
                }
            }

            outputJson = string.concat(outputJson, "]\n    }");
            if (i < allocations.length - 1) {
                outputJson = string.concat(outputJson, ",");
            }
            outputJson = string.concat(outputJson, "\n");
        }

        outputJson = string.concat(outputJson, "  ]\n}\n");

        vm.writeFile(outputPath, outputJson);
        console2.log("Output saved successfully");
        console2.log("");

        // Create the updateRoot call
        bytes memory updateRootCall = abi.encodeCall(RewardsDistributor.updateRoot, (root));

        // Add to batch
        addToBatch(REWARDS_DISTRIBUTOR, updateRootCall);

        console2.log("========================================");
        console2.log("BATCH SUMMARY");
        console2.log("========================================");
        console2.log("Operation: RewardsDistributor.updateRoot");
        console2.log("Merkle Root:", vm.toString(root));
        console2.log("");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve the transaction in Safe UI");
            console2.log("2. Once threshold reached, anyone can execute");
            console2.log("3. Merkle root will be updated to:", vm.toString(root));
            console2.log("4. Users can then claim using the generated proofs");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     * @param jsonPath Path to JSON file containing allocations
     */
    function run(string memory jsonPath) external {
        this.run(jsonPath, false);
    }

    /**
     * @notice Legacy execution function for single test user
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

    /**
     * @notice Check if base fee is acceptable
     * @return True if base fee is below limit
     */
    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
