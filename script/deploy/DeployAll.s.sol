// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {DeployTimelock} from "./00_DeployTimelock.s.sol";
import {DeployProtocolConfig} from "./01_DeployProtocolConfig.s.sol";
import {DeployMorphoCredit} from "./02_DeployMorphoCredit.s.sol";
import {DeployAdaptiveCurveIrm} from "./03_DeployAdaptiveCurveIrm.s.sol";
import {DeployHelper} from "./04_DeployHelper.s.sol";
import {DeployCreditLine} from "./05_DeployCreditLine.s.sol";
import {DeployInsuranceFund} from "./06_DeployInsuranceFund.s.sol";
import {DeployMarkdownManager} from "./07_DeployMarkdownManager.s.sol";

contract DeployAll is Script {
    struct DeploymentAddresses {
        address timelock;
        address protocolConfig;
        address protocolConfigImpl;
        address morphoCredit;
        address morphoCreditImpl;
        address adaptiveCurveIrm;
        address adaptiveCurveIrmImpl;
        address helper;
        address creditLine;
        address insuranceFund;
        address markdownManager;
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
        console.log("");
        
        // Step 7: Deploy AdaptiveCurveIrm
        console.log(">>> Step 7: Deploying AdaptiveCurveIrm...");
        DeployAdaptiveCurveIrm deployAdaptiveCurveIrm = new DeployAdaptiveCurveIrm();
        (addresses.adaptiveCurveIrm, addresses.adaptiveCurveIrmImpl) = deployAdaptiveCurveIrm.run();
        console.log("");
        
        // Step 8: Deploy Helper
        console.log(">>> Step 8: Deploying Helper...");
        DeployHelper deployHelper = new DeployHelper();
        addresses.helper = deployHelper.run();
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
        console.log("AdaptiveCurveIrm (Proxy):", addresses.adaptiveCurveIrm);
        console.log("AdaptiveCurveIrm (Impl):", addresses.adaptiveCurveIrmImpl);
        console.log("");
        console.log("Helper:", addresses.helper);
        console.log("CreditLine:", addresses.creditLine);
        console.log("InsuranceFund:", addresses.insuranceFund);
        console.log("MarkdownManager:", addresses.markdownManager);
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
        vm.serializeAddress(json, "helper", addresses.helper);
        vm.serializeAddress(json, "creditLine", addresses.creditLine);
        vm.serializeAddress(json, "insuranceFund", addresses.insuranceFund);
        vm.serializeAddress(json, "markdownManager", addresses.markdownManager);
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