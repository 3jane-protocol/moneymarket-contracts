// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {MorphoCredit} from "../../src/MorphoCredit.sol";

contract DeployMorphoCredit is Script {
    function run() external returns (address proxy, address implementation) {
        address timelockAddress = vm.envAddress("TIMELOCK_ADDRESS");
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");
        address owner = vm.envAddress("OWNER_ADDRESS");
        
        vm.startBroadcast();
        
        // First deploy the implementation to pass its address to constructor
        // MorphoCredit constructor requires protocolConfig
        MorphoCredit morphoImpl = new MorphoCredit(protocolConfig);
        
        // Deploy Transparent Proxy with Timelock as ProxyAdmin owner
        // Note: We need to deploy the proxy manually since MorphoCredit has a constructor with args
        proxy = Upgrades.deployTransparentProxy(
            address(morphoImpl),
            timelockAddress, // Timelock owns the ProxyAdmin
            abi.encodeCall(MorphoCredit.initialize, (owner))
        );
        
        // Get implementation address for verification
        implementation = address(morphoImpl);
        
        console.log("MorphoCredit Proxy deployed at:", proxy);
        console.log("MorphoCredit Implementation at:", implementation);
        console.log("ProxyAdmin owner: TimelockController");
        console.log("MorphoCredit owner:", owner);
        console.log("ProtocolConfig address:", protocolConfig);
        
        vm.stopBroadcast();
        
        return (proxy, implementation);
    }
}