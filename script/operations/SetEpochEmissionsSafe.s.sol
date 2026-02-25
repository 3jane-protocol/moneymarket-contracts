// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {RewardsDistributor} from "../../src/jane/RewardsDistributor.sol";

/**
 * @title SetEpochEmissionsSafe
 * @notice Set emission amount for a single epoch on RewardsDistributor via Safe multisig
 * @dev Executes setEpochEmissions for one epoch in an atomic Safe transaction
 */
contract SetEpochEmissionsSafe is Script, SafeHelper {
    /**
     * @notice Main execution function
     * @param epoch The epoch number to set emissions for
     * @param emissions The emission amount in wei (e.g., 10000 * 1e18 for 10,000 JANE)
     * @param send Whether to send transaction to Safe API (true) or just simulate (false)
     */
    function run(uint256 epoch, uint256 emissions, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Set Epoch Emissions via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Load RewardsDistributor address
        address rewardsDistributor = vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS");
        console2.log("RewardsDistributor address:", rewardsDistributor);
        console2.log("");

        // Get current emissions for this epoch
        uint256 currentEmissions = RewardsDistributor(rewardsDistributor).epochEmissions(epoch);

        // Get current maxClaimable
        uint256 currentMaxClaimable = RewardsDistributor(rewardsDistributor).maxClaimable();

        // Calculate the impact on maxClaimable
        int256 maxClaimableImpact;
        if (currentEmissions == 0) {
            maxClaimableImpact = int256(emissions);
        } else if (emissions > currentEmissions) {
            maxClaimableImpact = int256(emissions - currentEmissions);
        } else {
            maxClaimableImpact = -int256(currentEmissions - emissions);
        }

        uint256 newMaxClaimable;
        if (maxClaimableImpact >= 0) {
            newMaxClaimable = currentMaxClaimable + uint256(maxClaimableImpact);
        } else {
            newMaxClaimable = currentMaxClaimable - uint256(-maxClaimableImpact);
        }

        console2.log("=== Epoch Configuration ===");
        console2.log("Epoch number:", epoch);
        console2.log("Current emissions:", _formatJane(currentEmissions));
        console2.log("New emissions:", _formatJane(emissions));
        console2.log("");

        console2.log("=== Max Claimable Impact ===");
        console2.log("Current max claimable:", _formatJane(currentMaxClaimable));
        if (maxClaimableImpact >= 0) {
            console2.log("Change: +%s JANE", _formatJane(uint256(maxClaimableImpact)));
        } else {
            console2.log("Change: -%s JANE", _formatJane(uint256(-maxClaimableImpact)));
        }
        console2.log("New max claimable:", _formatJane(newMaxClaimable));
        console2.log("");

        // Create the setEpochEmissions call
        bytes memory setEmissionsCall = abi.encodeCall(RewardsDistributor.setEpochEmissions, (epoch, emissions));

        // Add to batch
        addToBatch(rewardsDistributor, setEmissionsCall);

        console2.log("=== Batch Summary ===");
        console2.log("Operation: RewardsDistributor.setEpochEmissions");
        console2.log("Parameters:");
        console2.log("  - epoch:", epoch);
        console2.log("  - emissions:", _formatJane(emissions));
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
            console2.log("3. Epoch", epoch, "emissions will be set to", _formatJane(emissions));
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     * @param epoch The epoch number to set emissions for
     * @param emissions The emission amount in wei
     */
    function run(uint256 epoch, uint256 emissions) external {
        this.run(epoch, emissions, false);
    }

    /**
     * @notice Format JANE amount (18 decimals) to human readable
     */
    function _formatJane(uint256 amount) private pure returns (string memory) {
        if (amount == 0) {
            return "0 JANE";
        }

        uint256 whole = amount / 1e18;
        uint256 decimal = (amount % 1e18) / 1e15; // Show 3 decimal places

        if (decimal == 0) {
            return string(abi.encodePacked(vm.toString(whole), " JANE"));
        } else {
            // Remove trailing zeros from decimal
            while (decimal > 0 && decimal % 10 == 0) {
                decimal = decimal / 10;
            }
            return string(abi.encodePacked(vm.toString(whole), ".", vm.toString(decimal), " JANE"));
        }
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
