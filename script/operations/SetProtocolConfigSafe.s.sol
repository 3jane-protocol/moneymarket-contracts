// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../../src/libraries/ProtocolConfigLib.sol";

/**
 * @title SetProtocolConfigSafe
 * @notice Set protocol configuration values via Safe multisig transaction
 * @dev Supports setting any subset of protocol config values in a single atomic transaction
 *      Only non-zero environment variables are included in the batch
 */
contract SetProtocolConfigSafe is Script, SafeHelper {
    struct ConfigUpdate {
        bytes32 key;
        uint256 value;
        uint256 previousValue;
        string description;
    }

    ConfigUpdate[] private updates;

    /**
     * @notice Main execution function
     * @param send Whether to send transaction to Safe API (true) or just simulate (false)
     */
    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Protocol Config Update via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Send to Safe:", send);
        console2.log("");

        // Load protocol config address
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");
        console2.log("ProtocolConfig address:", protocolConfig);
        console2.log("");

        // ====================================================================
        // CREDIT LINE CONFIGURATION
        // ====================================================================
        _checkAndAddConfig(protocolConfig, "MAX_LTV", ProtocolConfigLib.MAX_LTV, "Max LTV", false);
        _checkAndAddConfig(protocolConfig, "MAX_VV", ProtocolConfigLib.MAX_VV, "Max VV", false);
        _checkAndAddConfig(
            protocolConfig, "MAX_CREDIT_LINE", ProtocolConfigLib.MAX_CREDIT_LINE, "Max credit line", false
        );
        _checkAndAddConfig(
            protocolConfig, "MIN_CREDIT_LINE", ProtocolConfigLib.MIN_CREDIT_LINE, "Min credit line", false
        );
        _checkAndAddConfig(protocolConfig, "MAX_DRP", ProtocolConfigLib.MAX_DRP, "Max DRP", false);

        // ====================================================================
        // MARKET CONFIGURATION
        // ====================================================================
        _checkAndAddConfig(protocolConfig, "IS_PAUSED", ProtocolConfigLib.IS_PAUSED, "Market pause state", false);
        _checkAndAddConfig(
            protocolConfig, "MAX_ON_CREDIT", ProtocolConfigLib.MAX_ON_CREDIT, "Max on credit (USDC)", true
        );
        _checkAndAddConfig(protocolConfig, "IRP", ProtocolConfigLib.IRP, "Interest rate premium (IRP)", false);
        _checkAndAddConfig(protocolConfig, "MIN_BORROW", ProtocolConfigLib.MIN_BORROW, "Min borrow amount", false);
        _checkAndAddConfig(protocolConfig, "GRACE_PERIOD", ProtocolConfigLib.GRACE_PERIOD, "Grace period", false);
        _checkAndAddConfig(
            protocolConfig, "DELINQUENCY_PERIOD", ProtocolConfigLib.DELINQUENCY_PERIOD, "Delinquency period", false
        );
        _checkAndAddConfig(protocolConfig, "CYCLE_DURATION", ProtocolConfigLib.CYCLE_DURATION, "Cycle duration", false);

        // ====================================================================
        // IRM CONFIGURATION
        // ====================================================================
        _checkAndAddConfig(
            protocolConfig, "CURVE_STEEPNESS", ProtocolConfigLib.CURVE_STEEPNESS, "Curve steepness", false
        );
        _checkAndAddConfig(
            protocolConfig, "ADJUSTMENT_SPEED", ProtocolConfigLib.ADJUSTMENT_SPEED, "Adjustment speed", false
        );
        _checkAndAddConfig(
            protocolConfig, "TARGET_UTILIZATION", ProtocolConfigLib.TARGET_UTILIZATION, "Target utilization", false
        );
        _checkAndAddConfig(
            protocolConfig,
            "INITIAL_RATE_AT_TARGET",
            ProtocolConfigLib.INITIAL_RATE_AT_TARGET,
            "Initial rate at target",
            false
        );
        _checkAndAddConfig(
            protocolConfig, "MIN_RATE_AT_TARGET", ProtocolConfigLib.MIN_RATE_AT_TARGET, "Min rate at target", false
        );
        _checkAndAddConfig(
            protocolConfig, "MAX_RATE_AT_TARGET", ProtocolConfigLib.MAX_RATE_AT_TARGET, "Max rate at target", false
        );

        // ====================================================================
        // USD3 & sUSD3 CONFIGURATION
        // ====================================================================
        _checkAndAddConfig(protocolConfig, "TRANCHE_RATIO", ProtocolConfigLib.TRANCHE_RATIO, "Tranche ratio", false);
        _checkAndAddConfig(
            protocolConfig,
            "TRANCHE_SHARE_VARIANT",
            ProtocolConfigLib.TRANCHE_SHARE_VARIANT,
            "Tranche share variant",
            false
        );
        _checkAndAddConfig(
            protocolConfig, "SUSD3_LOCK_DURATION", ProtocolConfigLib.SUSD3_LOCK_DURATION, "sUSD3 lock duration", false
        );
        _checkAndAddConfig(
            protocolConfig,
            "SUSD3_COOLDOWN_PERIOD",
            ProtocolConfigLib.SUSD3_COOLDOWN_PERIOD,
            "sUSD3 cooldown period",
            false
        );
        _checkAndAddConfig(
            protocolConfig,
            "USD3_COMMITMENT_TIME",
            ProtocolConfigLib.USD3_COMMITMENT_TIME,
            "USD3 commitment time",
            false
        );
        _checkAndAddConfig(
            protocolConfig,
            "SUSD3_WITHDRAWAL_WINDOW",
            ProtocolConfigLib.SUSD3_WITHDRAWAL_WINDOW,
            "sUSD3 withdrawal window",
            false
        );
        _checkAndAddConfig(
            protocolConfig, "USD3_SUPPLY_CAP", ProtocolConfigLib.USD3_SUPPLY_CAP, "USD3 supply cap (USDC)", true
        );

        // ====================================================================
        // V1.1 CONFIGURATION (Not in ProtocolConfig constants but work via storage)
        // ====================================================================
        _checkAndAddConfig(protocolConfig, "DEBT_CAP", ProtocolConfigLib.DEBT_CAP, "Debt cap (waUSDC)", true);
        _checkAndAddConfig(
            protocolConfig,
            "MIN_SUSD3_BACKING_RATIO",
            ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO,
            "Min sUSD3 backing ratio",
            false
        );
        _checkAndAddConfig(
            protocolConfig,
            "FULL_MARKDOWN_DURATION",
            ProtocolConfigLib.FULL_MARKDOWN_DURATION,
            "Full markdown duration",
            false
        );

        // ====================================================================
        // BUILD AND EXECUTE BATCH
        // ====================================================================
        if (updates.length == 0) {
            console2.log("No configuration updates found in environment variables");
            console2.log("Set environment variables for the configs you want to update");
            console2.log("Example: IS_PAUSED=1 DEBT_CAP=10000000000000 forge script ...");
            return;
        }

        console2.log("=== Configuration Updates ===");
        for (uint256 i = 0; i < updates.length; i++) {
            console2.log("%d. %s", i + 1, updates[i].description);

            // Add to batch
            bytes memory setConfigCall = abi.encodeCall(IProtocolConfig.setConfig, (updates[i].key, updates[i].value));
            addToBatch(protocolConfig, setConfigCall);
        }
        console2.log("");

        console2.log("=== Batch Summary ===");
        console2.log("Total operations:", updates.length);
        console2.log("");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve the transaction in Safe UI");
            console2.log("2. Once threshold reached, anyone can execute");
            console2.log("3. All %d operations will execute atomically", updates.length);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     */
    function run() external {
        this.run(false);
    }

    /**
     * @notice Check if an environment variable is set and add to updates if non-zero
     * @param protocolConfig The protocol config contract address
     * @param envKey The environment variable name
     * @param configKey The protocol config key
     * @param description Human-readable description
     * @param isUSDC Whether the value is in USDC units (for formatting)
     */
    function _checkAndAddConfig(
        address protocolConfig,
        string memory envKey,
        bytes32 configKey,
        string memory description,
        bool isUSDC
    ) private {
        // Try to read the environment variable
        try vm.envUint(envKey) returns (uint256 value) {
            if (value > 0 || keccak256(bytes(envKey)) == keccak256("IS_PAUSED")) {
                // IS_PAUSED can be 0 (unpaused)
                // Fetch the current value from the protocol config
                uint256 previousValue = IProtocolConfig(protocolConfig).config(configKey);

                string memory formattedDesc = _formatDescription(envKey, description, value, previousValue, isUSDC);
                updates.push(
                    ConfigUpdate({
                        key: configKey, value: value, previousValue: previousValue, description: formattedDesc
                    })
                );
            }
        } catch {
            // Environment variable not set, skip
        }
    }

    /**
     * @notice Format description with human-readable values
     * @param envKey The environment variable name
     * @param baseDesc Base description
     * @param value The value being set
     * @param previousValue The current value
     * @param isUSDC Whether the value is in USDC units
     * @return Formatted description string
     */
    function _formatDescription(
        string memory envKey,
        string memory baseDesc,
        uint256 value,
        uint256 previousValue,
        bool isUSDC
    ) private pure returns (string memory) {
        bytes32 keyHash = keccak256(bytes(envKey));

        // Special formatting for specific keys
        if (keyHash == keccak256("IS_PAUSED")) {
            string memory prevState = previousValue == 0 ? "false (unpaused)" : "true (paused)";
            string memory newState = value == 0 ? "false (unpaused)" : "true (paused)";
            return string(abi.encodePacked(baseDesc, ": ", prevState, unicode" → ", newState));
        } else if (isUSDC) {
            // Format USDC values (6 decimals)
            return
                string(abi.encodePacked(baseDesc, ": ", _formatUSDC(previousValue), unicode" → ", _formatUSDC(value)));
        } else if (
            keyHash == keccak256("MAX_CREDIT_LINE") || keyHash == keccak256("MIN_CREDIT_LINE")
                || keyHash == keccak256("MIN_BORROW")
        ) {
            // Format as USDC values
            return
                string(abi.encodePacked(baseDesc, ": ", _formatUSDC(previousValue), unicode" → ", _formatUSDC(value)));
        } else if (
            keyHash == keccak256("TRANCHE_RATIO") || keyHash == keccak256("TRANCHE_SHARE_VARIANT")
                || keyHash == keccak256("MIN_SUSD3_BACKING_RATIO")
        ) {
            // Format as percentage (basis points)
            return string(
                abi.encodePacked(
                    baseDesc, ": ", _formatBasisPoints(previousValue), unicode" → ", _formatBasisPoints(value)
                )
            );
        } else if (
            keyHash == keccak256("GRACE_PERIOD") || keyHash == keccak256("DELINQUENCY_PERIOD")
                || keyHash == keccak256("CYCLE_DURATION") || keyHash == keccak256("SUSD3_LOCK_DURATION")
                || keyHash == keccak256("SUSD3_COOLDOWN_PERIOD") || keyHash == keccak256("USD3_COMMITMENT_TIME")
                || keyHash == keccak256("SUSD3_WITHDRAWAL_WINDOW") || keyHash == keccak256("FULL_MARKDOWN_DURATION")
        ) {
            // Format as days
            return
                string(abi.encodePacked(baseDesc, ": ", _formatDays(previousValue), unicode" → ", _formatDays(value)));
        } else if (keyHash == keccak256("IRP") || keyHash == keccak256("MAX_DRP")) {
            // Format as annual percentage rate
            return string(
                abi.encodePacked(
                    baseDesc, ": ", _formatAnnualRate(previousValue), unicode" → ", _formatAnnualRate(value)
                )
            );
        } else if (
            keyHash == keccak256("MAX_LTV") || keyHash == keccak256("MAX_VV") || keyHash == keccak256("CURVE_STEEPNESS")
                || keyHash == keccak256("ADJUSTMENT_SPEED") || keyHash == keccak256("TARGET_UTILIZATION")
                || keyHash == keccak256("INITIAL_RATE_AT_TARGET") || keyHash == keccak256("MIN_RATE_AT_TARGET")
                || keyHash == keccak256("MAX_RATE_AT_TARGET")
        ) {
            // Format as WAD value with scientific notation
            return
                string(abi.encodePacked(baseDesc, ": ", _formatWAD(previousValue), unicode" → ", _formatWAD(value)));
        } else {
            // Default: just show the raw value
            return
                string(abi.encodePacked(baseDesc, ": ", vm.toString(previousValue), unicode" → ", vm.toString(value)));
        }
    }

    /**
     * @notice Format USDC value (6 decimals)
     */
    function _formatUSDC(uint256 value) private pure returns (string memory) {
        uint256 millions = value / 1e6;
        if (millions >= 1e6) {
            return string(abi.encodePacked(vm.toString(millions / 1e6), "M USDC"));
        } else {
            return string(abi.encodePacked(vm.toString(millions), " USDC"));
        }
    }

    /**
     * @notice Format basis points as percentage
     */
    function _formatBasisPoints(uint256 value) private pure returns (string memory) {
        return string(abi.encodePacked(vm.toString(value / 100), "%"));
    }

    /**
     * @notice Format seconds as days
     */
    function _formatDays(uint256 value) private pure returns (string memory) {
        return string(abi.encodePacked(vm.toString(value / 1 days), " days"));
    }

    /**
     * @notice Format per-second rate as annual percentage
     */
    function _formatAnnualRate(uint256 value) private pure returns (string memory) {
        uint256 annualRate = value * 365 days;
        // Convert from WAD to percentage (multiply by 100)
        uint256 percentage = (annualRate * 100) / 1e18;
        uint256 decimal = ((annualRate * 10000) / 1e18) % 100; // Get 2 decimal places
        return string(abi.encodePacked(vm.toString(percentage), ".", vm.toString(decimal), "% APR"));
    }

    /**
     * @notice Format WAD value with scientific notation and decimal precision
     */
    function _formatWAD(uint256 value) private pure returns (string memory) {
        if (value >= 1e18) {
            uint256 wholePart = value / 1e18;
            uint256 decimalPart = (value % 1e18) / 1e15; // Get 3 decimal places

            if (decimalPart == 0) {
                return string(abi.encodePacked(vm.toString(wholePart), ".0e18"));
            } else {
                // Format decimal part with up to 3 significant digits
                return string(abi.encodePacked(vm.toString(wholePart), ".", _formatDecimalPart(decimalPart, 3), "e18"));
            }
        } else if (value >= 1e15) {
            uint256 wholePart = value / 1e15;
            uint256 decimalPart = (value % 1e15) / 1e12; // Get 3 decimal places

            if (decimalPart == 0) {
                return string(abi.encodePacked(vm.toString(wholePart), ".0e15"));
            } else {
                return string(abi.encodePacked(vm.toString(wholePart), ".", _formatDecimalPart(decimalPart, 3), "e15"));
            }
        } else {
            return vm.toString(value);
        }
    }

    /**
     * @notice Format decimal part removing trailing zeros
     */
    function _formatDecimalPart(uint256 decimal, uint256 digits) private pure returns (string memory) {
        // Remove trailing zeros
        while (decimal > 0 && decimal % 10 == 0) {
            decimal = decimal / 10;
            digits--;
        }

        if (decimal == 0) return "0";

        // Convert to string with proper padding if needed
        string memory decStr = vm.toString(decimal);
        bytes memory decBytes = bytes(decStr);

        // Pad with leading zeros if necessary
        if (decBytes.length < digits && decimal > 0) {
            bytes memory result = new bytes(digits);
            uint256 padding = digits - decBytes.length;
            for (uint256 i = 0; i < padding; i++) {
                result[i] = "0";
            }
            for (uint256 i = 0; i < decBytes.length; i++) {
                result[padding + i] = decBytes[i];
            }
            return string(result);
        }

        return decStr;
    }

    /**
     * @notice Check if base fee is acceptable
     * @return True if base fee is below limit
     */
    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
