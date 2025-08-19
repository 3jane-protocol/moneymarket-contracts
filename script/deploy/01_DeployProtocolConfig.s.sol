// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

contract DeployProtocolConfig is Script {
    function run() external returns (address proxy, address implementation) {
        address owner = vm.envAddress("OWNER_ADDRESS");
        
        // Check if already deployed by trying to load from env
        try vm.envAddress("PROTOCOL_CONFIG") returns (address existing) {
            if (existing != address(0) && existing.code.length > 0) {
                console.log("ProtocolConfig already deployed at:", existing);
                // Try to get implementation address to verify it's a proxy
                implementation = Upgrades.getImplementationAddress(existing);
                if (implementation != address(0)) {
                    console.log("Implementation at:", implementation);
                    return (existing, implementation);
                }
            }
        } catch {}
        
        vm.startBroadcast();
        
        // ProtocolConfig doesn't have constructor args, so no need to set constructorData
        Options memory opts;
        
        // Deploy Transparent Proxy using OpenZeppelin Upgrades library
        proxy = Upgrades.deployTransparentProxy(
            "ProtocolConfig.sol:ProtocolConfig",
            owner, // Owner owns the ProxyAdmin
            abi.encodeCall(ProtocolConfig.initialize, (owner)), // Owner will be the protocol owner
            opts
        );
        
        // Get the implementation address for logging
        implementation = Upgrades.getImplementationAddress(proxy);
        
        console.log("ProtocolConfig Proxy deployed at:", proxy);
        console.log("ProtocolConfig Implementation at:", implementation);
        console.log("ProxyAdmin owner:", owner);
        console.log("ProtocolConfig owner:", owner);
        
        vm.stopBroadcast();
        
        return (proxy, implementation);
    }
}