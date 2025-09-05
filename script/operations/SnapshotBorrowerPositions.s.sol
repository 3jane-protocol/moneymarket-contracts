// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position, Market} from "../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

/// @title SnapshotBorrowerPositions Script
/// @notice Snapshots borrower positions at a specific timestamp for cycle obligation processing
/// @dev Uses timestamp-to-block heuristic and accrues premiums for accurate balances
contract SnapshotBorrowerPositions is Script {
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /// @notice CreditLine contract address (mainnet) - same as CloseCycleSafe
    address private constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;

    /// @notice MorphoCredit contract address (retrieved from CreditLine)
    IMorphoCredit private immutable morphoCredit;

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Average block time in seconds (Ethereum mainnet)
    uint256 private constant AVG_BLOCK_TIME = 12;

    constructor() {
        morphoCredit = IMorphoCredit(ICreditLine(CREDIT_LINE).MORPHO());
    }

    /// @notice Struct for input borrowers
    struct BorrowerInput {
        address borrower;
    }

    /// @notice Struct for output obligations (matches CloseCycleSafe format)
    struct ObligationData {
        address borrower;
        uint256 endingBalance;
        uint256 repaymentBps;
    }

    /// @notice Main execution function
    /// @param borrowersJson Path to JSON file containing borrower addresses
    /// @param targetTimestamp Unix timestamp for the snapshot
    /// @param repaymentBps Default repayment percentage in basis points (e.g., 500 = 5%)
    /// @param outputPath Path for output JSON file
    function run(string memory borrowersJson, uint256 targetTimestamp, uint256 repaymentBps, string memory outputPath)
        external
    {
        _runSnapshot(borrowersJson, targetTimestamp, repaymentBps, outputPath);
    }

    /// @notice Internal execution function
    function _runSnapshot(
        string memory borrowersJson,
        uint256 targetTimestamp,
        uint256 repaymentBps,
        string memory outputPath
    ) internal {
        console2.log("=== Snapshot Borrower Positions ===");
        console2.log("Target timestamp:", targetTimestamp);
        console2.log("Default repayment:", repaymentBps, "bps");
        console2.log("");

        // Find and fork at the target block
        uint256 targetBlock = _findBlockForTimestamp(targetTimestamp);

        // Report actual vs target timestamp
        console2.log("Target timestamp:  %d", targetTimestamp);
        console2.log("Actual timestamp:  %d", block.timestamp);
        int256 timeDiff = int256(block.timestamp) - int256(targetTimestamp);
        if (timeDiff >= 0) {
            console2.log("Time difference:   +%d seconds", uint256(timeDiff));
        } else {
            console2.log("Time difference:   -%d seconds", uint256(-timeDiff));
        }
        console2.log("");

        // Read borrowers from JSON
        string memory json = vm.readFile(borrowersJson);
        bytes memory data = vm.parseJson(json);
        BorrowerInput[] memory borrowers = abi.decode(data, (BorrowerInput[]));

        console2.log("Processing %d borrowers...", borrowers.length);
        console2.log("");

        // Prepare obligations array
        ObligationData[] memory obligations = new ObligationData[](borrowers.length);
        uint256 totalDebt = 0;
        uint256 activeBorrowers = 0;

        // Get market state for share conversion
        IMorpho morpho = IMorpho(address(morphoCredit));
        Market memory marketState = morpho.market(MARKET_ID);

        // Process each borrower
        for (uint256 i = 0; i < borrowers.length; i++) {
            address borrower = borrowers[i].borrower;

            // Accrue premium to get accurate balance at this block
            morphoCredit.accrueBorrowerPremium(MARKET_ID, borrower);

            // Get position
            Position memory pos = morpho.position(MARKET_ID, borrower);

            // Convert borrowShares to borrowAssets
            uint256 borrowAssets =
                uint256(pos.borrowShares).toAssetsUp(marketState.totalBorrowAssets, marketState.totalBorrowShares);

            // Store obligation data
            obligations[i] =
                ObligationData({borrower: borrower, endingBalance: borrowAssets, repaymentBps: repaymentBps});

            if (borrowAssets > 0) {
                totalDebt += borrowAssets;
                activeBorrowers++;
                console2.log("  %s:", borrower);
                console2.log("    Borrow shares:  %d", pos.borrowShares);
                console2.log("    Borrow assets:  %d", borrowAssets);
                console2.log("    Repayment:      %d bps", repaymentBps);
            }
        }

        console2.log("");
        console2.log("=== Summary ===");
        console2.log("Total borrowers:    %d", borrowers.length);
        console2.log("Active borrowers:   %d", activeBorrowers);
        console2.log("Total debt:         %d", totalDebt);
        console2.log("");

        // Write output JSON
        _writeOutput(obligations, outputPath);

        console2.log("Output written to: %s", outputPath);
    }

    /// @notice Alternative entry point with default output path
    function run(string memory borrowersJson, uint256 targetTimestamp, uint256 repaymentBps) external {
        string memory outputPath = string.concat("data/snapshot-", vm.toString(targetTimestamp), ".json");
        _runSnapshot(borrowersJson, targetTimestamp, repaymentBps, outputPath);
    }

    /// @notice Find block number for a given timestamp using heuristic
    /// @param targetTimestamp Unix timestamp to find block for
    /// @return targetBlock The block number closest to the timestamp
    function _findBlockForTimestamp(uint256 targetTimestamp) private returns (uint256 targetBlock) {
        // Get current state (already forked via command line)
        uint256 currentBlock = block.number;
        uint256 currentTimestamp = block.timestamp;

        console2.log("Current block:     %d", currentBlock);
        console2.log("Current timestamp: %d", currentTimestamp);

        // Calculate block delta using average block time
        uint256 timeDelta;
        bool goingBack;

        if (currentTimestamp > targetTimestamp) {
            timeDelta = currentTimestamp - targetTimestamp;
            goingBack = true;
        } else {
            timeDelta = targetTimestamp - currentTimestamp;
            goingBack = false;
        }

        uint256 blockDelta = timeDelta / AVG_BLOCK_TIME;

        // Calculate target block
        if (goingBack) {
            targetBlock = currentBlock - blockDelta;
            console2.log("Going back %d blocks", blockDelta);
        } else {
            targetBlock = currentBlock + blockDelta;
            console2.log("Going forward %d blocks", blockDelta);
        }

        console2.log("Target block:      %d", targetBlock);

        // Roll to the target block
        vm.rollFork(targetBlock);

        return targetBlock;
    }

    /// @notice Write obligations to JSON file
    /// @param obligations Array of obligation data
    /// @param outputPath Path for output file
    function _writeOutput(ObligationData[] memory obligations, string memory outputPath) private {
        // Build JSON string manually to ensure alphabetical field ordering
        // Required format: borrower, endingBalance, repaymentBps (alphabetical)
        string memory jsonOutput = "[";

        for (uint256 i = 0; i < obligations.length; i++) {
            if (i > 0) jsonOutput = string.concat(jsonOutput, ",");

            jsonOutput = string.concat(jsonOutput, "\n  {");
            jsonOutput = string.concat(jsonOutput, '\n    "borrower": "', vm.toString(obligations[i].borrower), '",');
            jsonOutput =
                string.concat(jsonOutput, '\n    "endingBalance": ', vm.toString(obligations[i].endingBalance), ",");
            jsonOutput = string.concat(jsonOutput, '\n    "repaymentBps": ', vm.toString(obligations[i].repaymentBps));
            jsonOutput = string.concat(jsonOutput, "\n  }");
        }

        jsonOutput = string.concat(jsonOutput, "\n]");

        // Write to file
        vm.writeFile(outputPath, jsonOutput);
    }
}
