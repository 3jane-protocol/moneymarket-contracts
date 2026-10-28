// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position, Market} from "../../src/interfaces/IMorpho.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/**
 * @title GetAllBorrowerPositions
 * @notice Gets all borrower positions by scanning Borrow events and outputting current balances
 * @dev Scans from deployment block to current to find all borrowers
 *
 * Usage:
 *   forge script script/operations/GetAllBorrowerPositions.s.sol:GetAllBorrowerPositions --sig "run()" --rpc-url
 * $RPC_URL
 *   forge script script/operations/GetAllBorrowerPositions.s.sol:GetAllBorrowerPositions --sig "run(string)"
 * "data/all-borrowers.json" --rpc-url $RPC_URL
 */
contract GetAllBorrowerPositions is Script {
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /// @notice MorphoCredit contract address (mainnet)
    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Deployment block (when MorphoCredit was deployed)
    uint256 private constant FROM_BLOCK = 23241534;

    /// @notice Struct for output format
    struct BorrowerPosition {
        address address_;
        uint256 amount;
    }

    /**
     * @notice Main execution function with default output path
     */
    function run() external {
        string memory outputPath = string.concat("data/borrower-positions-", vm.toString(block.timestamp), ".json");
        _run(outputPath);
    }

    /**
     * @notice Main execution function with custom output path
     * @param outputPath Path for output JSON file
     */
    function run(string memory outputPath) external {
        _run(outputPath);
    }

    /**
     * @notice Internal execution function
     */
    function _run(string memory outputPath) internal {
        console2.log("=== Get All Borrower Positions ===");
        console2.log("MorphoCredit:", MORPHO_CREDIT);
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("Scanning from block:", FROM_BLOCK);
        console2.log("Current block:", block.number);
        console2.log("");

        // Get Borrow event signature
        bytes32 borrowEventSig = keccak256("Borrow(bytes32,address,address,address,uint256,uint256)");

        // Set up topics for the event filter
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = borrowEventSig;
        topics[1] = bytes32(Id.unwrap(MARKET_ID)); // Filter for our specific market

        console2.log("Fetching Borrow events...");

        // Query logs
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(FROM_BLOCK, block.number, MORPHO_CREDIT, topics);

        console2.log("Found %d Borrow events", logs.length);
        console2.log("");

        // Track unique borrowers
        address[] memory uniqueBorrowers = new address[](logs.length);
        uint256 uniqueCount = 0;

        // Extract unique borrowers from events
        for (uint256 i = 0; i < logs.length; i++) {
            // Decode event data: (onBehalf, receiver, assets, shares)
            // We want onBehalf (the actual borrower)
            address onBehalf = address(uint160(uint256(logs[i].topics[2])));

            // Check if we've seen this borrower before
            bool seen = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueBorrowers[j] == onBehalf) {
                    seen = true;
                    break;
                }
            }

            if (!seen) {
                uniqueBorrowers[uniqueCount] = onBehalf;
                uniqueCount++;
            }
        }

        console2.log("Found %d unique borrowers", uniqueCount);
        console2.log("");

        // Accrue premiums for all borrowers
        console2.log("Accruing premiums for accurate balances...");
        address[] memory borrowersToAccrue = new address[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            borrowersToAccrue[i] = uniqueBorrowers[i];
        }
        IMorphoCredit(MORPHO_CREDIT).accruePremiumsForBorrowers(MARKET_ID, borrowersToAccrue);

        // Get market state for share conversion
        IMorpho morpho = IMorpho(MORPHO_CREDIT);
        Market memory marketState = morpho.market(MARKET_ID);

        // Get positions for all unique borrowers
        BorrowerPosition[] memory positions = new BorrowerPosition[](uniqueCount);
        uint256 activePositions = 0;
        uint256 totalDebt = 0;

        console2.log("Fetching current positions...");
        console2.log("");

        for (uint256 i = 0; i < uniqueCount; i++) {
            address borrower = uniqueBorrowers[i];

            // Get position
            Position memory pos = morpho.position(MARKET_ID, borrower);

            // Convert borrowShares to borrowAssets
            uint256 borrowAssets =
                uint256(pos.borrowShares).toAssetsUp(marketState.totalBorrowAssets, marketState.totalBorrowShares);

            // Only include borrowers with non-zero positions
            if (borrowAssets > 0) {
                positions[activePositions] = BorrowerPosition({address_: borrower, amount: borrowAssets});
                activePositions++;
                totalDebt += borrowAssets;

                console2.log("  %s: %d", borrower, borrowAssets);
            }
        }

        console2.log("");
        console2.log("=== Summary ===");
        console2.log("Total unique borrowers: %d", uniqueCount);
        console2.log("Active borrowers: %d", activePositions);
        console2.log("Total debt: %d", totalDebt);
        console2.log("");

        // Write output JSON
        _writeOutput(positions, activePositions, outputPath);

        console2.log("Output written to: %s", outputPath);
    }

    /**
     * @notice Write positions to JSON file
     * @param positions Array of borrower positions
     * @param count Number of active positions to write
     * @param outputPath Path for output file
     */
    function _writeOutput(BorrowerPosition[] memory positions, uint256 count, string memory outputPath) private {
        string memory jsonOutput = "[";

        for (uint256 i = 0; i < count; i++) {
            if (i > 0) jsonOutput = string.concat(jsonOutput, ",");

            jsonOutput = string.concat(jsonOutput, "\n  {");
            jsonOutput = string.concat(jsonOutput, '\n    "address": "', vm.toString(positions[i].address_), '",');
            jsonOutput = string.concat(jsonOutput, '\n    "amount": ', vm.toString(positions[i].amount));
            jsonOutput = string.concat(jsonOutput, "\n  }");
        }

        jsonOutput = string.concat(jsonOutput, "\n]");

        // Write to file
        vm.writeFile(outputPath, jsonOutput);
    }
}
