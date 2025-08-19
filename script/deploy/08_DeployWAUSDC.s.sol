// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

// Import the flattened ATokenVault
import "../../src/tokens/flattened/ATokenVault.sol";

contract DeployWAUSDC is Script {
    function run() external returns (address, address) {
        // Use existing waUSDC deployment on Sepolia
        address existingWaUSDC = 0x4cEfDDb14ABbbD37445856E43B5eb2D55b20bbb8;
        
        console.log("Using existing waUSDC deployment on Sepolia");
        console.log("waUSDC address:", existingWaUSDC);
        
        // Save the existing address to deployment file
        _saveAddresses("waUSDC", existingWaUSDC, address(0));
        
        return (existingWaUSDC, address(0));
    }
    
    function _loadAddress(string memory key) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        try vm.readFile(deploymentsPath) returns (string memory json) {
            try vm.parseJsonAddress(json, string.concat(".", key)) returns (address addr) {
                return addr;
            } catch {
                return address(0);
            }
        } catch {
            return address(0);
        }
    }
    
    function _saveAddresses(string memory key, address proxy, address implementation) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/");
        string memory latestFile = string.concat(deploymentsPath, "latest.json");
        
        // Create updated JSON
        string memory json = "deployment";
        
        // Try to read and copy existing addresses
        try vm.readFile(latestFile) returns (string memory existingJson) {
            // Copy existing addresses if file exists
            try vm.parseJsonAddress(existingJson, ".timelock") returns (address addr) {
                vm.serializeAddress(json, "timelock", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".protocolConfig") returns (address addr) {
                vm.serializeAddress(json, "protocolConfig", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".protocolConfigImpl") returns (address addr) {
                vm.serializeAddress(json, "protocolConfigImpl", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".morphoCredit") returns (address addr) {
                vm.serializeAddress(json, "morphoCredit", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".morphoCreditImpl") returns (address addr) {
                vm.serializeAddress(json, "morphoCreditImpl", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".markdownManager") returns (address addr) {
                vm.serializeAddress(json, "markdownManager", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".creditLine") returns (address addr) {
                vm.serializeAddress(json, "creditLine", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".insuranceFund") returns (address addr) {
                vm.serializeAddress(json, "insuranceFund", addr);
            } catch {}
            try vm.parseJsonAddress(existingJson, ".adaptiveCurveIrm") returns (address addr) {
                vm.serializeAddress(json, "adaptiveCurveIrm", addr);
            } catch {}
        } catch {
            console.log("No existing deployment file found, creating new one");
        }
        
        // Add new addresses
        vm.serializeAddress(json, key, proxy);
        string memory finalJson = vm.serializeAddress(json, string.concat(key, "Impl"), implementation);
        
        // Write updated JSON
        vm.writeJson(finalJson, latestFile);
        
        console.log("Addresses saved to deployment file");
    }
}
