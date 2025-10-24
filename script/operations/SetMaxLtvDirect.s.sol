// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title SetMaxLtvDirect Script
/// @notice Sets the MAX_LTV value in ProtocolConfig via direct execution
/// @dev For testing or emergency use - production should use SetMaxLtvSafe
contract SetMaxLtvDirect is Script {
    /// @notice ProtocolConfig contract address (mainnet)
    ProtocolConfig private constant protocolConfig = ProtocolConfig(0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E);

    /// @notice Configuration key for MAX_LTV
    bytes32 private constant MAX_LTV = keccak256("MAX_LTV");

    /// @notice WAD scaling factor
    uint256 private constant WAD = 1e18;

    /// @notice Main execution function
    /// @param ltvPercentage The LTV percentage (e.g., 80 for 80%)
    function run(uint256 ltvPercentage) external {
        console2.log("=== Setting MAX_LTV in ProtocolConfig (Direct) ===");
        console2.log("ProtocolConfig address:", address(protocolConfig));
        console2.log("LTV percentage: %d%%", ltvPercentage);
        console2.log("");

        // Validate input
        require(ltvPercentage > 0 && ltvPercentage <= 100, "Invalid LTV percentage");

        // Convert percentage to WAD
        uint256 ltvWad = (ltvPercentage * WAD) / 100;
        console2.log("LTV in WAD:", ltvWad);
        console2.log("  (This equals %d / 100 in decimal)", ltvWad / 1e16);
        console2.log("");

        // Get current value for comparison
        uint256 currentValue = protocolConfig.config(MAX_LTV);
        console2.log("Current MAX_LTV value:", currentValue);
        if (currentValue > 0) {
            if (currentValue < 1e9) {
                console2.log("  (Appears to be in 1e6 format: %d / 100)", currentValue / 1e4);
            } else if (currentValue >= 1e16) {
                console2.log("  (Appears to be in WAD format: %d / 100)", currentValue / 1e16);
            }
        }
        console2.log("");

        // Get the deployer account
        string memory walletType = vm.envString("WALLET_TYPE");
        require(keccak256(bytes(walletType)) == keccak256("account"), "Direct execution requires WALLET_TYPE=account");

        string memory accountName = vm.envString("SAFE_PROPOSER_ACCOUNT");
        console2.log("Using account:", accountName);

        // Execute the transaction
        vm.startBroadcast();

        protocolConfig.setConfig(MAX_LTV, ltvWad);

        vm.stopBroadcast();

        console2.log("");
        console2.log("Transaction executed successfully!");
        console2.log("MAX_LTV has been set to: %d (WAD format)", ltvWad);
        console2.log("  This represents: %d%%", ltvPercentage);
    }

    /// @notice Dry run function for validation
    /// @param ltvPercentage The LTV percentage (e.g., 80 for 80%)
    function dryRun(uint256 ltvPercentage) external view {
        console2.log("=== DRY RUN: Setting MAX_LTV ===");
        console2.log("ProtocolConfig address:", address(protocolConfig));
        console2.log("LTV percentage: %d%%", ltvPercentage);
        console2.log("");

        // Validate input
        require(ltvPercentage > 0 && ltvPercentage <= 100, "Invalid LTV percentage");

        // Convert percentage to WAD
        uint256 ltvWad = (ltvPercentage * WAD) / 100;
        console2.log("LTV in WAD:", ltvWad);
        console2.log("  Decimal representation: %d / 100", ltvWad / 1e16);
        console2.log("");

        // Get current value
        uint256 currentValue = protocolConfig.config(MAX_LTV);
        console2.log("Current MAX_LTV value:", currentValue);
        if (currentValue > 0) {
            if (currentValue < 1e9) {
                console2.log("  Current format: 1e6 (%d / 100)", currentValue / 1e4);
                console2.log("  Needs conversion to WAD!");
            } else if (currentValue >= 1e16) {
                console2.log("  Current format: WAD (%d / 100)", currentValue / 1e16);
                if (currentValue == ltvWad) {
                    console2.log("  [INFO] Value is already set correctly");
                } else {
                    console2.log("  Will update from %d%% to %d%%", currentValue / 1e16, ltvPercentage);
                }
            }
        }
        console2.log("");
        console2.log("Dry run completed successfully!");
    }

    /// @notice Helper to check current configuration
    function checkConfig() external view {
        console2.log("=== Current ProtocolConfig Settings ===");
        console2.log("ProtocolConfig address:", address(protocolConfig));
        console2.log("");

        // Get MAX_LTV
        uint256 maxLtv = protocolConfig.config(MAX_LTV);
        console2.log("MAX_LTV raw value:", maxLtv);
        if (maxLtv > 0) {
            if (maxLtv < 1e9) {
                console2.log("  Format: 1e6");
                console2.log("  Percentage: %d%%", maxLtv / 1e4);
                console2.log("  To convert to WAD, multiply by 1e12");
                console2.log("  WAD value would be:", maxLtv * 1e12);
            } else if (maxLtv >= 1e16) {
                console2.log("  Format: WAD");
                console2.log("  Percentage: %d%%", maxLtv / 1e16);
            } else {
                console2.log("  Format: Unknown");
            }
        }

        // Get other related configs
        console2.log("");
        console2.log("Other credit line configs:");
        uint256 maxVv = protocolConfig.config(keccak256("MAX_VV"));
        uint256 maxCreditLine = protocolConfig.config(keccak256("MAX_CREDIT_LINE"));
        uint256 minCreditLine = protocolConfig.config(keccak256("MIN_CREDIT_LINE"));
        uint256 maxDrp = protocolConfig.config(keccak256("MAX_DRP"));

        console2.log("  MAX_VV:", maxVv);
        console2.log("  MAX_CREDIT_LINE:", maxCreditLine);
        console2.log("  MIN_CREDIT_LINE:", minCreditLine);
        console2.log("  MAX_DRP:", maxDrp);
    }
}
