// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

contract DeployProtocolConfig is Script {
    function run() external returns (address proxy, address implementation) {
        address timelockAddress = vm.envAddress("TIMELOCK_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        
        vm.startBroadcast();
        
        // Deploy Transparent Proxy with Timelock as ProxyAdmin owner
        proxy = Upgrades.deployTransparentProxy(
            "ProtocolConfig.sol",
            timelockAddress, // Timelock owns the ProxyAdmin
            abi.encodeCall(ProtocolConfig.initialize, (owner)) // Owner will be the protocol owner
        );
        
        // Get implementation address for verification
        implementation = Upgrades.getImplementationAddress(proxy);
        
        console.log("ProtocolConfig Proxy deployed at:", proxy);
        console.log("ProtocolConfig Implementation at:", implementation);
        console.log("ProxyAdmin owner: TimelockController");
        console.log("ProtocolConfig owner:", owner);
        
        vm.stopBroadcast();
        
        return (proxy, implementation);
    }
}