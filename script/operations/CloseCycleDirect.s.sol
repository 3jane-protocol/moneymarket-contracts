// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {CycleObligationDataLib} from "../utils/CycleObligationDataLib.sol";

/// @title CloseCycleDirect Script
/// @notice Closes payment cycles and posts obligations via direct execution
/// @dev For testing or emergency use - production should use CloseCycleSafe
/// @dev First batch uses closeCycleAndPostObligations, subsequent batches use addObligationsToLatestCycle
contract CloseCycleDirect is Script {
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

    /// @notice Dry run function for validation without execution
    /// @param jsonPath Path to JSON file containing obligation data
    /// @param endDate Unix timestamp for cycle end date
    function dryRun(string memory jsonPath, uint256 endDate) external view {
        console2.log("=== DRY RUN: Closing Cycle and Posting Obligations ===");
        console2.log("CreditLine address:", address(creditLine));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("End date:", endDate);
        console2.log("JSON file:", jsonPath);
        console2.log("");

        // Validate end date
        require(CycleObligationDataLib.validateEndDate(endDate), "End date must be in the past or very near future");

        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        ObligationData[] memory obligations = abi.decode(data, (ObligationData[]));

        console2.log("Loaded", obligations.length, "obligations from JSON");

        uint256 validCount = 0;
        uint256 invalidCount = 0;

        // Validate and display all obligations
        for (uint256 i = 0; i < obligations.length; i++) {
            ObligationData memory ob = obligations[i];
            bool valid = CycleObligationDataLib.validateObligation(ob.borrower, ob.repaymentBps, ob.endingBalance);

            if (valid) {
                console2.log("[SUCCESS] Borrower:", ob.borrower);
                validCount++;
            } else {
                console2.log("[FAILED] Borrower:", ob.borrower);
                invalidCount++;
            }

            console2.log("  Repayment:", ob.repaymentBps, "bps");
            console2.log("  Ending balance:", ob.endingBalance);

            if (!valid) {
                if (ob.borrower == address(0)) console2.log("  ERROR: Zero address");
                if (!CycleObligationDataLib.validateRepaymentBps(ob.repaymentBps)) {
                    console2.log("  ERROR: Invalid repayment BPS");
                }
                if (!CycleObligationDataLib.validateEndingBalance(ob.endingBalance)) {
                    console2.log("  ERROR: Invalid ending balance");
                }
            }
        }

        console2.log("");
        console2.log("Summary:");
        console2.log("  Valid obligations:", validCount);
        console2.log("  Invalid obligations:", invalidCount);
        console2.log("  Total batches needed:", (obligations.length + BATCH_SIZE - 1) / BATCH_SIZE);

        require(invalidCount == 0, "Some obligations failed validation");
        console2.log("");
        console2.log("Dry run completed successfully!");
    }

    /// @notice Main execution function
    /// @param jsonPath Path to JSON file containing obligation data
    /// @param endDate Unix timestamp for cycle end date
    function run(string memory jsonPath, uint256 endDate) external {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Closing Cycle and Posting Obligations (Direct) ===");
        console2.log("CreditLine address:", address(creditLine));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("End date:", endDate);
        console2.log("JSON file:", jsonPath);
        console2.log("");

        // Validate end date
        require(CycleObligationDataLib.validateEndDate(endDate), "End date must be in the past or very near future");

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

        // Get the deployer account
        string memory walletType = vm.envString("WALLET_TYPE");
        require(keccak256(bytes(walletType)) == keccak256("account"), "Direct execution requires WALLET_TYPE=account");

        string memory accountName = vm.envString("SAFE_PROPOSER_ACCOUNT");
        console2.log("Using account:", accountName);

        vm.startBroadcast();

        // Process in batches
        uint256 totalBatches = (obligations.length + BATCH_SIZE - 1) / BATCH_SIZE;
        console2.log("Processing in %d batches of up to %d obligations each", totalBatches, BATCH_SIZE);

        for (uint256 i = 0; i < obligations.length; i += BATCH_SIZE) {
            uint256 end = i + BATCH_SIZE > obligations.length ? obligations.length : i + BATCH_SIZE;
            uint256 size = end - i;

            console2.log("");
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

                console2.log("  Borrower:", ob.borrower);
                console2.log("    Repayment:", ob.repaymentBps, "bps");
                console2.log("    Ending balance:", ob.endingBalance);
            }

            // Execute the appropriate call based on batch number
            if (i == 0) {
                // First batch: close cycle with end date
                console2.log("  [FIRST BATCH: Calling closeCycleAndPostObligations]");
                creditLine.closeCycleAndPostObligations(MARKET_ID, endDate, borrowers, repaymentBps, endingBalances);
            } else {
                // Subsequent batches: add to latest cycle
                console2.log("  [SUBSEQUENT BATCH: Calling addObligationsToLatestCycle]");
                creditLine.addObligationsToLatestCycle(MARKET_ID, borrowers, repaymentBps, endingBalances);
            }

            console2.log("  Batch %d executed successfully", (i / BATCH_SIZE) + 1);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("All obligations posted successfully!");
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
