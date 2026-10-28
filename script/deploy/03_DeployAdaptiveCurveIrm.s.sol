// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {AdaptiveCurveIrm} from "../../src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";

contract DeployAdaptiveCurveIrm is Script {
    function run() external returns (address proxy, address implementation) {
        address morphoAddress = vm.envAddress("MORPHO_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // Check if already deployed by trying to load from env
        try vm.envAddress("ADAPTIVE_CURVE_IRM_ADDRESS") returns (address existing) {
            if (existing != address(0) && existing.code.length > 0) {
                console.log("AdaptiveCurveIrm already deployed at:", existing);
                // Try to get implementation address to verify it's a proxy
                implementation = Upgrades.getImplementationAddress(existing);
                if (implementation != address(0)) {
                    console.log("Implementation at:", implementation);
                    return (existing, implementation);
                }
            }
        } catch {}

        vm.startBroadcast();

        // AdaptiveCurveIrm requires morpho address in its constructor
        Options memory opts;
        opts.constructorData = abi.encode(morphoAddress);
        opts.unsafeSkipAllChecks = true; // Skip validation due to deployment profile compilation

        // Deploy as Transparent Proxy using OpenZeppelin Upgrades library
        proxy = Upgrades.deployTransparentProxy(
            "AdaptiveCurveIrm.sol:AdaptiveCurveIrm",
            timelock, // Timelock owns the ProxyAdmin for upgrade control
            abi.encodeCall(AdaptiveCurveIrm.initialize, ()),
            opts
        );

        // Get the implementation address for logging
        implementation = Upgrades.getImplementationAddress(proxy);

        console.log("AdaptiveCurveIrm Proxy deployed at:", proxy);
        console.log("AdaptiveCurveIrm Implementation at:", implementation);
        console.log("ProxyAdmin owner:", timelock);
        console.log("Morpho address:", morphoAddress);

        vm.stopBroadcast();

        return (proxy, implementation);
    }
}
