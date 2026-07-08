// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {CreditLineDataLib} from "../utils/CreditLineDataLib.sol";

/**
 * @title SetCreditLinesSafe Script
 * @notice Sets credit lines for borrowers via Safe multisig transaction through Timelock
 * @dev Since CreditLine is owned by the Timelock, updates must go through schedule/execute.
 *
 *      Usage:
 *      1. Schedule: forge script ... -s "schedule(string,bool)" ./credit-lines.json true
 *      2. Wait for timelock delay (24 hours)
 *      3. Execute: forge script ... -s "execute(string,bool)" ./credit-lines.json true (same JSON)
 */
contract SetCreditLinesSafe is Script, SafeHelper, TimelockHelper {
    using CreditLineDataLib for *;

    // Mainnet addresses
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    /// @notice CreditLine contract address (mainnet)
    CreditLine private constant CREDIT_LINE = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Struct for JSON parsing - fields ordered to match alphabetized JSON
    /// @dev JSON fields alphabetically: borrower_address, credit, drp, vv
    struct CreditLineData {
        address borrower; // maps to "borrower_address" (1st alphabetically)
        uint256 credit; // maps to "credit" (2nd alphabetically)
        uint128 drp; // maps to "drp" (3rd alphabetically)
        uint256 vv; // maps to "vv" (4th alphabetically)
    }

    /**
     * @notice Schedule credit line updates via Timelock (Step 1)
     * @param jsonPath Path to JSON file containing credit line data
     * @param send Whether to send transaction to Safe API (true) or just simulate (false)
     */
    function schedule(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Schedule Credit Lines via Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("CreditLine address:", address(CREDIT_LINE));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Parse and validate credit lines
        CreditLineData[] memory creditLines = _parseCreditLines(jsonPath);

        if (creditLines.length == 0) {
            console2.log("No credit lines found in JSON file");
            return;
        }

        // Build the setCreditLines call
        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(creditLines);

        // Build timelock operation arrays (single call)
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = address(CREDIT_LINE);
        values[0] = 0;
        datas[0] = setCreditLinesCall;

        // Generate deterministic salt
        bytes32 salt = _generateSalt(creditLines);
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use execute() to execute when ready.");
            return;
        }

        // Simulate execution to verify calls will succeed
        simulateExecution(TIMELOCK, targets, values, datas);
        console2.log("");

        // Get minimum delay
        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("Timelock delay:", minDelay, "seconds (%d hours)", minDelay / 3600);
        console2.log("");

        // Encode the schedule call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        // Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("=== IMPORTANT ===");
            console2.log("Operation ID: %s", vm.toString(operationId));
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve and execute the schedule transaction");
            console2.log("2. Wait %d seconds (%d hours) after scheduling", minDelay, minDelay / 3600);
            console2.log("3. Run execute() with the SAME JSON file");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
            console2.log("Operation ID would be: %s", vm.toString(operationId));
        }
    }

    /**
     * @notice Execute scheduled credit line updates (Step 2 - after delay)
     * @param jsonPath Path to JSON file containing credit line data (must match schedule)
     * @param send Whether to send transaction to Safe API (true) or just simulate (false)
     */
    function execute(string memory jsonPath, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Execute Credit Lines via Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("CreditLine address:", address(CREDIT_LINE));
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Parse credit lines (must match what was scheduled)
        CreditLineData[] memory creditLines = _parseCreditLines(jsonPath);

        if (creditLines.length == 0) {
            console2.log("No credit lines found in JSON file");
            return;
        }

        // Rebuild the setCreditLines call
        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(creditLines);

        // Rebuild timelock operation arrays
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = address(CREDIT_LINE);
        values[0] = 0;
        datas[0] = setCreditLinesCall;

        // Regenerate the same salt
        bytes32 salt = _generateSalt(creditLines);
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        // Check operation state
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Verify operation is ready
        requireOperationReady(TIMELOCK, operationId);

        // Encode the execute call
        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        // Add to Safe batch
        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(TIMELOCK, executeCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed, %d credit lines will be updated", creditLines.length);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Check status of a scheduled operation
     * @param jsonPath Path to JSON file containing credit line data
     */
    function checkStatus(string memory jsonPath) external {
        console2.log("=== Check Credit Lines Update Status ===");
        console2.log("Timelock address:", TIMELOCK);
        console2.log("JSON file:", jsonPath);
        console2.log("");

        // Parse credit lines
        CreditLineData[] memory creditLines = _parseCreditLines(jsonPath);

        if (creditLines.length == 0) {
            console2.log("No credit lines found in JSON file");
            return;
        }

        console2.log("Credit lines in file:", creditLines.length);
        console2.log("");

        // Rebuild operation
        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(creditLines);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = address(CREDIT_LINE);
        values[0] = 0;
        datas[0] = setCreditLinesCall;

        bytes32 salt = _generateSalt(creditLines);
        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);

        // Show timelock delay
        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("");
        console2.log("Current timelock delay:", minDelay, "seconds (%d hours)", minDelay / 3600);
    }

    /**
     * @notice Main execution function (backwards compatible - direct Safe call)
     * @dev This will fail if Timelock owns CreditLine. Use schedule/execute instead.
     * @param jsonPath Path to JSON file containing credit line data
     * @param send Whether to send transaction to Safe API (true) or just simulate (false)
     */
    function run(string memory jsonPath, bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Setting Credit Lines via Safe (Direct) ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("CreditLine address:", address(CREDIT_LINE));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Parse and validate credit lines
        CreditLineData[] memory creditLines = _parseCreditLines(jsonPath);

        if (creditLines.length == 0) {
            console2.log("No credit lines found in JSON file");
            return;
        }

        // Build the setCreditLines call
        bytes memory setCreditLinesCall = _buildSetCreditLinesCall(creditLines);

        // Add to Safe batch
        addToBatch(address(CREDIT_LINE), setCreditLinesCall);

        console2.log("Prepared setCreditLines call for %d borrowers", creditLines.length);

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
    /// @param jsonPath Path to JSON file containing credit line data
    function run(string memory jsonPath) external {
        this.run(jsonPath, false);
    }

    /**
     * @notice Parse and validate credit lines from JSON file
     */
    function _parseCreditLines(string memory jsonPath) private returns (CreditLineData[] memory creditLines) {
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        creditLines = abi.decode(data, (CreditLineData[]));

        console2.log("Loaded", creditLines.length, "credit lines from JSON");

        // Validate all credit lines
        for (uint256 i = 0; i < creditLines.length; i++) {
            require(
                CreditLineDataLib.validateDrp(creditLines[i].drp),
                string.concat("Invalid DRP for borrower ", vm.toString(creditLines[i].borrower))
            );
            require(
                creditLines[i].vv > 0, string.concat("Invalid VV for borrower ", vm.toString(creditLines[i].borrower))
            );
            require(
                creditLines[i].credit > 0,
                string.concat("Invalid credit for borrower ", vm.toString(creditLines[i].borrower))
            );
        }

        console2.log("All credit lines validated successfully");
    }

    /**
     * @notice Build the setCreditLines call data
     */
    function _buildSetCreditLinesCall(CreditLineData[] memory creditLines) private view returns (bytes memory) {
        uint256 len = creditLines.length;

        Id[] memory ids = new Id[](len);
        address[] memory borrowers = new address[](len);
        uint256[] memory vvs = new uint256[](len);
        uint256[] memory credits = new uint256[](len);
        uint128[] memory drps = new uint128[](len);

        for (uint256 i = 0; i < len; i++) {
            ids[i] = MARKET_ID;
            borrowers[i] = creditLines[i].borrower;
            vvs[i] = creditLines[i].vv;
            credits[i] = creditLines[i].credit;
            drps[i] = creditLines[i].drp;
        }

        return abi.encodeCall(CREDIT_LINE.setCreditLines, (ids, borrowers, vvs, credits, drps));
    }

    /**
     * @notice Generate deterministic salt from credit line data
     */
    function _generateSalt(CreditLineData[] memory creditLines) private pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < creditLines.length; i++) {
            packed = abi.encodePacked(
                packed, creditLines[i].borrower, creditLines[i].credit, creditLines[i].drp, creditLines[i].vv
            );
        }
        return keccak256(abi.encodePacked("CreditLine Update: ", packed));
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
}
