// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

contract TestJsonParsing is Script {
    // Test struct - fields must be ordered to match alphabetized JSON fields
    // JSON fields alphabetically: borrower_address, credit, drp, vv
    struct CreditLineData {
        address borrower; // maps to "borrower_address" (1st alphabetically)
        uint256 credit; // maps to "credit" (2nd alphabetically)
        uint128 drp; // maps to "drp" (3rd alphabetically)
        uint256 vv; // maps to "vv" (4th alphabetically)
    }

    function run() external {
        console2.log("Testing JSON parsing...");

        // Read the JSON file
        string memory json = vm.readFile("data/credit-lines-example.json");
        console2.log("JSON content loaded");

        // Parse the JSON
        bytes memory data = vm.parseJson(json);
        console2.log("JSON parsed to bytes");
        console2.log("Bytes length:", data.length);

        // Try to decode directly
        CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));
        console2.log("Successfully decoded", creditLines.length, "credit lines");

        for (uint256 i = 0; i < creditLines.length; i++) {
            console2.log("Credit line", i);
            console2.log("  Borrower:", creditLines[i].borrower);
            console2.log("  VV:", creditLines[i].vv);
            console2.log("  Credit:", creditLines[i].credit);
            console2.log("  DRP:", creditLines[i].drp);
        }
    }
}
