// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";

// Don't import flattened USD3 directly to avoid duplicate declarations
// The contract will be deployed using the compiled bytecode

// Define the initialization interface
interface IUSD3Initialize {
    function initialize(address _morphoCredit, Id _marketId, address _management, address _keeper) external;
}

contract DeployUSD3 is Script {
    function run() external returns (address, address) {
        // Check if already deployed
        address existing = _loadAddress("usd3");
        if (existing != address(0)) {
            console.log("USD3 already deployed at:", existing);
            address impl = _loadAddress("usd3Impl");
            if (impl != address(0)) {
                console.log("Implementation at:", impl);
                return (existing, impl);
            }
        }

        // Load required addresses from env variables
        address morphoCredit = vm.envAddress("MORPHO_ADDRESS");
        address waUSDC = vm.envAddress("WAUSDC_ADDRESS");
        bytes32 marketIdBytes = vm.envBytes32("MARKET_ID");
        Id marketId = Id.wrap(marketIdBytes);
        address owner = vm.envAddress("OWNER_ADDRESS");
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        console.log("Deploying USD3 (Senior Tranche)...");
        console.log("  MorphoCredit:", morphoCredit);
        console.log("  waUSDC:", waUSDC);
        console.log("  Market ID:");
        console.logBytes32(Id.unwrap(marketId));
        console.log("  Owner:", owner);

        vm.startBroadcast();

        // USD3 has no constructor arguments
        Options memory opts;
        opts.unsafeSkipAllChecks = true;

        // Deploy as upgradeable proxy
        // Initialize requires: morphoCredit, marketId, management, keeper
        address proxy = Upgrades.deployTransparentProxy(
            "out/USD3.sol/USD3.json",
            timelock, // Timelock owns the ProxyAdmin for upgrade control
            abi.encodeCall(
                IUSD3Initialize.initialize,
                (
                    morphoCredit, // _morphoCredit
                    marketId, // _marketId
                    owner, // _management
                    multisig // _keeper
                )
            ),
            opts
        );

        address implementation = Upgrades.getImplementationAddress(proxy);

        console.log("USD3 Proxy deployed at:", proxy);
        console.log("USD3 Implementation at:", implementation);
        console.log("ProxyAdmin owner:", timelock);

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

    function _loadBytes32(string memory key) internal view returns (bytes32) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        try vm.readFile(deploymentsPath) returns (string memory json) {
            try vm.parseJsonBytes32(json, string.concat(".", key)) returns (bytes32 value) {
                return value;
            } catch {
                return bytes32(0);
            }
        } catch {
            return bytes32(0);
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

        // Copy all existing addresses (skip timelock since we're not using it)
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

        // Copy waUSDC addresses
        try vm.parseJsonAddress(existingJson, ".waUSDC") returns (address waUSDC) {
            vm.serializeAddress(json, "waUSDC", waUSDC);
        } catch {}
        try vm.parseJsonAddress(existingJson, ".waUSDCImpl") returns (address waUSDCImpl) {
            vm.serializeAddress(json, "waUSDCImpl", waUSDCImpl);
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
