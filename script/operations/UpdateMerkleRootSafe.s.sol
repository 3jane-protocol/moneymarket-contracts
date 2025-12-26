// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";

/**
 * @title UpdateMerkleRootSafe
 * @notice Update the merkle root on RewardsDistributor via Safe multisig
 * @dev Simple script for when you already have a merkle root generated
 *
 * Usage:
 *   forge script script/operations/UpdateMerkleRootSafe.s.sol --sig "run(bytes32,bool)" 0x1234...abcd false  # Dry run
 *   forge script script/operations/UpdateMerkleRootSafe.s.sol --sig "run(bytes32,bool)" 0x1234...abcd true   # Send to
 * Safe
 */
contract UpdateMerkleRootSafe is Script, SafeHelper {
    /// @notice RewardsDistributor address (mainnet)
    address private constant REWARDS_DISTRIBUTOR = 0xaC6985D4dBcd89CCAD71DB9bf0309eaF57F064e8;

    /**
     * @notice Update merkle root via Safe multisig
     * @param newRoot The new merkle root to set
     * @param send Whether to send transaction to Safe (true) or just simulate (false)
     */
    function run(bytes32 newRoot, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Update Merkle Root via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Get current root for comparison
        RewardsDistributor distributor = RewardsDistributor(REWARDS_DISTRIBUTOR);
        bytes32 currentRoot = distributor.merkleRoot();

        console2.log("RewardsDistributor:", REWARDS_DISTRIBUTOR);
        console2.log("");

        console2.log("=== Root Update ===");
        console2.log("Current root:", vm.toString(currentRoot));
        console2.log("New root:    ", vm.toString(newRoot));
        console2.log("");

        if (currentRoot == newRoot) {
            console2.log("WARNING: New root is the same as current root!");
            console2.log("");
        }

        // Create the updateRoot call
        bytes memory updateRootCall = abi.encodeCall(RewardsDistributor.updateRoot, (newRoot));

        // Add to batch
        addToBatch(REWARDS_DISTRIBUTOR, updateRootCall);

        console2.log("=== Batch Summary ===");
        console2.log("Operation: RewardsDistributor.updateRoot");
        console2.log("New Root:", vm.toString(newRoot));
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
            console2.log("3. Merkle root will be updated to:", vm.toString(newRoot));
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     * @param newRoot The new merkle root to set
     */
    function run(bytes32 newRoot) external {
        this.run(newRoot, false);
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
