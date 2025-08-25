// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Helper} from "../../src/Helper.sol";

contract DeployHelper is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("helper");
        if (existing != address(0)) {
            console.log("Helper already deployed at:", existing);
            return existing;
        }

        // Load addresses from environment variables
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        address usd3 = vm.envAddress("USD3_ADDRESS");
        address susd3 = vm.envAddress("SUSD3_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address wausdc = vm.envAddress("WAUSDC_ADDRESS");

        console.log("Deploying Helper...");
        console.log("  MORPHO:", morpho);
        console.log("  USD3:", usd3);
        console.log("  sUSD3:", susd3);
        console.log("  USDC:", usdc);
        console.log("  WAUSDC:", wausdc);

        vm.startBroadcast();

        Helper helper = new Helper(morpho, usd3, susd3, usdc, wausdc);

        console.log("Helper deployed at:", address(helper));

        vm.stopBroadcast();

        // Don't save to file during DeployAll - DeployAll handles persistence

        return address(helper);
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

    function _saveAddress(string memory key, address value) internal {
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

        // Copy token addresses if they exist
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
        try vm.parseJsonAddress(existingJson, ".susd3") returns (address susd3) {
            vm.serializeAddress(json, "susd3", susd3);
        } catch {}
        try vm.parseJsonAddress(existingJson, ".susd3Impl") returns (address susd3Impl) {
            vm.serializeAddress(json, "susd3Impl", susd3Impl);
        } catch {}

        // Copy market ID if it exists
        try vm.parseJsonBytes32(existingJson, ".marketId") returns (bytes32 marketId) {
            vm.serializeBytes32(json, "marketId", marketId);
        } catch {}

        // Copy configuration status if it exists
        try vm.parseJsonBool(existingJson, ".tokensConfigured") returns (bool configured) {
            vm.serializeBool(json, "tokensConfigured", configured);
        } catch {}

        // Add new address
        string memory finalJson = vm.serializeAddress(json, key, value);

        // Write updated JSON
        vm.writeJson(finalJson, latestFile);

        console.log("Address saved to deployment file");
    }
}
