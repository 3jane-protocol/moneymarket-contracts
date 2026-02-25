// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {stdJson} from "forge-std/StdJson.sol";

interface IUSD3Whitelist {
    function setWhitelist(address _user, bool _allowed) external;
    function whitelist(address user) external view returns (bool);
}

contract WhitelistUSD3Safe is Script, SafeHelper {
    using stdJson for string;

    // Mainnet USD3 address
    address constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    // Struct to match JSON format, alphabetized
    struct WhitelistEntry {
        bool allowed;
        address user;
    }

    function run(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        console2.log("Send to Safe:", send);

        // Read JSON file
        string memory json = vm.readFile(jsonPath);

        // Parse whitelist entries
        bytes memory data = vm.parseJson(json);
        WhitelistEntry[] memory entries = abi.decode(data, (WhitelistEntry[]));

        console2.log("=== USD3 Whitelist Update via Safe ===");
        console2.log("USD3 Address: %s", USD3);
        console2.log("Total entries: %d", entries.length);
        console2.log("");

        IUSD3Whitelist usd3 = IUSD3Whitelist(USD3);

        // Check current whitelist status and prepare updates
        console2.log("Checking current whitelist status...");
        uint256 toAdd = 0;
        uint256 toRemove = 0;
        uint256 skipped = 0;

        // Arrays to track which entries need updates
        bool[] memory needsUpdate = new bool[](entries.length);

        // Check each entry and determine if update is needed
        for (uint256 i = 0; i < entries.length; i++) {
            bool isWhitelisted = usd3.whitelist(entries[i].user);

            // Only update if state needs to change
            if (isWhitelisted != entries[i].allowed) {
                needsUpdate[i] = true;
                if (entries[i].allowed) {
                    toAdd++;
                } else {
                    toRemove++;
                }

                // Log first few changes
                if ((toAdd + toRemove) <= 5) {
                    console2.log(
                        "  %s: %s -> %s",
                        entries[i].user,
                        isWhitelisted ? "Whitelisted" : "Not whitelisted",
                        entries[i].allowed ? "Add" : "Remove"
                    );
                }
            } else {
                skipped++;
                // Log first few skipped
                if (skipped <= 3) {
                    console2.log(
                        "  %s: Already %s (skipping)",
                        entries[i].user,
                        isWhitelisted ? "whitelisted" : "not whitelisted"
                    );
                }
            }
        }

        if ((toAdd + toRemove) > 5) {
            console2.log("  ... and %d more changes", (toAdd + toRemove) - 5);
        }
        if (skipped > 3) {
            console2.log("  ... and %d more skipped", skipped - 3);
        }

        console2.log("");
        console2.log("Summary:");
        console2.log("  To add: %d addresses", toAdd);
        console2.log("  To remove: %d addresses", toRemove);
        console2.log("  Skipped (already correct): %d addresses", skipped);
        console2.log("");

        // Only proceed if there are changes to make
        if (toAdd + toRemove == 0) {
            console2.log("No changes needed - all addresses already have correct whitelist status");
            return;
        }

        // Prepare batch transactions only for entries that need updates
        console2.log("Preparing batch transaction for %d updates...", toAdd + toRemove);

        uint256 updateCount = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            if (!needsUpdate[i]) continue;

            bytes memory callData = abi.encodeCall(usd3.setWhitelist, (entries[i].user, entries[i].allowed));

            addToBatch(USD3, callData);

            // Log first few updates
            if (updateCount < 3) {
                console2.log("  %s %s", entries[i].allowed ? "Adding" : "Removing", entries[i].user);
            }
            updateCount++;
        }

        if (updateCount > 3) {
            console2.log("  ... and %d more", updateCount - 3);
        }

        console2.log("");
        console2.log("All addresses prepared for batch transaction");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Get other signers to approve the transaction");
            console2.log("2. Execute once threshold is reached");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }
}
