// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {BatchOperationsLib} from "../utils/BatchOperationsLib.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {MorphoCredit} from "../../src/MorphoCredit.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";

/// @title BatchOperationsSafe Script
/// @notice Batches multiple unrelated operations into a single Safe multisig transaction
/// @dev Parses JSON configuration to execute various protocol operations in one batch
contract BatchOperationsSafe is Script, SafeHelper {
    using BatchOperationsLib for *;

    /// @notice Protocol contract addresses (mainnet)
    address private constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    address private constant CREDIT_LINE = 0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9;
    address private constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;

    /// @notice Struct for JSON operation parsing
    struct BatchOperation {
        string opType; // Type of operation: "setConfig", "setCreditLines", "custom"
        address target; // Target contract address (optional, uses defaults if not provided)
        bytes32 key; // Config key for setConfig operations
        uint256 value; // Value for setConfig operations
        string dataFile; // Path to data file for operations like setCreditLines
        bytes customData; // Custom calldata for direct calls
    }

    /// @notice Main execution function
    /// @param configPath Path to JSON file containing batch operations
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(string memory configPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Batching Multiple Operations via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Configuration file:", configPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Read and parse JSON configuration
        string memory json = vm.readFile(configPath);
        bytes memory data = vm.parseJson(json, ".operations");
        BatchOperation[] memory operations = abi.decode(data, (BatchOperation[]));

        console2.log("Loaded", operations.length, "operations from configuration");
        console2.log("");

        // Process each operation
        for (uint256 i = 0; i < operations.length; i++) {
            BatchOperation memory op = operations[i];
            console2.log("Operation", i + 1, ":", op.opType);

            bytes memory callData;
            address targetAddress;

            // Handle different operation types
            if (_strEquals(op.opType, "setConfig")) {
                targetAddress = op.target != address(0) ? op.target : PROTOCOL_CONFIG;
                callData = BatchOperationsLib.encodeSetConfig(op.key, op.value);
                console2.log("  Target:", targetAddress);
                console2.log("  Config Key:", vm.toString(op.key));
                console2.log("  Value:", op.value);
            } else if (_strEquals(op.opType, "setCreditLines")) {
                targetAddress = op.target != address(0) ? op.target : CREDIT_LINE;
                callData = _encodeCreditLinesFromFile(op.dataFile);
                console2.log("  Target:", targetAddress);
                console2.log("  Data file:", op.dataFile);
            } else if (_strEquals(op.opType, "setMinBorrow")) {
                // Convenience operation for setting MIN_BORROW
                targetAddress = op.target != address(0) ? op.target : PROTOCOL_CONFIG;
                bytes32 minBorrowKey = keccak256("MIN_BORROW");
                callData = BatchOperationsLib.encodeSetConfig(minBorrowKey, op.value);
                console2.log("  Target:", targetAddress);
                console2.log("  Min Borrow:", op.value);
            } else if (_strEquals(op.opType, "setMaxLTV")) {
                // Convenience operation for setting MAX_LTV
                targetAddress = op.target != address(0) ? op.target : PROTOCOL_CONFIG;
                bytes32 maxLtvKey = keccak256("MAX_LTV");
                callData = BatchOperationsLib.encodeSetConfig(maxLtvKey, op.value);
                console2.log("  Target:", targetAddress);
                console2.log("  Max LTV:", op.value);
            } else if (_strEquals(op.opType, "setIRP")) {
                // Convenience operation for setting IRP (Interest Rate Penalty)
                targetAddress = op.target != address(0) ? op.target : PROTOCOL_CONFIG;
                bytes32 irpKey = keccak256("IRP");
                callData = BatchOperationsLib.encodeSetConfig(irpKey, op.value);
                console2.log("  Target:", targetAddress);
                console2.log("  IRP:", op.value);
            } else if (_strEquals(op.opType, "custom")) {
                require(op.target != address(0), "Custom operation requires target address");
                targetAddress = op.target;
                callData = op.customData;
                console2.log("  Target:", targetAddress);
                console2.log("  Custom data length:", callData.length);
            } else {
                revert(string.concat("Unknown operation type: ", op.opType));
            }

            // Add to batch
            addToBatch(targetAddress, callData);
            console2.log("");
        }

        console2.log("All operations prepared for batching");
        console2.log("");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Alternative entry point with default simulation mode
    /// @param configPath Path to JSON file containing batch operations
    function run(string memory configPath) external {
        this.run(configPath, false);
    }

    /// @notice Encode credit lines from a JSON file
    /// @param dataFile Path to JSON file with credit line data
    /// @return Encoded setCreditLines call
    function _encodeCreditLinesFromFile(string memory dataFile) private view returns (bytes memory) {
        // Read and parse the credit lines JSON
        string memory json = vm.readFile(dataFile);
        bytes memory data = vm.parseJson(json);

        // Parse as the same structure used in SetCreditLinesSafe
        CreditLineData[] memory creditLines = abi.decode(data, (CreditLineData[]));

        // Prepare arrays
        uint256 size = creditLines.length;
        Id[] memory ids = new Id[](size);
        address[] memory borrowers = new address[](size);
        uint256[] memory vvs = new uint256[](size);
        uint256[] memory credits = new uint256[](size);
        uint128[] memory drps = new uint128[](size);

        // Use the standard market ID
        Id marketId = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

        for (uint256 i = 0; i < size; i++) {
            ids[i] = marketId;
            borrowers[i] = creditLines[i].borrower;
            vvs[i] = creditLines[i].vv;
            credits[i] = creditLines[i].credit;
            drps[i] = creditLines[i].drp;
        }

        return abi.encodeCall(CreditLine.setCreditLines, (ids, borrowers, vvs, credits, drps));
    }

    /// @notice Check if base fee is acceptable
    /// @return True if base fee is below limit
    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }

    /// @notice Compare two strings for equality
    function _strEquals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Struct for credit line data (matches SetCreditLinesSafe)
    struct CreditLineData {
        address borrower;
        uint256 credit;
        uint128 drp;
        uint256 vv;
    }
}
