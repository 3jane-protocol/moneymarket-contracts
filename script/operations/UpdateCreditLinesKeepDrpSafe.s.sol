// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {IMorpho, IMorphoCredit, Id, Position} from "../../src/interfaces/IMorpho.sol";
import {CreditLineDataLib} from "../utils/CreditLineDataLib.sol";

/// @title UpdateCreditLinesKeepDrpSafe Script
/// @notice Updates credit lines based on waUSDC PPS adjustment while keeping current DRPs
/// @dev Reads new credit/vv from JSON but preserves on-chain DRP values
contract UpdateCreditLinesKeepDrpSafe is Script, SafeHelper {
    using CreditLineDataLib for *;

    /// @notice MorphoCredit contract address (mainnet)
    address private constant MORPHO_ADDRESS = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    IMorpho private constant morpho = IMorpho(MORPHO_ADDRESS);
    IMorphoCredit private constant morphoCredit = IMorphoCredit(MORPHO_ADDRESS);
    ProtocolConfig private constant config = ProtocolConfig(0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E);

    /// @notice CreditLine contract address (mainnet)
    CreditLine private constant creditLine = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Struct for JSON parsing - fields ordered alphabetically
    struct CreditLineData {
        address borrower_address; // 1st alphabetically
        uint256 credit; // 2nd alphabetically
        uint128 drp; // 3rd alphabetically (will be ignored)
        uint256 vv; // 4th alphabetically
    }

    /// @notice Main execution function
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Updating Credit Lines (Keep Current DRPs) via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("MorphoCredit address:", MORPHO_ADDRESS);
        console2.log("CreditLine address:", address(creditLine));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Read and parse JSON
        string memory jsonPath = "data/credit-lines-10-28-2025.json";
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        CreditLineData[] memory newCreditLines = abi.decode(data, (CreditLineData[]));

        uint256 minCredit = config.getCreditLineConfig().minCreditLine;

        console2.log("Loaded", newCreditLines.length, "credit lines from", jsonPath);
        console2.log("");

        // Prepare arrays for setCreditLines
        Id[] memory ids = new Id[](newCreditLines.length);
        address[] memory borrowers = new address[](newCreditLines.length);
        uint256[] memory vvs = new uint256[](newCreditLines.length);
        uint256[] memory credits = new uint256[](newCreditLines.length);
        uint128[] memory drps = new uint128[](newCreditLines.length);

        uint256 totalCurrentCredit = 0;
        uint256 totalNewCredit = 0;

        console2.log("=== Credit Line Adjustments ===");
        console2.log("");

        // Process each credit line
        for (uint256 i = 0; i < newCreditLines.length; i++) {
            address borrower = newCreditLines[i].borrower_address;

            // Get current on-chain values
            Position memory pos = morpho.position(MARKET_ID, borrower);
            uint256 currentCredit = pos.collateral; // Credit line stored as collateral

            // Get current DRP (2nd return value)
            (, uint128 currentDrp,) = morphoCredit.borrowerPremium(MARKET_ID, borrower);

            uint256 newCredit = newCreditLines[i].credit;
            uint256 newVv = newCreditLines[i].vv;

            // Verify credit line is decreasing
            if (newCredit >= currentCredit && currentCredit > 0) {
                console2.log("ERROR: Credit would increase or stay same for", borrower);
                console2.log("  Current:", currentCredit / 1e6, "waUSDC");
                console2.log("  New:    ", newCredit / 1e6, "waUSDC");
                console2.log("  Skipping ... \n");
                newCredit = currentCredit;
            }
            if (newCredit < minCredit) {
                newCredit = minCredit;
            }

            // Calculate reduction percentage
            uint256 reductionBps = 0;
            if (currentCredit > 0) {
                reductionBps = ((currentCredit - newCredit) * 10000) / currentCredit;
            }

            console2.log("Borrower:", borrower);
            console2.log("  Current credit:", currentCredit / 1e6, "waUSDC");
            console2.log("  New credit:    ", newCredit / 1e6, "waUSDC");
            // Format reduction percentage
            string memory reductionStr =
                string(abi.encodePacked(vm.toString(reductionBps / 100), ".", vm.toString(reductionBps % 100), "%"));
            console2.log("  Reduction:     ", reductionStr);
            console2.log("  DRP (kept):    ", currentDrp);
            console2.log("  New VV:        ", newVv);
            console2.log("");

            // Populate arrays
            ids[i] = MARKET_ID;
            borrowers[i] = borrower;
            vvs[i] = newVv;
            credits[i] = newCredit;
            drps[i] = currentDrp; // KEEP CURRENT DRP

            totalCurrentCredit += currentCredit;
            totalNewCredit += newCredit;
        }

        // Calculate overall reduction
        uint256 overallReductionBps = 0;
        if (totalCurrentCredit > 0) {
            overallReductionBps = ((totalCurrentCredit - totalNewCredit) * 10000) / totalCurrentCredit;
        }

        console2.log("=== Summary ===");
        console2.log("Total current credit:", totalCurrentCredit / 1e6, "USDC");
        console2.log("Total new credit:    ", totalNewCredit / 1e6, "USDC");
        // Format overall reduction percentage
        string memory overallReductionStr = string(
            abi.encodePacked(vm.toString(overallReductionBps / 100), ".", vm.toString(overallReductionBps % 100), "%")
        );
        console2.log("Overall reduction:   ", overallReductionStr);
        console2.log("(Should match waUSDC PPS appreciation)");
        console2.log("");

        // Create the setCreditLines call
        bytes memory setCreditLinesCall =
            abi.encodeCall(CreditLine.setCreditLines, (ids, borrowers, vvs, credits, drps));

        // Add to batch
        addToBatch(address(creditLine), setCreditLinesCall);

        console2.log("=== Batch Summary ===");
        console2.log("Operation: CreditLine.setCreditLines");
        console2.log("Number of credit lines: ", newCreditLines.length);
        console2.log("All DRPs preserved from current on-chain values");
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
            console2.log("3. All", newCreditLines.length, "credit lines will be updated atomically");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     */
    function run() external {
        this.run(false);
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
