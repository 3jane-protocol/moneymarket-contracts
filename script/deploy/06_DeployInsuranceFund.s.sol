// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {InsuranceFund} from "../../src/InsuranceFund.sol";

contract DeployInsuranceFund is Script {
    function run() external returns (address) {
        address creditLine = vm.envAddress("CREDIT_LINE_ADDRESS");

        vm.startBroadcast();

        InsuranceFund insuranceFund = new InsuranceFund(creditLine);

        console.log("InsuranceFund deployed at:", address(insuranceFund));
        console.log("CreditLine:", creditLine);

        vm.stopBroadcast();

        return address(insuranceFund);
    }
}
