// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {CreditLineDataLib} from "../utils/CreditLineDataLib.sol";

/// @title SetCreditLinesSafe Script
/// @notice Sets credit lines for borrowers via Safe multisig transaction
/// @dev Parses JSON file with credit line data and batches transactions for Safe
contract SetCreditLinesSafe is Script, SafeHelper {
    using CreditLineDataLib for *;

    /// @notice CreditLine contract address (mainnet)
    CreditLine private constant creditLine = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

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

        console2.log("=== Setting Credit Lines via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("CreditLine address:", address(creditLine));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));

        console2.log("Loaded", creditLines.length, "credit lines from JSON");

        // Validate all credit lines
        for (uint256 i = 0; i < creditLines.length; i++) {
            require(
                CreditLineDataLib.validateDrp(creditLines[i].drp),
                string.concat("Invalid DRP for borrower ", vm.toString(creditLines[i].borrower))
            );
            require(
                creditLines[i].vv > 0, string.concat("Invalid VV for borrower ", vm.toString(creditLines[i].borrower))
            );
            require(
                creditLines[i].credit > 0,
                string.concat("Invalid credit for borrower ", vm.toString(creditLines[i].borrower))
            );
        }

        console2.log("All credit lines validated successfully");
        console2.log("");

        // Process in batches
        uint256 totalBatches = (creditLines.length + BATCH_SIZE - 1) / BATCH_SIZE;
        console2.log("Processing in %d batches of up to %d credit lines each", totalBatches, BATCH_SIZE);

        for (uint256 i = 0; i < creditLines.length; i += BATCH_SIZE) {
            uint256 end = i + BATCH_SIZE > creditLines.length ? creditLines.length : i + BATCH_SIZE;
            uint256 size = end - i;

            console2.log("Batch %d - Processing borrowers %d to %d", (i / BATCH_SIZE) + 1, i, end - 1);

            // Prepare arrays for this batch
            Id[] memory ids = new Id[](size);
            address[] memory borrowers = new address[](size);
            uint256[] memory vvs = new uint256[](size);
            uint256[] memory credits = new uint256[](size);
            uint128[] memory drps = new uint128[](size);

            for (uint256 j = 0; j < size; j++) {
                CreditLineData memory cl = creditLines[i + j];
                ids[j] = MARKET_ID;
                borrowers[j] = cl.borrower;
                vvs[j] = cl.vv;
                credits[j] = cl.credit;
                drps[j] = cl.drp;

                console2.log("  -", vm.toString(cl.borrower));
                console2.log("    VV:", cl.vv);
                console2.log("    Credit:", cl.credit);
                console2.log("    DRP:", cl.drp);
            }

            // Encode the setCreditLines call
            bytes memory callData = abi.encodeCall(creditLine.setCreditLines, (ids, borrowers, vvs, credits, drps));

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
    /// @param jsonPath Path to JSON file containing credit line data
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
