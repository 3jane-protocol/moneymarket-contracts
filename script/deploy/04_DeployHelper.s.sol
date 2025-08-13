// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Helper} from "../../src/Helper.sol";

contract DeployHelper is Script {
    function run() external returns (address) {
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        address usd3 = vm.envAddress("USD3_ADDRESS");
        address susd3 = vm.envAddress("SUSD3_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address wausdc = vm.envAddress("WAUSDC_ADDRESS");
        
        vm.startBroadcast();
        
        Helper helper = new Helper(morpho, usd3, susd3, usdc, wausdc);
        
        console.log("Helper deployed at:", address(helper));
        console.log("MORPHO:", morpho);
        console.log("USD3:", usd3);
        console.log("sUSD3:", susd3);
        console.log("USDC:", usdc);
        console.log("WAUSDC:", wausdc);
        
        vm.stopBroadcast();
        
        return address(helper);
    }
}