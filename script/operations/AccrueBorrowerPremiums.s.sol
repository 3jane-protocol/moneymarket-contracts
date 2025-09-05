// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IMorphoCredit, Id} from "../../src/interfaces/IMorpho.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract AccrueBorrowerPremiums is Script {
    using stdJson for string;

    // Mainnet addresses
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;

    // Market ID for USDC market
    Id constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    struct BorrowerList {
        address[] borrowers;
    }

    function run(string memory jsonPath, uint256 batchSize) public {
        // Read JSON file
        string memory json = vm.readFile(jsonPath);

        // Parse borrower addresses
        address[] memory borrowers = abi.decode(json.parseRaw("."), (address[]));

        console2.log("=== Accruing Premiums for Borrowers ===");
        console2.log("Total borrowers: %d", borrowers.length);
        console2.log("Batch size: %d", batchSize);
        console2.log("");

        IMorphoCredit morpho = IMorphoCredit(MORPHO_CREDIT);

        // Process in batches if specified
        if (batchSize == 0 || batchSize >= borrowers.length) {
            // Single batch
            _accrueBatch(morpho, borrowers, 0, borrowers.length);
        } else {
            // Multiple batches
            uint256 numBatches = (borrowers.length + batchSize - 1) / batchSize;
            console2.log("Processing in %d batches", numBatches);
            console2.log("");

            for (uint256 i = 0; i < numBatches; i++) {
                uint256 start = i * batchSize;
                uint256 end = start + batchSize;
                if (end > borrowers.length) {
                    end = borrowers.length;
                }

                address[] memory batch = new address[](end - start);
                for (uint256 j = 0; j < batch.length; j++) {
                    batch[j] = borrowers[start + j];
                }

                _accrueBatch(morpho, batch, i + 1, numBatches);
            }
        }

        console2.log("");
        console2.log("=== Premium Accrual Complete ===");
    }

    function _accrueBatch(IMorphoCredit morpho, address[] memory borrowers, uint256 batchNum, uint256 totalBatches)
        private
    {
        if (totalBatches > 1) {
            console2.log("Processing batch %d/%d (%d borrowers)", batchNum, totalBatches, borrowers.length);
        }

        uint256 gasBefore = gasleft();

        vm.broadcast();
        morpho.accruePremiumsForBorrowers(MARKET_ID, borrowers);

        uint256 gasUsed = gasBefore - gasleft();
        console2.log("  Gas used: %d", gasUsed);
        console2.log("  Gas per borrower: %d", gasUsed / borrowers.length);

        // Log a few sample addresses from this batch
        uint256 samplesToShow = borrowers.length < 3 ? borrowers.length : 3;
        for (uint256 i = 0; i < samplesToShow; i++) {
            console2.log("  Accrued for: %s", borrowers[i]);
        }
        if (borrowers.length > samplesToShow) {
            console2.log("  ... and %d more", borrowers.length - samplesToShow);
        }
    }

    // Convenience function for running with default batch size
    function run(string memory jsonPath) public {
        run(jsonPath, 0); // 0 means single batch
    }
}
