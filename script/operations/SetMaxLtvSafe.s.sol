// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title SetMaxLtvSafe Script
/// @notice Sets the MAX_LTV value in ProtocolConfig via Safe multisig
/// @dev Converts from percentage to WAD (1e18) format
contract SetMaxLtvSafe is Script, SafeHelper {
    /// @notice ProtocolConfig contract address (mainnet)
    ProtocolConfig private constant protocolConfig = ProtocolConfig(0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E);

    /// @notice Configuration key for MAX_LTV
    bytes32 private constant MAX_LTV = keccak256("MAX_LTV");

    /// @notice WAD scaling factor
    uint256 private constant WAD = 1e18;

    /// @notice Main execution function
    /// @param ltvPercentage The LTV percentage (e.g., 80 for 80%)
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(uint256 ltvPercentage, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        console2.log("=== Setting MAX_LTV in ProtocolConfig via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("ProtocolConfig address:", address(protocolConfig));
        console2.log("LTV percentage: %d%%", ltvPercentage);
        console2.log("Send to Safe:", send);
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
            // If current value looks like 1e6 format
            if (currentValue < 1e9) {
                console2.log("  (Appears to be in 1e6 format: %d / 100)", currentValue / 1e4);
            } else if (currentValue >= 1e16) {
                console2.log("  (Appears to be in WAD format: %d / 100)", currentValue / 1e16);
            }
        }
        console2.log("");

        // Encode the setConfig call
        bytes memory callData = abi.encodeCall(protocolConfig.setConfig, (MAX_LTV, ltvWad));

        // Add to Safe batch
        console2.log("Adding setConfig call to Safe transaction...");
        addToBatch(address(protocolConfig), callData);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("MAX_LTV will be set to: %d", ltvWad);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
            console2.log("");
            console2.log("MAX_LTV would be set to: %d", ltvWad);
        }
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
