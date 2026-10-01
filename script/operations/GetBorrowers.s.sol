// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

contract GetBorrowers is Script {
    // Mainnet Morpho contract
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;

    /// @notice Get borrowers from the last N days and save to JSON
    /// @param daysBack Number of days to look back
    function run(uint256 daysBack) external {
        uint256 currentBlock = block.number;
        uint256 blocksPerDay = 7200; // ~7200 blocks per day on mainnet
        uint256 fromBlock = currentBlock > (daysBack * blocksPerDay) ? currentBlock - (daysBack * blocksPerDay) : 0;

        string memory outputPath = string.concat("data/borrowers-", vm.toString(daysBack), "d.json");

        console2.log("=== Fetching Borrow Events ===");
        console2.log("Morpho Contract:", MORPHO_CREDIT);
        console2.log("Looking back", daysBack, "days");
        console2.log("From block:", fromBlock);
        console2.log("To block:", currentBlock);
        console2.log("");

        // Use cast command via FFI to get logs in JSON format
        string[] memory inputs = new string[](12);
        inputs[0] = "cast";
        inputs[1] = "logs";
        inputs[2] = "--from-block";
        inputs[3] = vm.toString(fromBlock);
        inputs[4] = "--to-block";
        inputs[5] = vm.toString(currentBlock);
        inputs[6] = "--address";
        inputs[7] = vm.toString(MORPHO_CREDIT);
        inputs[8] = "Borrow(bytes32,address,address,address,uint256,uint256)";
        inputs[9] = "--rpc-url";
        inputs[10] = vm.envString("ETH_RPC_URL");
        inputs[11] = "--json"; // Add JSON flag to get JSON output

        bytes memory result = vm.ffi(inputs);

        // Save raw JSON logs
        vm.writeFile(string.concat(outputPath, ".raw"), string(result));

        // Now extract unique borrowers using jq
        string[] memory jqCmd = new string[](3);
        jqCmd[0] = "bash";
        jqCmd[1] = "-c";
        jqCmd[2] = string.concat(
            "cat ",
            outputPath,
            ".raw | jq -r '[.[].topics[2] | ltrimstr(\"0x000000000000000000000000\") | \"0x\" + .] | unique' > ",
            outputPath
        );

        vm.ffi(jqCmd);

        // Count unique borrowers
        string[] memory countCmd = new string[](3);
        countCmd[0] = "bash";
        countCmd[1] = "-c";
        countCmd[2] = string.concat("cat ", outputPath, " | jq 'length'");

        bytes memory countResult = vm.ffi(countCmd);

        console2.log("Raw logs saved to:", string.concat(outputPath, ".raw"));
        console2.log("Unique borrowers saved to:", outputPath);
        console2.log("Number of unique borrowers:", string(countResult));
    }

    /// @notice Simple version that just prints the command to run
    /// @param daysBack Number of days to look back
    function getCommand(uint256 daysBack) external view {
        uint256 currentBlock = block.number;
        uint256 blocksPerDay = 7200;
        uint256 fromBlock = currentBlock > (daysBack * blocksPerDay) ? currentBlock - (daysBack * blocksPerDay) : 0;

        console2.log("Run this command to get borrowers from the last", daysBack, "days:");
        console2.log("");
        console2.log("# Step 1: Fetch logs in JSON format");
        console2.log("cast logs \\");
        console2.log("  --from-block", fromBlock, "\\");
        console2.log("  --to-block", currentBlock, "\\");
        console2.log("  --address 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc \\");
        console2.log('  "Borrow(bytes32,address,address,address,uint256,uint256)" \\');
        console2.log("  --rpc-url $ETH_RPC_URL --json > data/logs.json");
        console2.log("");
        console2.log("# Step 2: Extract unique borrower addresses");
        console2.log(
            "cat data/logs.json | jq -r '[.[].topics[2] | ltrimstr(\"0x000000000000000000000000\") | \"0x\" + .] | unique' > data/borrowers.json"
        );
        console2.log("");
        console2.log("# Step 3: Count unique borrowers");
        console2.log("echo \"Found $(cat data/borrowers.json | jq 'length') unique borrowers\"");
    }

    /// @notice Process existing raw logs file to extract unique borrowers
    /// @param inputFile Path to the raw logs file (YAML or JSON format)
    function processLogs(string memory inputFile) external {
        console2.log("=== Processing Logs File ===");
        console2.log("Input file:", inputFile);

        string memory outputFile = string.concat(inputFile, ".borrowers.json");

        // First check if it's JSON or YAML
        string[] memory checkCmd = new string[](3);
        checkCmd[0] = "bash";
        checkCmd[1] = "-c";
        checkCmd[2] = string.concat(
            "if head -1 ",
            inputFile,
            " | grep -q '^\\['; then echo 'json'; elif head -1 ",
            inputFile,
            " | grep -q '^- address:'; then echo 'yaml'; else echo 'unknown'; fi"
        );

        bytes memory formatResult = vm.ffi(checkCmd);
        string memory format = string(formatResult);

        if (keccak256(bytes(format)) == keccak256(bytes("yaml\n"))) {
            console2.log("Detected YAML format, converting...");

            // Convert YAML to JSON and extract borrowers
            string[] memory yamlCmd = new string[](3);
            yamlCmd[0] = "bash";
            yamlCmd[1] = "-c";
            yamlCmd[2] = string.concat(
                "cat ",
                inputFile,
                " | yq -o json '.' | jq -r '[.[].topics[2] | ltrimstr(\"0x000000000000000000000000\") | \"0x\" + .] | unique' > ",
                outputFile
            );

            vm.ffi(yamlCmd);
        } else {
            console2.log("Processing as JSON...");

            // Process JSON directly
            string[] memory jsonCmd = new string[](3);
            jsonCmd[0] = "bash";
            jsonCmd[1] = "-c";
            jsonCmd[2] = string.concat(
                "cat ",
                inputFile,
                " | jq -r '[.[].topics[2] | ltrimstr(\"0x000000000000000000000000\") | \"0x\" + .] | unique' > ",
                outputFile
            );

            vm.ffi(jsonCmd);
        }

        // Count results
        string[] memory countCmd = new string[](3);
        countCmd[0] = "bash";
        countCmd[1] = "-c";
        countCmd[2] = string.concat("cat ", outputFile, " | jq 'length'");

        bytes memory count = vm.ffi(countCmd);

        console2.log("Unique borrowers extracted to:", outputFile);
        console2.log("Total unique borrowers:", string(count));

        // Show first few
        string[] memory showCmd = new string[](3);
        showCmd[0] = "bash";
        showCmd[1] = "-c";
        showCmd[2] = string.concat("cat ", outputFile, " | jq -r '.[:5] | .[]'");

        bytes memory firstFew = vm.ffi(showCmd);
        console2.log("First few borrowers:");
        console2.log(string(firstFew));
    }
}
