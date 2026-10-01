// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CreditLine} from "../../src/CreditLine.sol";

contract DeployCreditLine is Script {
    function run() external returns (address) {
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address ozd = address(0x1);
        address mm = vm.envAddress("MARKDOWN_MANAGER_ADDRESS");
        address prover = vm.envOr("PROVER_ADDRESS", address(0)); // Optional

        vm.startBroadcast();

        CreditLine creditLine = new CreditLine(morpho, owner, ozd, mm, prover);

        console.log("CreditLine deployed at:", address(creditLine));
        console.log("MORPHO:", morpho);
        console.log("Owner:", owner);
        console.log("OZD:", ozd);
        console.log("Markdown Manager:", mm);
        console.log("Prover:", prover);

        vm.stopBroadcast();

        return address(creditLine);
    }
}
