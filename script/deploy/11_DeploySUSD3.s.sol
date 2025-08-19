// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

// Import the flattened sUSD3
import "../../src/tokens/flattened/sUSD3.sol";

contract DeploySUSD3 is Script {
    function run() external returns (address, address) {
        // Check if already deployed
        address existing = _loadAddress("susd3");
        if (existing != address(0)) {
            console.log("sUSD3 already deployed at:", existing);
            address implementation = _loadAddress("susd3Impl");
            if (implementation != address(0)) {
                console.log("Implementation at:", implementation);
                return (existing, implementation);
            }
        }
        
        // Load required addresses from env variables
        address usd3Token = vm.envAddress("USD3_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        
        console.log("Deploying sUSD3 (Subordinate Tranche)...");
        console.log("  USD3 Token:", usd3Token);
        console.log("  Owner:", owner);
        
        vm.startBroadcast();
        
        // sUSD3 has no constructor arguments
        Options memory opts;
        opts.unsafeSkipAllChecks = true;
        
        // Deploy as upgradeable proxy
        // Initialize requires: usd3Token, management, keeper
        address proxy = Upgrades.deployTransparentProxy(
            "out/sUSD3.sol/sUSD3.json",
            owner, // ProxyAdmin owner
            abi.encodeCall(sUSD3.initialize, (
                usd3Token,       // _usd3Token
                owner,          // _management
                owner           // _keeper
            )),
            opts
        );
        
        address implementation = Upgrades.getImplementationAddress(proxy);
        
        console.log("sUSD3 Proxy deployed at:", proxy);
        console.log("sUSD3 Implementation at:", implementation);
        console.log("ProxyAdmin owner:", owner);
        
        vm.stopBroadcast();
        
        // Don't save to file during DeployAll - just return the addresses
        // The DeployAll script will handle persistence
        
        return (proxy, implementation);
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
        
        // Read existing deployment data
        string memory existingJson = vm.readFile(latestFile);
        
        // Create updated JSON
        string memory json = "deployment";
        
        // Copy all existing addresses
        vm.serializeAddress(json, "timelock", vm.parseJsonAddress(existingJson, ".timelock"));
        vm.serializeAddress(json, "protocolConfig", vm.parseJsonAddress(existingJson, ".protocolConfig"));
        vm.serializeAddress(json, "protocolConfigImpl", vm.parseJsonAddress(existingJson, ".protocolConfigImpl"));
        vm.serializeAddress(json, "morphoCredit", vm.parseJsonAddress(existingJson, ".morphoCredit"));
        vm.serializeAddress(json, "morphoCreditImpl", vm.parseJsonAddress(existingJson, ".morphoCreditImpl"));
        vm.serializeAddress(json, "markdownManager", vm.parseJsonAddress(existingJson, ".markdownManager"));
        vm.serializeAddress(json, "creditLine", vm.parseJsonAddress(existingJson, ".creditLine"));
        vm.serializeAddress(json, "insuranceFund", vm.parseJsonAddress(existingJson, ".insuranceFund"));
        vm.serializeAddress(json, "adaptiveCurveIrm", vm.parseJsonAddress(existingJson, ".adaptiveCurveIrm"));
        
        // Copy token addresses
        try vm.parseJsonAddress(existingJson, ".waUSDC") returns (address waUSDC) {
            vm.serializeAddress(json, "waUSDC", waUSDC);
        } catch {}
        try vm.parseJsonAddress(existingJson, ".waUSDCImpl") returns (address waUSDCImpl) {
            vm.serializeAddress(json, "waUSDCImpl", waUSDCImpl);
        } catch {}
        try vm.parseJsonAddress(existingJson, ".usd3") returns (address usd3) {
            vm.serializeAddress(json, "usd3", usd3);
        } catch {}
        try vm.parseJsonAddress(existingJson, ".usd3Impl") returns (address usd3Impl) {
            vm.serializeAddress(json, "usd3Impl", usd3Impl);
        } catch {}
        
        // Copy market ID
        try vm.parseJsonBytes32(existingJson, ".marketId") returns (bytes32 marketId) {
            vm.serializeBytes32(json, "marketId", marketId);
        } catch {}
        
        // Add new addresses
        vm.serializeAddress(json, key, proxy);
        string memory finalJson = vm.serializeAddress(json, string.concat(key, "Impl"), implementation);
        
        // Write updated JSON
        vm.writeJson(finalJson, latestFile);
        
        console.log("Addresses saved to deployment file");
    }
}
