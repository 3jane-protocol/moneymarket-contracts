// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AdaptiveCurveIrm} from "../../src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";

contract DeployAdaptiveCurveIrm is Script {
    function run() external returns (address proxy, address implementation) {
        address timelockAddress = vm.envAddress("TIMELOCK_ADDRESS");
        address morphoAddress = vm.envAddress("MORPHO_ADDRESS");
        
        vm.startBroadcast();
        
        // First deploy the implementation to pass its address to constructor
        // AdaptiveCurveIrm constructor requires morpho address
        AdaptiveCurveIrm irmImpl = new AdaptiveCurveIrm(morphoAddress);
        
        // Deploy Transparent Proxy with Timelock as ProxyAdmin owner
        // Note: We need to deploy the proxy manually since AdaptiveCurveIrm has a constructor with args
        proxy = Upgrades.deployTransparentProxy(
            address(irmImpl),
            timelockAddress, // Timelock owns the ProxyAdmin
            abi.encodeCall(AdaptiveCurveIrm.initialize, ())
        );
        
        // Get implementation address for verification
        implementation = address(irmImpl);
        
        console.log("AdaptiveCurveIrm Proxy deployed at:", proxy);
        console.log("AdaptiveCurveIrm Implementation at:", implementation);
        console.log("ProxyAdmin owner: TimelockController");
        console.log("Morpho address:", morphoAddress);
        
        vm.stopBroadcast();
        
        return (proxy, implementation);
    }
}