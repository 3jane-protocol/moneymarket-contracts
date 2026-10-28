// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {CreditLineDataLib} from "../utils/CreditLineDataLib.sol";

/// @title SetCreditLinesDirect Script
/// @notice Sets credit lines for borrowers via direct execution (requires owner/OZD privileges)
/// @dev Parses JSON file with credit line data and executes setCreditLines directly
contract SetCreditLinesDirect is Script {
    using CreditLineDataLib for *;

    /// @notice Maximum number of credit lines to process in a single setCreditLines call
    uint256 private constant BATCH_SIZE = 50;

    /// @notice Struct for JSON parsing - fields ordered to match alphabetized JSON
    /// @dev JSON fields alphabetically: borrower_address, credit, drp, vv
    struct CreditLineData {
        address borrower; // maps to "borrower_address" (1st alphabetically)
        uint256 credit; // maps to "credit" (2nd alphabetically)
        uint128 drp; // maps to "drp" (3rd alphabetically)
        uint256 vv; // maps to "vv" (4th alphabetically)
    }

    /// @notice Main execution function
    /// @param jsonPath Path to JSON file containing credit line data
    function run(string memory jsonPath) external {
        // Load addresses from environment
        address creditLineAddress = vm.envAddress("CREDIT_LINE_ADDRESS");
        bytes32 marketIdBytes = vm.envBytes32("MARKET_ID");

        CreditLine creditLine = CreditLine(creditLineAddress);
        Id marketId = Id.wrap(marketIdBytes);

        console2.log("=== Setting Credit Lines (Direct Execution) ===");
        console2.log("CreditLine address:", creditLineAddress);
        console2.log("Market ID:", vm.toString(Id.unwrap(marketId)));
        console2.log("JSON file:", jsonPath);
        console2.log("");

        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Warning: Base fee is high, continuing anyway...");
        }

        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));

        console2.log("Loaded", creditLines.length, "credit lines from JSON");

        // Validate all credit lines
        uint256 totalCredit = 0;
        for (uint256 i = 0; i < creditLines.length; i++) {
            CreditLineData memory cl = creditLines[i];

            require(
                CreditLineDataLib.validateDrp(cl.drp),
                string.concat("Invalid DRP for borrower ", vm.toString(cl.borrower))
            );
            require(cl.vv > 0, string.concat("Invalid VV for borrower ", vm.toString(cl.borrower)));
            require(cl.credit > 0, string.concat("Invalid credit for borrower ", vm.toString(cl.borrower)));

            // Check LTV
            require(
                CreditLineDataLib.validateLtv(cl.credit, cl.vv),
                string.concat("LTV exceeds maximum for borrower ", vm.toString(cl.borrower))
            );

            totalCredit += cl.credit;
        }

        console2.log("All credit lines validated successfully");
        console2.log("Total credit to be assigned:", totalCredit);
        console2.log("");

        // Start broadcast for actual execution
        vm.startBroadcast();

        // Process in batches
        uint256 totalBatches = (creditLines.length + BATCH_SIZE - 1) / BATCH_SIZE;
        console2.log("Processing in %d batches of up to %d credit lines each", totalBatches, BATCH_SIZE);

        uint256 successfulBatches = 0;
        for (uint256 i = 0; i < creditLines.length; i += BATCH_SIZE) {
            uint256 end = i + BATCH_SIZE > creditLines.length ? creditLines.length : i + BATCH_SIZE;
            uint256 size = end - i;

            console2.log("");
            console2.log("Batch %d - Processing borrowers %d to %d", (i / BATCH_SIZE) + 1, i, end - 1);

            // Prepare arrays for this batch
            Id[] memory ids = new Id[](size);
            address[] memory borrowers = new address[](size);
            uint256[] memory vvs = new uint256[](size);
            uint256[] memory credits = new uint256[](size);
            uint128[] memory drps = new uint128[](size);

            for (uint256 j = 0; j < size; j++) {
                CreditLineData memory cl = creditLines[i + j];
                ids[j] = marketId;
                borrowers[j] = cl.borrower;
                vvs[j] = cl.vv;
                credits[j] = cl.credit;
                drps[j] = cl.drp;

                // Log details
                console2.log("  Borrower:", cl.borrower);
                console2.log("    VV: %d USDC", cl.vv / 1e6);
                console2.log("    Credit: %d USDC", cl.credit / 1e6);
                console2.log("    DRP (APR): %d bps", CreditLineDataLib.drpToApr(cl.drp));
            }

            // Execute setCreditLines for this batch
            try creditLine.setCreditLines(ids, borrowers, vvs, credits, drps) {
                console2.log("  [SUCCESS] Batch %d executed successfully", (i / BATCH_SIZE) + 1);
                successfulBatches++;
            } catch Error(string memory reason) {
                console2.log("  [FAILED] Batch %d failed: %s", (i / BATCH_SIZE) + 1, reason);
            } catch {
                console2.log("  [FAILED] Batch %d failed with unknown error", (i / BATCH_SIZE) + 1);
            }
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Execution Complete ===");
        console2.log("Successful batches: %d / %d", successfulBatches, totalBatches);
        console2.log("Total borrowers processed: %d", creditLines.length);
    }

    /// @notice Dry run without broadcasting
    /// @param jsonPath Path to JSON file containing credit line data
    function dryRun(string memory jsonPath) external {
        // Load addresses from environment
        address creditLineAddress = vm.envAddress("CREDIT_LINE_ADDRESS");
        bytes32 marketIdBytes = vm.envBytes32("MARKET_ID");

        CreditLine creditLine = CreditLine(creditLineAddress);
        Id marketId = Id.wrap(marketIdBytes);

        console2.log("=== DRY RUN - Credit Lines ===");
        console2.log("CreditLine address:", creditLineAddress);
        console2.log("Market ID:", vm.toString(Id.unwrap(marketId)));
        console2.log("JSON file:", jsonPath);
        console2.log("");

        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));

        console2.log("Loaded", creditLines.length, "credit lines from JSON");
        console2.log("");

        // Display all credit lines
        uint256 totalCredit = 0;
        uint256 totalVV = 0;

        for (uint256 i = 0; i < creditLines.length; i++) {
            CreditLineData memory cl = creditLines[i];
            console2.log("Borrower %d: %s", i + 1, cl.borrower);
            console2.log("  VV: %d USDC", cl.vv / 1e6);
            console2.log("  Credit: %d USDC", cl.credit / 1e6);
            console2.log("  LTV: %d bps", (cl.credit * 10000) / cl.vv);
            console2.log("  DRP (APR): %d bps", CreditLineDataLib.drpToApr(cl.drp));

            totalCredit += cl.credit;
            totalVV += cl.vv;
        }

        console2.log("");
        console2.log("=== Summary ===");
        console2.log("Total borrowers: %d", creditLines.length);
        console2.log("Total VV: %d USDC", totalVV / 1e6);
        console2.log("Total credit: %d USDC", totalCredit / 1e6);
        console2.log("Average LTV: %d bps", (totalCredit * 10000) / totalVV);
    }

    /// @notice Check if base fee is acceptable
    /// @return True if base fee is below limit
    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee high: %d gwei (limit: %d gwei)", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        return true;
    }
}
