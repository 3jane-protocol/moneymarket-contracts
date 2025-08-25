// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {MorphoCredit} from "../../src/MorphoCredit.sol";

contract DeployMorphoCredit is Script {
    function run() external returns (address proxy, address implementation) {
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // Check if already deployed by trying to load from env
        try vm.envAddress("MORPHO_ADDRESS") returns (address existing) {
            if (existing != address(0) && existing.code.length > 0) {
                console.log("MorphoCredit already deployed at:", existing);
                // Try to get implementation address to verify it's a proxy
                implementation = Upgrades.getImplementationAddress(existing);
                if (implementation != address(0)) {
                    console.log("Implementation at:", implementation);
                    return (existing, implementation);
                }
            }
        } catch {}

        vm.startBroadcast();

        // MorphoCredit requires protocolConfig in its constructor
        Options memory opts;
        opts.constructorData = abi.encode(protocolConfig);
        opts.unsafeSkipAllChecks = true; // Skip validation due to deployment profile compilation

        // Deploy Transparent Proxy using OpenZeppelin Upgrades library
        proxy = Upgrades.deployTransparentProxy(
            "MorphoCredit.sol:MorphoCredit",
            timelock, // Timelock owns the ProxyAdmin for upgrade control
            abi.encodeCall(MorphoCredit.initialize, (owner)),
            opts
        );

        // Get the implementation address for logging
        implementation = Upgrades.getImplementationAddress(proxy);

        console.log("MorphoCredit Proxy deployed at:", proxy);
        console.log("MorphoCredit Implementation at:", implementation);
        console.log("ProxyAdmin owner:", timelock);
        console.log("MorphoCredit owner:", owner);
        console.log("ProtocolConfig address:", protocolConfig);

        vm.stopBroadcast();

        return (proxy, implementation);
    }
}
