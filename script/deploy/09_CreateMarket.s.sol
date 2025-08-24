// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMorpho, MarketParams, Id} from "../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";

contract CreateMarket is Script {
    function run() external returns (Id) {
        // Load deployed addresses - try env vars first, then file
        address morphoCredit = _loadAddressWithEnv("morphoCredit", "MORPHO_ADDRESS");
        address waUSDC = vm.envAddress("WAUSDC_ADDRESS"); // Load existing waUSDC from env
        address adaptiveCurveIrm = _loadAddressWithEnv("adaptiveCurveIrm", "ADAPTIVE_CURVE_IRM_ADDRESS");
        address creditLine = _loadAddressWithEnv("creditLine", "CREDIT_LINE_ADDRESS");
        address usdcOracle = vm.envAddress("USDC_ORACLE"); // Load USDC oracle from env

        console.log("Creating market in MorphoCredit...");
        console.log("  MorphoCredit:", morphoCredit);
        console.log("  Loan Token (waUSDC):", waUSDC);
        console.log("  IRM:", adaptiveCurveIrm);
        console.log("  Credit Line:", creditLine);
        console.log("  USDC Oracle:", usdcOracle);

        // Create market parameters for unsecured lending
        MarketParams memory params = MarketParams({
            loanToken: waUSDC,
            collateralToken: address(0), // No collateral for unsecured lending
            oracle: usdcOracle, // USDC price oracle for health checks
            irm: adaptiveCurveIrm,
            lltv: 0.95e18, // 95% LLTV for unsecured lending (high value since no collateral)
            creditLine: creditLine // Enable credit line feature
        });

        // Calculate market ID
        Id marketId = MarketParamsLib.id(params);
        console.log("Market ID:");
        console.logBytes32(Id.unwrap(marketId));

        // Broadcast as the owner to enable IRM
        address owner = vm.envAddress("OWNER_ADDRESS");
        vm.startBroadcast(owner);

        // Enable the IRM if not already enabled
        if (!IMorpho(morphoCredit).isIrmEnabled(adaptiveCurveIrm)) {
            console.log("Enabling IRM:", adaptiveCurveIrm);
            IMorpho(morphoCredit).enableIrm(adaptiveCurveIrm);
        }

        // Enable LLTV of 95% for unsecured lending
        if (!IMorpho(morphoCredit).isLltvEnabled(0.95e18)) {
            console.log("Enabling LLTV 95% for unsecured lending...");
            IMorpho(morphoCredit).enableLltv(0.95e18);
        }

        // Create the market
        IMorpho(morphoCredit).createMarket(params);

        vm.stopBroadcast();

        console.log("Market created successfully!");
        console.log("Market ID:");
        console.logBytes32(Id.unwrap(marketId));

        // Don't save to file during DeployAll - just return the marketId
        // The DeployAll script will handle persistence

        return marketId;
    }

    function _loadAddress(string memory key) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        string memory json = vm.readFile(deploymentsPath);
        return vm.parseJsonAddress(json, string.concat(".", key));
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

    function _saveMarketId(Id marketId) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/");
        string memory latestFile = string.concat(deploymentsPath, "latest.json");

        // Read existing deployment data
        string memory existingJson = vm.readFile(latestFile);

        // Create updated JSON with market ID
        string memory json = "deployment";

        // Copy existing addresses (skip timelock since we're not using it)
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

        // Add waUSDC if it exists
        try vm.parseJsonAddress(existingJson, ".waUSDC") returns (address waUSDC) {
            vm.serializeAddress(json, "waUSDC", waUSDC);
        } catch {}

        // Add market ID
        string memory finalJson = vm.serializeBytes32(json, "marketId", Id.unwrap(marketId));

        // Write updated JSON
        vm.writeJson(finalJson, latestFile);

        console.log("Market ID saved to deployment file");
    }
}
