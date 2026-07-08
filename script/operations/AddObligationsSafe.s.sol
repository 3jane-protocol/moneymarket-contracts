// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {CycleObligationDataLib} from "../utils/CycleObligationDataLib.sol";

/// @title AddObligationsSafe Script
/// @notice Adds obligations to the latest closed cycle via Safe multisig transaction
/// @dev For use when a cycle is already closed and you need to add more obligations
contract AddObligationsSafe is Script, SafeHelper {
    using CycleObligationDataLib for *;

    /// @notice CreditLine contract address (mainnet)
    CreditLine private constant creditLine = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Maximum number of obligations to process in a single call
    uint256 private constant BATCH_SIZE = 50;

    /// @notice Struct for JSON parsing - fields ordered to match alphabetized JSON
    /// @dev JSON fields alphabetically: borrower, endingBalance, repaymentBps
    struct ObligationData {
        address borrower; // maps to "borrower" (1st alphabetically)
        uint256 endingBalance; // maps to "endingBalance" (2nd alphabetically)
        uint256 repaymentBps; // maps to "repaymentBps" (3rd alphabetically)
    }

    /// @notice Main execution function
    /// @param jsonPath Path to JSON file containing obligation data
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Adding Obligations to Latest Cycle via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("CreditLine address:", address(creditLine));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        ObligationData[] memory obligations = abi.decode(data, (ObligationData[]));

        console2.log("Loaded", obligations.length, "obligations from JSON");

        // Validate all obligations
        for (uint256 i = 0; i < obligations.length; i++) {
            require(
                CycleObligationDataLib.validateObligation(
                    obligations[i].borrower, obligations[i].repaymentBps, obligations[i].endingBalance
                ),
                string.concat("Invalid obligation for borrower ", vm.toString(obligations[i].borrower))
            );
        }

        console2.log("All obligations validated successfully");
        console2.log("");

        // Process in batches
        uint256 totalBatches = (obligations.length + BATCH_SIZE - 1) / BATCH_SIZE;
        console2.log("Processing in %d batches of up to %d obligations each", totalBatches, BATCH_SIZE);

        for (uint256 i = 0; i < obligations.length; i += BATCH_SIZE) {
            uint256 end = i + BATCH_SIZE > obligations.length ? obligations.length : i + BATCH_SIZE;
            uint256 size = end - i;

            console2.log("Batch %d - Processing obligations %d to %d", (i / BATCH_SIZE) + 1, i, end - 1);

            // Prepare arrays for this batch
            address[] memory borrowers = new address[](size);
            uint256[] memory repaymentBps = new uint256[](size);
            uint256[] memory endingBalances = new uint256[](size);

            for (uint256 j = 0; j < size; j++) {
                ObligationData memory ob = obligations[i + j];
                borrowers[j] = ob.borrower;
                repaymentBps[j] = ob.repaymentBps;
                endingBalances[j] = ob.endingBalance;

                console2.log("  -", vm.toString(ob.borrower));
                console2.log("    Repayment:", ob.repaymentBps, "bps");
                console2.log("    Ending balance:", ob.endingBalance);
            }

            // Encode the addObligationsToLatestCycle call
            bytes memory callData = abi.encodeCall(
                creditLine.addObligationsToLatestCycle, (MARKET_ID, borrowers, repaymentBps, endingBalances)
            );

            // Add to Safe batch
            addToBatch(address(creditLine), callData);
        }

        console2.log("");
        console2.log("All batches prepared");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Alternative entry point with default simulation mode
    /// @param jsonPath Path to JSON file containing obligation data
    function run(string memory jsonPath) external {
        this.run(jsonPath, false);
    }

    /// @notice Check if base fee is acceptable
    /// @return True if base fee is below limit
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
