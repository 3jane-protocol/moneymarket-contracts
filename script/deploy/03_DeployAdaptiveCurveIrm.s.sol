// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AdaptiveCurveIrm} from "../../src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";

contract DeployAdaptiveCurveIrm is Script {
    function run() external returns (address irm) {
        address morphoAddress = vm.envAddress("MORPHO_ADDRESS");
        
        // Check if already deployed by trying to load from env
        try vm.envAddress("ADAPTIVE_CURVE_IRM_ADDRESS") returns (address existing) {
            if (existing != address(0) && existing.code.length > 0) {
                console.log("AdaptiveCurveIrm already deployed at:", existing);
                return existing;
            }
        } catch {}
        
        vm.startBroadcast();
        
        // Deploy AdaptiveCurveIrm as a regular contract (not upgradeable)
        irm = address(new AdaptiveCurveIrm(morphoAddress));
        
        console.log("AdaptiveCurveIrm deployed at:", irm);
        console.log("Morpho address:", morphoAddress);
        
        vm.stopBroadcast();
        
        return irm;
    }
}