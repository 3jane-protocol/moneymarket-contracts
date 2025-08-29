// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

contract TestJsonParsing2 is Script {
    // Try different struct configurations to debug

    // Option 1: All fields as address/uint256
    struct CreditLineData1 {
        address borrower_address;
        uint256 credit;
        uint256 drp;
        uint256 vv;
    }

    // Option 2: Match exact JSON field names with types
    struct CreditLineData2 {
        address borrower_address;
        uint256 credit;
        uint128 drp;
        uint256 vv;
    }

    function run() external view {
        console2.log("Testing JSON parsing variations...");

        // Read the JSON file
        string memory json = vm.readFile("data/credit-lines-example.json");

        // Parse the JSON
        bytes memory data = vm.parseJson(json);
        console2.log("Parsed bytes length:", data.length);

        // Log the hex representation to understand the structure
        console2.logBytes(data);

        // Try option 1
        console2.log("\nTrying option 1 (all uint256):");
        try this.tryOption1(data) returns (bool success) {
            if (success) console2.log("Option 1 succeeded!");
        } catch {
            console2.log("Option 1 failed");
        }

        // Try option 2
        console2.log("\nTrying option 2 (uint128 drp):");
        try this.tryOption2(data) returns (bool success) {
            if (success) console2.log("Option 2 succeeded!");
        } catch {
            console2.log("Option 2 failed");
        }
    }

    function tryOption1(bytes memory data) external pure returns (bool) {
        CreditLineData1[] memory creditLines = abi.decode(data, (CreditLineData1[]));
        console2.log("Option 1: Decoded", creditLines.length, "credit lines");
        return true;
    }

    function tryOption2(bytes memory data) external pure returns (bool) {
        CreditLineData2[] memory creditLines = abi.decode(data, (CreditLineData2[]));
        console2.log("Option 2: Decoded", creditLines.length, "credit lines");
        return true;
    }
}
