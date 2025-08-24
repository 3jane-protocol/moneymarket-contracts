// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../src/interfaces/ICreditLine.sol";

import {DeployTimelock} from "./00_DeployTimelock.s.sol";
import {DeployProtocolConfig} from "./01_DeployProtocolConfig.s.sol";
import {ConfigureProtocol} from "./01a_ConfigureProtocol.s.sol";
import {DeployMorphoCredit} from "./02_DeployMorphoCredit.s.sol";
import {DeployAdaptiveCurveIrm} from "./03_DeployAdaptiveCurveIrm.s.sol";
import {DeployHelper} from "./04_DeployHelper.s.sol";
import {DeployCreditLine} from "./05_DeployCreditLine.s.sol";
import {DeployInsuranceFund} from "./06_DeployInsuranceFund.s.sol";
import {DeployMarkdownManager} from "./07_DeployMarkdownManager.s.sol";
import {CreateMarket} from "./09_CreateMarket.s.sol";
// Temporarily disabled - need to fix flattened contract imports
// import {DeployUSD3} from "./10_DeployUSD3.s.sol";
// import {DeploySUSD3} from "./11_DeploySUSD3.s.sol";
import {ConfigureTokens} from "./12_ConfigureTokens.s.sol";

contract DeployAll is Script {
    struct DeploymentAddresses {
        address timelock;
        address protocolConfig;
        address protocolConfigImpl;
        address morphoCredit;
        address morphoCreditImpl;
        address adaptiveCurveIrm;
        address adaptiveCurveIrmImpl;
        address creditLine;
        address insuranceFund;
        address markdownManager;
        bytes32 marketId;
        address usd3;
        address usd3Impl;
        address susd3;
        address susd3Impl;
        address helper;
    }

    function run() external returns (DeploymentAddresses memory addresses) {
        console.log("=== Starting Full Protocol Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Block number:", block.number);
        console.log("");

        // Step 1: Deploy TimelockController
        console.log(">>> Step 1: Deploying TimelockController...");
        DeployTimelock deployTimelock = new DeployTimelock();
        addresses.timelock = deployTimelock.run();
        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(addresses.timelock));
        console.log("");

        // Step 2: Deploy ProtocolConfig
        console.log(">>> Step 2: Deploying ProtocolConfig...");
        DeployProtocolConfig deployProtocolConfig = new DeployProtocolConfig();
        (addresses.protocolConfig, addresses.protocolConfigImpl) = deployProtocolConfig.run();
        vm.setEnv("PROTOCOL_CONFIG", vm.toString(addresses.protocolConfig));
        console.log("");

        // Step 2a: Configure ProtocolConfig
        console.log(">>> Step 2a: Configuring ProtocolConfig...");
        ConfigureProtocol configureProtocol = new ConfigureProtocol();
        configureProtocol.run();
        console.log("");

        // Step 3: Deploy MorphoCredit
        console.log(">>> Step 3: Deploying MorphoCredit...");
        DeployMorphoCredit deployMorphoCredit = new DeployMorphoCredit();
        (addresses.morphoCredit, addresses.morphoCreditImpl) = deployMorphoCredit.run();
        vm.setEnv("MORPHO_ADDRESS", vm.toString(addresses.morphoCredit));
        console.log("");

        // Step 4: Deploy MarkdownManager (needed by CreditLine)
        console.log(">>> Step 4: Deploying MarkdownManager...");
        DeployMarkdownManager deployMarkdownManager = new DeployMarkdownManager();
        addresses.markdownManager = deployMarkdownManager.run();
        vm.setEnv("MARKDOWN_MANAGER_ADDRESS", vm.toString(addresses.markdownManager));
        console.log("");

        // Step 5: Deploy CreditLine
        console.log(">>> Step 5: Deploying CreditLine...");
        DeployCreditLine deployCreditLine = new DeployCreditLine();
        addresses.creditLine = deployCreditLine.run();
        vm.setEnv("CREDIT_LINE_ADDRESS", vm.toString(addresses.creditLine));
        console.log("");

        // Step 6: Deploy InsuranceFund
        console.log(">>> Step 6: Deploying InsuranceFund...");
        DeployInsuranceFund deployInsuranceFund = new DeployInsuranceFund();
        addresses.insuranceFund = deployInsuranceFund.run();
        vm.setEnv("INSURANCE_FUND_ADDRESS", vm.toString(addresses.insuranceFund));
        console.log("");

        // Step 6a: Configure CreditLine with InsuranceFund
        console.log(">>> Step 6a: Configuring CreditLine with InsuranceFund...");
        address owner = vm.envAddress("OWNER_ADDRESS");
        vm.startBroadcast(owner);
        ICreditLine(addresses.creditLine).setInsuranceFund(addresses.insuranceFund);
        vm.stopBroadcast();
        console.log("  - Set InsuranceFund in CreditLine");
        console.log("");

        // Step 7: Deploy AdaptiveCurveIrm
        console.log(">>> Step 7: Deploying AdaptiveCurveIrm...");
        DeployAdaptiveCurveIrm deployAdaptiveCurveIrm = new DeployAdaptiveCurveIrm();
        addresses.adaptiveCurveIrm = deployAdaptiveCurveIrm.run();
        addresses.adaptiveCurveIrmImpl = address(0); // Not upgradeable
        vm.setEnv("ADAPTIVE_CURVE_IRM_ADDRESS", vm.toString(addresses.adaptiveCurveIrm));
        console.log("");

        // Step 8: Create Market in MorphoCredit
        console.log(">>> Step 8: Creating Market in MorphoCredit...");
        CreateMarket createMarket = new CreateMarket();
        addresses.marketId = Id.unwrap(createMarket.run());
        vm.setEnv("MARKET_ID", vm.toString(addresses.marketId));
        console.log("");

        // Step 9: Deploy USD3 (Senior Tranche) - TEMPORARILY DISABLED
        console.log(">>> Step 9: Skipping USD3 deployment (temporarily disabled)...");
        // DeployUSD3 deployUSD3 = new DeployUSD3();
        // (addresses.usd3, addresses.usd3Impl) = deployUSD3.run();
        // vm.setEnv("USD3_ADDRESS", vm.toString(addresses.usd3));
        addresses.usd3 = address(0); // Placeholder
        addresses.usd3Impl = address(0); // Placeholder
        console.log("");

        // Step 10: Deploy sUSD3 (Subordinate Tranche) - TEMPORARILY DISABLED
        console.log(">>> Step 10: Skipping sUSD3 deployment (temporarily disabled)...");
        // DeploySUSD3 deploySUSD3 = new DeploySUSD3();
        // (addresses.susd3, addresses.susd3Impl) = deploySUSD3.run();
        // vm.setEnv("SUSD3_ADDRESS", vm.toString(addresses.susd3));
        addresses.susd3 = address(0); // Placeholder
        addresses.susd3Impl = address(0); // Placeholder
        console.log("");

        // Step 11: Deploy Helper - TEMPORARILY DISABLED (needs USD3/sUSD3)
        console.log(">>> Step 11: Skipping Helper deployment (needs USD3/sUSD3)...");
        // DeployHelper deployHelper = new DeployHelper();
        // addresses.helper = deployHelper.run();
        // vm.setEnv("HELPER_ADDRESS", vm.toString(addresses.helper));
        addresses.helper = address(0); // Placeholder
        console.log("");

        // Step 12: Configure Token Relationships - TEMPORARILY DISABLED (needs USD3/sUSD3)
        console.log(">>> Step 12: Skipping Token Configuration (needs USD3/sUSD3)...");
        // ConfigureTokens configureTokens = new ConfigureTokens();
        // configureTokens.run();
        console.log("");

        // Print summary
        console.log("=== Deployment Complete! ===");
        console.log("");
        console.log("Summary of Deployed Contracts:");
        console.log("-------------------------------");
        console.log("TimelockController:", addresses.timelock);
        console.log("");
        console.log("ProtocolConfig (Proxy):", addresses.protocolConfig);
        console.log("ProtocolConfig (Impl):", addresses.protocolConfigImpl);
        console.log("");
        console.log("MorphoCredit (Proxy):", addresses.morphoCredit);
        console.log("MorphoCredit (Impl):", addresses.morphoCreditImpl);
        console.log("");
        console.log("AdaptiveCurveIrm:", addresses.adaptiveCurveIrm);
        console.log("");
        console.log("CreditLine:", addresses.creditLine);
        console.log("InsuranceFund:", addresses.insuranceFund);
        console.log("MarkdownManager:", addresses.markdownManager);
        console.log("");
        console.log("Market ID:", vm.toString(addresses.marketId));
        console.log("");
        console.log("USD3 (Proxy):", addresses.usd3);
        console.log("USD3 (Impl):", addresses.usd3Impl);
        console.log("");
        console.log("sUSD3 (Proxy):", addresses.susd3);
        console.log("sUSD3 (Impl):", addresses.susd3Impl);
        console.log("");
        console.log("Helper:", addresses.helper);
        console.log("-------------------------------");

        // Save deployment addresses to file
        _saveDeploymentAddresses(addresses);

        return addresses;
    }

    function _saveDeploymentAddresses(DeploymentAddresses memory addresses) internal {
        string memory chainId = vm.toString(block.chainid);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/");

        // Create deployment info JSON
        string memory json = "deploymentInfo";
        vm.serializeAddress(json, "timelock", addresses.timelock);
        vm.serializeAddress(json, "protocolConfig", addresses.protocolConfig);
        vm.serializeAddress(json, "protocolConfigImpl", addresses.protocolConfigImpl);
        vm.serializeAddress(json, "morphoCredit", addresses.morphoCredit);
        vm.serializeAddress(json, "morphoCreditImpl", addresses.morphoCreditImpl);
        vm.serializeAddress(json, "adaptiveCurveIrm", addresses.adaptiveCurveIrm);
        vm.serializeAddress(json, "adaptiveCurveIrmImpl", addresses.adaptiveCurveIrmImpl);
        vm.serializeAddress(json, "creditLine", addresses.creditLine);
        vm.serializeAddress(json, "insuranceFund", addresses.insuranceFund);
        vm.serializeAddress(json, "markdownManager", addresses.markdownManager);
        vm.serializeBytes32(json, "marketId", addresses.marketId);
        vm.serializeAddress(json, "usd3", addresses.usd3);
        vm.serializeAddress(json, "usd3Impl", addresses.usd3Impl);
        vm.serializeAddress(json, "susd3", addresses.susd3);
        vm.serializeAddress(json, "susd3Impl", addresses.susd3Impl);
        vm.serializeAddress(json, "helper", addresses.helper);
        vm.serializeBool(json, "tokensConfigured", true);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);
        string memory finalJson = vm.serializeAddress(json, "deployer", msg.sender);

        // Write to file
        string memory fileName = string.concat(deploymentsPath, "deployment-", timestamp, ".json");
        vm.writeJson(finalJson, fileName);

        // Also write to latest.json for easy access
        string memory latestFile = string.concat(deploymentsPath, "latest.json");
        vm.writeJson(finalJson, latestFile);

        console.log("");
        console.log("Deployment addresses saved to:");
        console.log(fileName);
        console.log(latestFile);
    }
}
