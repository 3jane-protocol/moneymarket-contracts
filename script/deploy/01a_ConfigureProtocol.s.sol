// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

contract ConfigureProtocol is Script {
    function run() external {
        // Load deployed addresses
        address protocolConfig = _loadAddressWithEnv("protocolConfig", "PROTOCOL_CONFIG");
        address owner = vm.envAddress("OWNER_ADDRESS");
        
        console.log("Configuring ProtocolConfig...");
        console.log("  ProtocolConfig:", protocolConfig);
        console.log("  Owner:", owner);
        
        vm.startBroadcast(owner);
        
        ProtocolConfig config = ProtocolConfig(protocolConfig);
        
        // IRM configurations (required for AdaptiveCurveIrm)
        console.log("Setting IRM configurations...");
        config.setConfig(keccak256("CURVE_STEEPNESS"), uint256(4 ether)); // 4 curve steepness
        config.setConfig(keccak256("ADJUSTMENT_SPEED"), uint256(50 ether / int256(365 days))); // ~50% per year
        config.setConfig(keccak256("TARGET_UTILIZATION"), uint256(0.9 ether)); // 90% target utilization
        config.setConfig(keccak256("INITIAL_RATE_AT_TARGET"), uint256(0.04 ether / int256(365 days))); // 4% APR
        config.setConfig(keccak256("MIN_RATE_AT_TARGET"), uint256(0.001 ether / int256(365 days))); // 0.1% APR
        config.setConfig(keccak256("MAX_RATE_AT_TARGET"), uint256(2.0 ether / int256(365 days))); // 200% APR
        
        // Credit Line configurations
        console.log("Setting Credit Line configurations...");
        config.setConfig(keccak256("MAX_LTV"), 0.8 ether); // 80% LTV
        config.setConfig(keccak256("MAX_VV"), 0.9 ether); // 90% VV
        config.setConfig(keccak256("MAX_CREDIT_LINE"), 1e30); // Large credit line for testing
        config.setConfig(keccak256("MIN_CREDIT_LINE"), 1e18); // 1 token minimum
        config.setConfig(keccak256("MAX_DRP"), 0.1 ether); // 10% max DRP
        
        // Market configurations
        console.log("Setting Market configurations...");
        config.setConfig(keccak256("IS_PAUSED"), 0); // Not paused
        config.setConfig(keccak256("MAX_ON_CREDIT"), 0.95 ether); // 95% max on credit
        config.setConfig(keccak256("IRP"), uint256(0.1 ether / int256(365 days))); // 10% IRP
        config.setConfig(keccak256("MIN_BORROW"), 1000e18); // 1000 tokens minimum borrow
        config.setConfig(keccak256("GRACE_PERIOD"), 7 days); // 7 days grace period
        config.setConfig(keccak256("DELINQUENCY_PERIOD"), 23 days); // 23 days delinquency period
        
        // USD3 & sUSD3 configurations
        console.log("Setting USD3 & sUSD3 configurations...");
        config.setConfig(keccak256("TRANCHE_RATIO"), 0.7 ether); // 70% tranche ratio
        config.setConfig(keccak256("TRANCHE_SHARE_VARIANT"), 1); // Variant 1
        config.setConfig(keccak256("SUSD3_LOCK_DURATION"), 30 days); // 30 days lock duration
        config.setConfig(keccak256("SUSD3_COOLDOWN_PERIOD"), 7 days); // 7 days cooldown period
        
        vm.stopBroadcast();
        
        console.log("ProtocolConfig configured successfully!");
    }
    
    function _loadAddressWithEnv(string memory key, string memory envVar) internal view returns (address) {
        // Try environment variable first
        try vm.envAddress(envVar) returns (address addr) {
            if (addr != address(0)) {
                return addr;
            }
        } catch {}
        
        // Fall back to loading from file
        return _loadAddress(key);
    }
    
    function _loadAddress(string memory key) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        string memory json = vm.readFile(deploymentsPath);
        return vm.parseJsonAddress(json, string.concat(".", key));
    }
}